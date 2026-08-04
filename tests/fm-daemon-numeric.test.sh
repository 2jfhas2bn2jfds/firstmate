#!/usr/bin/env bash
# tests/fm-daemon-numeric.test.sh - the daemon's numeric-value hardening
# (incident daemon-rearm-fix-d8, field-proven 2026-07-15 through 2026-07-20).
#
# WHAT BROKE. Every liveness decision in bin/fm-supervise-daemon.sh is an integer
# comparison over a value read from a command (stat, date, wc) or a state file.
# `[ "$v" -ge N ]` aborts with "integer expression expected" the instant that
# value is not a clean integer, and two real pollutions produce exactly that:
#
#   1. BSD `wc` LEFT-PADS its count, so `sz=$(wc -c < "$LOG")` is "  192505".
#      Padding on its own is tolerated by bash's `[` and by $(( )), so it is not
#      by itself the abort - it is the carrier that made (2) fatal here, and the
#      reason the reported operand reads "  192505" rather than "192505".
#   2. When the disk fills, a bash builtin's output write fails and the undrained
#      buffer is flushed into a LATER command substitution, so `$(date +%s)` and
#      `$(wc -c ...)` come back with a stale log line APPENDED:
#        "1784687492\n[2026-07-15T05:17:47-0300] watcher beacon stale 461s ..."
#      A multi-line operand aborts both `[` and $(( )).
#
# The daemon's own stderr recorded both, forever repeating from 2026-07-15:
#   bin/fm-supervise-daemon.sh: line 725: [: ...watcher beacon stale...
#   3: integer expression expected
#   bin/fm-supervise-daemon.sh: line 958: [:   192505
#   ...: integer expression expected
#
# Line 725 was _backstop_should_arm. The abort made it return non-zero, so
# ensure_watcher_backstop concluded "no arm needed" and a lapsed watcher chain
# was NEVER auto-recovered. Proven in the field 2026-07-20: the beacon went 59
# minutes stale with three secondmates in flight and no re-arm ever fired. The
# backstop was silently dead for three weeks, which is the whole point of these
# tests: the failure has to be loud AND the decision has to survive it.
#
# WHAT IS PINNED HERE.
#   1. _as_int coerces a whitespace-padded value (the `wc` form) to a bare
#      integer, and keeps the FIRST line of a buffer-polluted value (the real
#      number under both pollutions).
#   2. A genuinely unusable value falls back LOUDLY - a warning on stderr - never
#      silently.
#   3. _file_age survives a padded or polluted mtime/clock and returns a bare
#      integer, with the "unknown" sentinel biased toward stale, never fresh.
#   4. _backstop_should_arm STILL ARMS under a polluted read. This is the
#      regression itself: fail toward action, because a redundant arm is a no-op
#      while a missed one is an unsupervised fleet.
#   5. trim_log's size comparison (the reported line) tolerates the same values.
#   6. An unusable CLOCK is held to the same bar as an unusable mtime: _now
#      refuses to invent an epoch, _age_since reads the resulting gap as very
#      old, the stranded-wake poke still fires, and _stamp_now never writes a
#      fabricated epoch into a marker that is read back by content.
#   7. Every numeric ENV override goes through the same coercion (_env_int, or
#      _env_secs for the one fractional delay), so a malformed value falls back
#      instead of aborting the comparison it configures - including _int_warn's
#      own throttle, which must not turn a throttled warning into an unbounded
#      stderr flood.
#   8. A THROTTLE keeps no state of its own. It is wall time over the marker its
#      caller stamps, and nothing else, so an unreadable clock reads as very old
#      and the action fires on every tick until the clock comes back. That is the
#      direction the daemon wants: the condition that makes the clock unreadable
#      is the full disk, so a rate limit that held there would go quiet during its
#      own incident. Both clock states are driven here, and the readable half is
#      pinned against BOTH of its bounds in one case (it must not arm twice inside
#      one throttle window, and it must arm again once that window has passed),
#      with a positive control so a stub that silently suppresses the readable
#      path fails loudly instead of passing while measuring nothing. The real
#      failure is INTERMITTENT (the buffer lands in some later substitution, not
#      in all of them), so that alternating shape is driven here too, and so is
#      the disk-full condition itself, as an unwritable state dir.
#   9. No captain-facing line prints the sentinel as a duration. "stale persisted
#      1784687492s" was the reported nonsense; 999999s is the same class of
#      fabricated-looking number, so an unmeasurable age is named as unknown.
#  10. The OUTERMOST capture, which is where the reported abort actually landed.
#      Coercing inside a helper closes nothing on its own: the result still has
#      to cross a $( ) to be read, and that capture is where the stuck buffer
#      was recorded arriving. Cases 1-9 all stub a value inside a helper, so not
#      one of them can see that failure - which is exactly how it survived a
#      round of hardening. Section 6 below stubs the producers' stdout instead,
#      and adds the structural half: no numeric comparison in a liveness
#      decision reads its operand across a substitution.
#  11. A cadence that feeds `sleep` stays positive. `sleep 0` returns instantly
#      and `sleep -1` fails, so a non-positive override spins the loop it paces
#      rather than merely mis-pacing it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions once; its main loop is BASH_SOURCE-guarded.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-daemon-numeric)
# fm_test_tmproot installs its cleanup trap inside a command substitution, and
# bash runs an EXIT trap when that subshell exits, so the root is gone by the
# time it is echoed back. Every case dir below is mkdir -p'd, which is how the
# rest of the suite works around it; recreate the root here so scratch files
# written straight into it exist too.
mkdir -p "$TMP_ROOT"

# The exact stale log line the full disk kept replaying into later command
# substitutions, verbatim from state/.supervise-daemon.startup.err.
STUCK_BUFFER_LINE='[2026-07-15T05:17:47-0300] watcher beacon stale 461s with 3 in flight; launching backstop re-arm'

new_state() {  # <name> -> echoes a fresh state dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# Assert a function's stdout, keeping its stderr out of the captured value.
assert_out() {  # <got> <want> <msg>
  [ "$1" = "$2" ] || fail "$3 (want '$2', got '$1')"
}

# --- 1. _as_int: the two field pollutions -----------------------------------

# The whitespace-padded case: `wc -c < file` on BSD. This is the value the
# daemon's own stderr named at the reported line ("[:   192505").
test_as_int_strips_whitespace_padding() {
  local got
  got=$(_as_int "  192505" 0 'log-size' 2>/dev/null)
  assert_out "$got" "192505" "left-padded wc count coerces to a bare integer"
  got=$(_as_int "  192505  " 0 'log-size' 2>/dev/null)
  assert_out "$got" "192505" "padding on both sides coerces to a bare integer"
  got=$(_as_int "$(printf '\t42\t')" 0 'log-size' 2>/dev/null)
  assert_out "$got" "42" "tab padding coerces to a bare integer"
  pass "_as_int: a whitespace-padded count reads as a bare integer"
}

# The stuck-output-buffer case: the real value with a stale log line appended.
# The first line IS the real value in both pollutions, so it is recoverable.
test_as_int_keeps_first_line_of_polluted_value() {
  local got
  got=$(_as_int "$(printf '1784687492\n%s' "$STUCK_BUFFER_LINE")" '' 'clock' 2>/dev/null)
  assert_out "$got" "1784687492" "a polluted clock read recovers the real epoch"
  # Padding and pollution together: exactly the reported "[:   192505\n[2026..."
  got=$(_as_int "$(printf '  192505\n%s' "$STUCK_BUFFER_LINE")" 0 'log-size' 2>/dev/null)
  assert_out "$got" "192505" "padded AND polluted still recovers the real count"
  pass "_as_int: a buffer-polluted value recovers its real first-line number"
}

test_as_int_passes_clean_values_through() {
  local got
  got=$(_as_int "300" 0 'x' 2>/dev/null);  assert_out "$got" "300" "plain integer"
  got=$(_as_int "0" 9 'x' 2>/dev/null);    assert_out "$got" "0" "zero is a value, not a fallback"
  got=$(_as_int "-1" 0 'x' 2>/dev/null);   assert_out "$got" "-1" "negative sentinels survive"
  pass "_as_int: clean values pass through unchanged"
}

# --- 2. an unusable value is LOUD, never silent -----------------------------

test_as_int_falls_back_loudly_on_garbage() {
  local out err
  err="$(new_state as-int-garbage)/garbage.err"
  out=$(_as_int "not-a-number" 999999 'mtime:/some/beacon' 2>"$err")
  assert_out "$out" "999999" "an unusable value yields the caller's fallback"
  assert_grep "unreadable numeric value" "$err" "the fallback is announced on stderr"
  assert_grep "mtime:/some/beacon" "$err" "the warning names the context"
  pass "_as_int: an unusable value falls back loudly, not silently"
}

test_as_int_rejects_near_misses() {
  local out
  out=$(_as_int "" 7 'x' 2>/dev/null);      assert_out "$out" "7" "empty is not a number"
  out=$(_as_int "12abc" 7 'x' 2>/dev/null); assert_out "$out" "7" "trailing junk is not a number"
  out=$(_as_int "1 2" 7 'x' 2>/dev/null);   assert_out "$out" "7" "two numbers on one line is not a number"
  out=$(_as_int "-" 7 'x' 2>/dev/null);     assert_out "$out" "7" "a bare sign is not a number"
  pass "_as_int: near-miss values are rejected to the fallback"
}

# --- 3. _file_age under a polluted stat/clock -------------------------------

# Stub _stat_file_mtime for one call. The daemon's real reader is a plain
# `stat`, so a stub is the only way to reproduce a polluted read deterministically.
with_stub_mtime() {  # <emitted-mtime> <fn> [args...]
  local emitted=$1; shift
  local saved
  saved=$(declare -f _stat_file_mtime)
  eval "_stat_file_mtime() { printf '%s' \"\$FM_TEST_STUB_MTIME\"; }"
  FM_TEST_STUB_MTIME="$emitted" "$@"
  local rc=$?
  eval "$saved"
  return $rc
}

# _file_age reads the clock itself, so sampling `date` in the test and asserting
# an exact age would flake whenever a second boundary fell between the two
# samples. Both operands are stubbed instead, which keeps the assertion exact.
test_file_age_survives_padded_mtime() {
  local state now got
  state=$(new_state age-padded)
  : > "$state/.last-watcher-beat"
  now=1784687492
  got=$(with_stub_clock "$now" \
          with_stub_mtime "  $(( now - 461 ))" _file_age "$state/.last-watcher-beat" 2>/dev/null)
  assert_out "$got" "461" "a padded mtime still yields the true age"
  pass "_file_age: a whitespace-padded mtime yields a bare integer age"
}

test_file_age_survives_polluted_mtime() {
  local state now got err
  state=$(new_state age-polluted)
  err="$state/age-polluted.err"
  : > "$state/.last-watcher-beat"
  now=1784687492
  got=$(with_stub_clock "$now" \
          with_stub_mtime "$(printf '%s\n%s' "$(( now - 461 ))" "$STUCK_BUFFER_LINE")" \
          _file_age "$state/.last-watcher-beat" 2>"$err")
  assert_out "$got" "461" "a buffer-polluted mtime still yields the true age"
  assert_no_grep "integer expression expected" "$err" "no aborted comparison leaks to stderr"
  assert_no_grep "syntax error" "$err" "no aborted arithmetic leaks to stderr"
  pass "_file_age: a buffer-polluted mtime yields the true age with no abort"
}

# An unknown age must read as VERY OLD (the documented 999999 sentinel), so any
# liveness check built on it errs toward acting rather than toward doing nothing.
test_file_age_unusable_reads_as_stale_not_fresh() {
  local state got
  state=$(new_state age-garbage)
  : > "$state/.last-watcher-beat"
  got=$(with_stub_mtime "wat" _file_age "$state/.last-watcher-beat" 2>/dev/null)
  assert_out "$got" "999999" "an unreadable mtime reads as very old, never as fresh"
  pass "_file_age: an unusable mtime biases stale, so callers still act"
}

# --- 4. THE REGRESSION: the backstop still arms under a polluted read -------

# This is the field failure. With a task in flight and a beacon well past
# FM_GUARD_GRACE, the backstop must arm - and must keep arming when the mtime
# read is polluted by the stuck output buffer. Before the fix, `[` aborted here
# and _backstop_should_arm returned non-zero: no arm, no poke, no supervision.
test_backstop_still_arms_when_beacon_read_is_polluted() {
  local state now err
  state=$(new_state backstop-polluted)
  err="$state/backstop-polluted.err"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  : > "$state/.last-watcher-beat"
  now=$(date +%s)
  # 3540s stale: the 59-minute lapse observed on 2026-07-20, far past the
  # 300s grace, so the ONLY thing that can suppress the arm is the abort.
  if with_stub_mtime "$(printf '%s\n%s' "$(( now - 3540 ))" "$STUCK_BUFFER_LINE")" \
       _backstop_should_arm "$state" 2>"$err"; then
    :
  else
    fail "backstop did not arm on a 59-minute stale beacon with a polluted mtime read"
  fi
  assert_no_grep "integer expression expected" "$err" "the arm decision ran no aborted comparison"
  pass "_backstop_should_arm: a polluted beacon read still arms the watcher"
}

# Same, for a padded read: it must arm AND the decision must be the true age.
test_backstop_still_arms_when_beacon_read_is_padded() {
  local state now
  state=$(new_state backstop-padded)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  : > "$state/.last-watcher-beat"
  now=$(date +%s)
  if with_stub_mtime "  $(( now - 3540 ))" _backstop_should_arm "$state" 2>/dev/null; then
    pass "_backstop_should_arm: a padded beacon read still arms the watcher"
  else
    fail "backstop did not arm on a stale beacon with a whitespace-padded mtime read"
  fi
}

# The fail-toward-action bias, end to end: an entirely unreadable beacon read
# with work in flight must arm rather than quietly conclude "fresh".
test_backstop_arms_when_beacon_read_is_unusable() {
  local state
  state=$(new_state backstop-garbage)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  : > "$state/.last-watcher-beat"
  if with_stub_mtime "wat" _backstop_should_arm "$state" 2>/dev/null; then
    pass "_backstop_should_arm: an unusable beacon read arms rather than assumes fresh"
  else
    fail "backstop stayed quiet on an unusable beacon read (fails toward silence)"
  fi
}

# A garbage FM_GUARD_GRACE must not abort the decision either: it falls back to
# the documented default rather than taking the whole backstop down with it.
test_backstop_survives_garbage_grace_env() {
  local state
  state=$(new_state backstop-badenv)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  # No beacon file at all => the 999999 sentinel => stale beyond any sane grace.
  if FM_GUARD_GRACE="  " _backstop_should_arm "$state" 2>/dev/null; then
    pass "_backstop_should_arm: a garbage FM_GUARD_GRACE falls back, does not abort"
  else
    fail "a garbage FM_GUARD_GRACE suppressed the backstop"
  fi
}

# The fresh-beacon case must stay unchanged: hardening must not make the daemon
# arm constantly. (Guards against "fix it by always returning true".)
test_backstop_still_quiet_on_a_fresh_beacon() {
  local state now
  state=$(new_state backstop-fresh)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  : > "$state/.last-watcher-beat"
  now=$(date +%s)
  if with_stub_mtime "  $(( now - 5 ))" _backstop_should_arm "$state" 2>/dev/null; then
    fail "backstop armed on a 5-second-old beacon (hardening broke the quiet path)"
  else
    pass "_backstop_should_arm: a fresh beacon still suppresses the arm"
  fi
}

# --- 4b. the CLOCK half: no invented epochs ---------------------------------

# Stub `date +%s` for one call. A shell function shadows the PATH binary in this
# shell and every subshell it forks, which is the only way to reproduce a
# polluted clock read deterministically. Other `date` formats pass through.
with_stub_clock() {  # <emitted-clock> <fn> [args...]
  local emitted=$1; shift
  local rc
  eval 'date() { case "${1:-}" in +%s) printf "%s" "$FM_TEST_STUB_CLOCK" ;; *) command date "$@" ;; esac; }'
  FM_TEST_STUB_CLOCK="$emitted" "$@"
  rc=$?
  unset -f date
  return $rc
}

# The clock gets the same treatment as the mtime, with one difference: there is
# no safe fallback EPOCH. A fabricated 0 is a 1970 timestamp, and it propagates
# into ages and into marker files, so _now refuses instead.
test_now_refuses_to_invent_an_epoch() {
  local got rc
  got=$(with_stub_clock "1784687492" _now 2>/dev/null)
  assert_out "$got" "1784687492" "a clean clock read passes through"
  got=$(with_stub_clock "$(printf '1784687492\n%s' "$STUCK_BUFFER_LINE")" _now 2>/dev/null)
  assert_out "$got" "1784687492" "a buffer-polluted clock recovers the real epoch"
  rc=0
  got=$(with_stub_clock "wat" _now 2>/dev/null) || rc=$?
  assert_out "$got" "" "an unusable clock yields no epoch at all"
  [ "$rc" -ne 0 ] || fail "_now reported success on an unusable clock read"
  pass "_now: an unusable clock refuses rather than fabricating an epoch"
}

test_age_since_reads_an_unusable_clock_as_very_old() {
  local got
  got=$(with_stub_clock "wat" _age_since 1784687492 'stale-marker:x' 2>/dev/null)
  assert_out "$got" "999999" "an unusable clock reads as very old, never as fresh"
  got=$(_age_since "" 'stale-marker:x' 2>/dev/null)
  assert_out "$got" "999999" "an unreadable stored epoch reads as very old"
  got=$(with_stub_clock "1000" _age_since "1500" 'stale-marker:x' 2>/dev/null)
  assert_out "$got" "0" "a future epoch is fresh, never a negative age"
  pass "_age_since: an unusable epoch or clock biases very old, and never goes negative"
}

# The stranded-wake poke is the ONLY mechanism that re-invokes the LLM session.
# With a fabricated epoch of 0 the queue age came out hugely negative and the
# poke silently never fired - failing toward silence in the exact path this
# hardening exists to protect.
test_poke_still_fires_when_the_clock_read_is_unusable() {
  local state now
  state=$(new_state poke-badclock)
  now=$(date +%s)
  printf '%s\t1\tsignal\tfoo-x1\tfoo-x1 needs-decision\n' "$(( now - 3600 ))" \
    > "$state/.wake-queue"
  if with_stub_clock "wat" poke_should_fire "$state" 2>/dev/null; then
    pass "poke_should_fire: an unusable clock still pokes the stranded session"
  else
    fail "poke_should_fire stayed silent on an unusable clock (fails toward silence)"
  fi
}

# A garbage FM_POKE_AFTER_SECS must fall back, not abort the comparison and take
# the whole poke down with it.
test_poke_survives_garbage_poke_env() {
  local state now
  state=$(new_state poke-badenv)
  now=$(date +%s)
  printf '%s\t1\tsignal\tfoo-x1\tfoo-x1 needs-decision\n' "$(( now - 3600 ))" \
    > "$state/.wake-queue"
  if FM_POKE_AFTER_SECS="  " FM_POKE_MIN_INTERVAL=" x " poke_should_fire "$state" 2>/dev/null; then
    pass "poke_should_fire: garbage poke thresholds fall back instead of aborting"
  else
    fail "garbage poke thresholds suppressed the stranded-wake poke"
  fi
}

# Markers that are read back BY CONTENT (the stale marker, the escalation-since
# sidecar) must never receive a fabricated epoch: it does not merely mislead
# once, it persists and is believed for as long as the marker lives.
test_stamp_now_never_writes_a_fabricated_epoch() {
  local state f rc
  state=$(new_state stamp-now)
  f="$state/marker"
  with_stub_clock "1784687492" _stamp_now "$f" 2>/dev/null \
    || fail "_stamp_now failed on a clean clock read"
  assert_out "$(cat "$f")" "1784687492" "a clean clock is stamped verbatim"
  # The on-disk format stays byte-identical to what `date +%s > marker` wrote.
  assert_out "$(wc -c < "$f" | tr -d '[:space:]')" "11" "the stamp keeps its trailing newline"
  rc=0
  with_stub_clock "wat" _stamp_now "$f" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "_stamp_now reported success on an unusable clock read"
  assert_out "$(cat "$f")" "" "an unusable clock truncates rather than fabricating an epoch"
  # The mtime-only throttles still work off the truncated file, and a content
  # reader sees the very-old sentinel instead of a believable 1970 timestamp.
  [ -e "$f" ] || fail "_stamp_now removed the marker instead of truncating it"
  assert_out "$(_age_since "$(cat "$f")" 'stale-marker:x' 2>/dev/null)" "999999" \
    "the truncated stamp reads as the sentinel, not as a 1970 epoch"
  pass "_stamp_now: an unusable clock never persists a fabricated epoch"
}

# End to end for the same defect: a stale marker recorded under a broken clock
# must not later escalate a garbage "stale persisted 1784687492s" wedge line.
test_stale_marker_never_stores_a_fabricated_epoch() {
  local state marker age
  state=$(new_state stale-marker-badclock)
  with_stub_clock "wat" stale_marker_record "sess:fm-foo-x1" "$state" 2>/dev/null || true
  marker="$state/.subsuper-stale-foo-x1"
  [ -e "$marker" ] || fail "stale_marker_record wrote no marker at all"
  assert_no_grep "1970" "$marker" "the marker holds no fabricated epoch"
  age=$(_age_since "$(cat "$marker" 2>/dev/null || true)" 'stale-marker:foo-x1' 2>/dev/null)
  assert_out "$age" "999999" "the marker ages to the sentinel, not to ~1.78e9 seconds"
  pass "stale_marker_record: a broken clock cannot persist a bogus idle-since epoch"
}

# --- 4c. THROTTLES under an unusable clock ----------------------------------

# The very-old sentinel is right for a liveness age, and it is right here too.
# "Has enough time passed since the last arm?" cannot be answered without a
# clock, and the answer the daemon wants when it cannot be answered is "act":
# the thing that made the clock unreadable is the full disk, so a rate limit
# that still held there would be quietest during exactly the incident the gated
# action exists to survive.
test_throttle_fires_every_call_on_an_unusable_clock() {
  local state marker i fired=0
  state=$(new_state throttle-badclock)
  marker="$state/.subsuper-last-backstop-arm"
  : > "$marker"
  for (( i = 0; i < 12; i++ )); do
    if with_stub_clock "wat" throttle_ready "$marker" 30 2>/dev/null; then
      fired=$(( fired + 1 ))
    fi
  done
  assert_out "$fired" "12" "an unusable clock must not silence or slow a throttled action"
  pass "throttle_ready: an unusable clock fires the action rather than holding it shut"
}

# The wall-clock path is unchanged, and a marker that has never been written
# still fires at once: a throttle must not delay the FIRST run of an action.
test_throttle_uses_the_wall_clock_when_it_is_readable() {
  local state marker
  state=$(new_state throttle-goodclock)
  marker="$state/.subsuper-last-backstop-arm"
  throttle_ready "$marker" 30 2>/dev/null \
    || fail "an absent marker (action never ran) was throttled"
  : > "$marker"
  if with_stub_clock 1784687492 with_stub_mtime 1784687490 \
       throttle_ready "$marker" 30 2>/dev/null; then
    fail "a 2-second-old marker passed a 30-second throttle"
  fi
  with_stub_clock 1784687492 with_stub_mtime 1784687400 \
    throttle_ready "$marker" 30 2>/dev/null \
    || fail "a 92-second-old marker failed a 30-second throttle"
  pass "throttle_ready: a readable clock still throttles by wall time"
}

# Drive <ticks> present-mode ticks through the real backstop and count the arms
# it detached. <clock> is the stubbed `date +%s` reading, "wat" (unusable) by
# default; pass a real epoch to drive the same ticks on a readable clock, or
# "intermittent" plus a readable epoch to alternate an unusable tick with a
# readable one.
_count_backstop_arms() {  # <state> <ticks> [clock] [readable-epoch] -> arms observed
  local state=$1 ticks=$2 clock=${3:-wat} readable=${4:-} armlog armbin i n prev stable tick_clock
  armlog="$TMP_ROOT/$(basename "$state").armed"
  armbin="$TMP_ROOT/$(basename "$state").arm.sh"
  mkdir -p "$TMP_ROOT"
  : > "$armlog"
  cat > "$armbin" <<SH
#!/usr/bin/env bash
echo armed >> "$armlog"
SH
  chmod +x "$armbin"
  (
    FM_WATCH_ARM_BIN="$armbin"
    for (( i = 0; i < ticks; i++ )); do
      tick_clock=$clock
      # The pollution lands in SOME later command substitution, not in all of
      # them, so the field failure alternates rather than sticking: the daemon's
      # own stderr shows the aborts interleaved with ordinary ticks.
      if [ "$clock" = intermittent ]; then
        if [ $(( i % 2 )) -eq 0 ]; then tick_clock=wat; else tick_clock=$readable; fi
      fi
      with_stub_clock "$tick_clock" ensure_watcher_backstop "$state" 2>/dev/null
    done
  )
  # The arms are detached (double-forked), so their writes land after the tick
  # loop returns. Wait for the count to stop MOVING rather than for the first
  # write alone: a case that asserts an exact number would otherwise be counting
  # the race instead of the behaviour.
  prev=-1; stable=0; n=0
  for (( i = 0; i < 60; i++ )); do
    # `grep -c` PRINTS 0 and EXITS 1 on no match, so `|| echo 0` would emit a
    # two-line "0\n0" and turn the caller's assertion into the very multi-line
    # abort this suite exists to pin.
    n=$(grep -c armed "$armlog" 2>/dev/null) || n=0
    if [ "$n" -gt 0 ] && [ "$n" -eq "$prev" ]; then
      stable=$(( stable + 1 ))
      [ "$stable" -ge 3 ] && break
    else
      stable=0
    fi
    prev=$n
    sleep 0.1
  done
  printf '%s' "$n"
}

# A readable clock is the only state in which there is a rate to limit, so BOTH
# of the wall-clock throttle's bounds are pinned here, in one case: it must not
# arm twice inside one FM_BACKSTOP_ARM_THROTTLE window, and it must arm again
# once that window has passed. A case that pinned one bound could not see a
# failure at the other, which is how this rate limit regressed once per
# direction.
#
# The stubbed epoch is derived from REAL time, so the throttle compares it
# against the marker's real mtime and runs genuine wall-clock arithmetic. A fixed
# epoch older than that mtime would make every age negative, clamp it to 0 and
# leave the readable path unable to fire at all: an upper bound over a path that
# never fires measures nothing, so the first assertion below is the positive
# control that says the path is observable.
test_backstop_bounds_on_a_readable_clock() {
  local state now fired
  state=$(new_state backstop-readable-bounds)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  now=$(date +%s)
  # The first of these 36 ticks has no marker to throttle against, so it must
  # arm; the 35 that follow are all inside the 30-second window, so none may.
  fired=$(_count_backstop_arms "$state" 36 "$now")
  [ "$fired" -gt 0 ] || fail "the readable path never armed at all, so this case bounds nothing"
  assert_out "$fired" "1" "the backstop armed more than once inside one throttle window"
  # ... and the window expiring must let it arm again, or the upper bound above
  # would be satisfied by a backstop that had simply stopped working.
  fired=$(_count_backstop_arms "$state" 1 "$(( now + 600 ))")
  assert_out "$fired" "1" "the backstop stayed quiet after its throttle window had passed"
  pass "ensure_watcher_backstop: a readable clock arms once per throttle window, and again after it"
}

# The backstop is the regression's own path: with work in flight, a stale beacon
# and an unreadable clock, there is no elapsed time to throttle by, so it must
# keep arming on every tick rather than fall quiet.
test_backstop_arms_every_tick_on_an_unusable_clock() {
  local state fired
  state=$(new_state backstop-badclock-throttle)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  # A marker from an earlier arm, so the throttle is the only thing that could
  # suppress these ticks.
  : > "$state/.subsuper-last-backstop-arm"
  fired=$(_count_backstop_arms "$state" 12)
  [ "$fired" -gt 0 ] || fail "the backstop never armed under an unusable clock (fails toward silence)"
  assert_out "$fired" "12" "an unusable clock left the backstop arming less often than every tick"
  pass "ensure_watcher_backstop: an unusable clock keeps arming, never falls quiet"
}

# An unreadable clock is not a state the daemon sits in cleanly: the undrained
# buffer is flushed into SOME later command substitution, so _now fails on one
# tick and reads fine on the next. That is the shape the field produced, and both
# halves must behave: every unreadable tick arms (never toward silence) and every
# readable tick is throttled by the marker the previous tick stamped.
test_backstop_is_bounded_on_an_intermittent_clock() {
  local state fired
  state=$(new_state backstop-intermittent-clock)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  # Derived from real time for the same reason as the readable-clock case: the
  # readable ticks must run real wall-clock arithmetic against the marker's real
  # mtime, not a fixed epoch that clamps every age to zero.
  fired=$(_count_backstop_arms "$state" 36 intermittent "$(date +%s)")
  [ "$fired" -gt 0 ] || fail "the backstop armed $fired time(s) in 36 intermittent-clock ticks (fails toward silence)"
  assert_out "$fired" "18" "the intermittent clock did not arm on its unreadable ticks and throttle on its readable ones"
  pass "ensure_watcher_backstop: an intermittent clock arms on every unreadable tick and throttles on every readable one"
}

# --- 4c-2. the throttle under the FULL DISK that made the clock unreadable ---
#
# Nothing the throttle needs may live on that disk. It keeps no state of its own
# at all now, so the two shapes a full disk produces are driven below against an
# unwritable state dir: a marker that cannot be created, and one that exists but
# cannot be re-stamped. Both assert the same observable behaviour, that the
# backstop keeps arming, on behaviour rather than on any internal file, so they
# are meaningful against any implementation.

# Returns 0 when <dir> genuinely refuses writes. Running as root defeats the
# simulation, and a test that silently passes because it never reproduced the
# condition is worthless, so the caller reports the skip out loud instead.
_dir_is_unwritable() {  # <dir>
  local probe="$1/.write-probe"
  if : 2>/dev/null > "$probe"; then rm -f "$probe" 2>/dev/null || true; return 1; fi
  return 0
}

test_backstop_still_arms_when_the_state_dir_cannot_be_written() {
  local state fired
  state=$(new_state backstop-fulldisk-nomarker)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  chmod 555 "$state"
  if ! _dir_is_unwritable "$state"; then
    chmod 755 "$state"
    pass "ensure_watcher_backstop: unwritable-state case not simulable here (writes still succeed, e.g. running as root)"
    return 0
  fi
  # No throttle marker can be created (_stamp_now's write hits the same wall a
  # full disk does), so the throttle has nothing to measure against at all.
  fired=$(_count_backstop_arms "$state" 12)
  chmod 755 "$state"
  [ "$fired" -gt 0 ] || fail "the backstop armed $fired time(s) in 12 ticks on a full disk (fails toward silence)"
  assert_out "$fired" "12" "an uncreatable marker left the backstop arming less often than every tick"
  pass "ensure_watcher_backstop: an uncreatable marker still arms every tick"
}

test_backstop_still_arms_when_a_stale_marker_cannot_be_refreshed() {
  local state fired
  state=$(new_state backstop-fulldisk-marker)
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  # The marker exists from an earlier arm, so this is the other half: the clock
  # is unreadable, the marker cannot be re-stamped, and neither may pin the arm.
  : > "$state/.subsuper-last-backstop-arm"
  chmod 555 "$state"
  if ! _dir_is_unwritable "$state"; then
    chmod 755 "$state"
    pass "ensure_watcher_backstop: unrefreshable-marker case not simulable here (writes still succeed, e.g. running as root)"
    return 0
  fi
  fired=$(_count_backstop_arms "$state" 12)
  chmod 755 "$state"
  [ "$fired" -gt 0 ] || fail "the backstop armed $fired time(s) in 12 ticks with an unrefreshable marker (fails toward silence)"
  assert_out "$fired" "12" "an unrefreshable marker left the backstop arming less often than every tick"
  pass "ensure_watcher_backstop: a marker that cannot be re-stamped still arms every tick"
}

# One housekeeping tick against a supervisor target that cannot resolve, so
# every delivery attempt fails and the max-defer escape is the path under test.
_wedge_housekeep() {  # <state> <log> [stub-clock]
  if [ -n "${3:-}" ]; then
    with_stub_clock "$3" _wedge_housekeep "$1" "$2"
    return
  fi
  LOG="$2" FM_SUPERVISOR_TARGET="fm-no-such-session:99.99" \
    FM_ESCALATE_BATCH_SECS=9999999 FM_MAX_DEFER_SECS=300 housekeeping "$1"
}

# Count the wedge alarms recorded in a daemon log.
_wedge_alarm_count() {  # <log>
  local n
  n=$(grep -c "escalation undelivered" "$1" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# The wedge re-alarm is the second throttle the sentinel governs, and it is gated
# in exactly ONE place, housekeeping's max-defer escape, so this drives the REAL
# nested path (housekeeping calling inject_wedge_alarm) rather than the alarm on
# its own. On a readable clock it must keep the max-defer cadence: once, then not
# again until that window has passed.
test_wedge_realarm_keeps_its_cadence_on_a_readable_clock() {
  local state log now i
  state=$(new_state wedge-cadence)
  log="$state/daemon.log"
  printf 'needs-decision: pick A\n' > "$state/.subsuper-escalations"
  afk_enter "$state"
  # No .since sidecar, so the buffered age is the very-old sentinel, past any
  # max-defer window; the wedge marker's own age is the only thing gating here.
  now=$(date +%s)
  (
    for (( i = 0; i < 12; i++ )); do
      _wedge_housekeep "$state" "$log" "$now"
    done
  ) >/dev/null 2>&1
  assert_out "$(_wedge_alarm_count "$log")" "1" "the wedge alarm re-fired inside one max-defer window"
  ( _wedge_housekeep "$state" "$log" "$(( now + 600 ))" ) >/dev/null 2>&1
  assert_out "$(_wedge_alarm_count "$log")" "2" "the wedge alarm stayed silent after its max-defer window had passed"
  pass "housekeeping: the wedge re-alarm keeps its max-defer cadence on the real nested path"
}

# The same path with no clock at all. There is no window to wait out, and the
# incident the alarm announces is the one that took the clock away, so it must
# keep alarming rather than quieten.
test_wedge_realarm_keeps_alarming_on_an_unusable_clock() {
  local state log i
  state=$(new_state wedge-nested)
  log="$state/daemon.log"
  printf 'needs-decision: pick A\n' > "$state/.subsuper-escalations"
  afk_enter "$state"
  (
    for (( i = 0; i < 12; i++ )); do
      _wedge_housekeep "$state" "$log" "wat"
    done
  ) >/dev/null 2>&1
  assert_out "$(_wedge_alarm_count "$log")" "12" "an unusable clock made the wedge alarm quieter than every tick"
  pass "housekeeping: the wedge re-alarm keeps sounding while the clock is unreadable"
}

# A throttle's marker must not outlive the episode it stands for. The wedge
# marker is CLEARED the moment a digest is finally delivered, which ends that
# episode, so a later wedge is a new episode and must alarm at once. Everything
# here runs on a readable clock and a healthy disk: an alarm delayed by
# bookkeeping carried over from the previous episode is the same defect as one
# delayed by a full disk, reached from the healthy path.
test_wedge_realarm_fires_again_after_a_delivered_digest() {
  local state log
  state=$(new_state wedge-episodes)
  log="$state/daemon.log"
  afk_enter "$state"
  printf 'needs-decision: pick A\n' > "$state/.subsuper-escalations"
  (
    local saved
    saved=$(declare -f inject_msg)
    # Episode 1: no supervisor pane accepts the digest, so the max-defer escape
    # alarms and writes the wedge marker.
    _wedge_housekeep "$state" "$log"
    # The digest finally lands. escalate_flush's own success path ends the
    # episode: buffer cleared, wedge marker gone.
    inject_msg() { return 0; }
    LOG="$log" escalate_flush "$state"
    eval "$saved"
    # Episode 2: a fresh undeliverable escalation, no .since sidecar, so its age
    # is past any max-defer window again.
    printf 'needs-decision: pick B\n' > "$state/.subsuper-escalations"
    rm -f "$state/.subsuper-escalations.since"
    _wedge_housekeep "$state" "$log"
  ) >/dev/null 2>&1
  [ -e "$state/.subsuper-inject-wedged" ] || fail "the second wedge wrote no alarm marker at all"
  assert_out "$(_wedge_alarm_count "$log")" "2" "the second wedge alarmed at once instead of waiting out the previous episode"
  pass "housekeeping: a delivered digest lets the next wedge alarm immediately"
}

# --- 4d. captain-facing text never prints a sentinel as a duration ----------

# "stale persisted 1784687492s" was the pre-fix nonsense the captain called out.
# 999999s is the same class of fabricated-looking duration, just smaller: it
# reads exactly like a measurement and would wake the captain for nothing.
test_age_phrase_renders_the_sentinel_as_an_explicit_unknown() {
  assert_out "$(_age_phrase 461)" "461s" "a real measurement still prints as a duration"
  assert_out "$(_age_phrase 0)" "0s" "a zero age still prints as a duration"
  case "$(_age_phrase 999999)" in
    *999999*) fail "the very-old sentinel printed as a fabricated-looking duration" ;;
    *unknown*) : ;;
    *) fail "the very-old sentinel did not render as an explicit unknown" ;;
  esac
  pass "_age_phrase: the sentinel renders as an explicit unknown, never as a duration"
}

test_wedge_alarm_text_carries_no_sentinel_duration() {
  local state log marker
  state=$(new_state wedge-text)
  log="$state/daemon.log"
  marker="$state/.subsuper-inject-wedged"
  printf 'buffered item\n' > "$state/.subsuper-escalations"
  ( LOG="$log"; inject_wedge_alarm "$state" 999999 ) >/dev/null 2>&1
  assert_no_grep "999999s" "$log" "the wedge log line printed no fabricated duration"
  assert_grep "unknown" "$log" "the wedge log line names the duration as unknown"
  assert_no_grep "999999s" "$marker" "the wedge marker printed no fabricated duration"
  pass "inject_wedge_alarm: an unmeasurable age is reported as unknown, not as 999999s"
}

# --- 4e. numeric ENV overrides are coerced like every other input -----------

test_env_int_coerces_malformed_overrides() {
  local got
  unset FM_TEST_ENVINT 2>/dev/null || true
  got=$(_env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "300" "an unset override takes the default"
  got=$(FM_TEST_ENVINT="" _env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "300" "an empty override takes the default"
  got=$(FM_TEST_ENVINT="  " _env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "300" "a whitespace-only override takes the default"
  got=$(FM_TEST_ENVINT=" 45 " _env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "45" "a padded override coerces to a bare integer"
  got=$(FM_TEST_ENVINT="0" _env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "0" "zero is a value, not a fallback"
  got=$(FM_TEST_ENVINT="90s" _env_int FM_TEST_ENVINT 300 2>/dev/null)
  assert_out "$got" "300" "a unit-suffixed override falls back rather than aborting"
  pass "_env_int: malformed numeric overrides fall back instead of aborting"
}

# One override is fractional seconds, so it cannot go through _as_int (which
# would reject its own 0.5 default). It must not stay raw either: `sleep` exits
# immediately on a malformed argument, turning a paced retry into a spin.
test_env_secs_coerces_malformed_fractional_overrides() {
  local got
  unset FM_TEST_ENVSECS 2>/dev/null || true
  got=$(_env_secs FM_TEST_ENVSECS 0.5 2>/dev/null)
  assert_out "$got" "0.5" "an unset override takes the fractional default"
  got=$(FM_TEST_ENVSECS=" 0.25 " _env_secs FM_TEST_ENVSECS 0.5 2>/dev/null)
  assert_out "$got" "0.25" "a padded fractional override coerces to a bare decimal"
  got=$(FM_TEST_ENVSECS="2" _env_secs FM_TEST_ENVSECS 0.5 2>/dev/null)
  assert_out "$got" "2" "a plain integer is a valid delay"
  got=$(FM_TEST_ENVSECS="0.5s" _env_secs FM_TEST_ENVSECS 0.5 2>/dev/null)
  assert_out "$got" "0.5" "a unit-suffixed override falls back rather than spinning sleep"
  got=$(FM_TEST_ENVSECS="1.2.3" _env_secs FM_TEST_ENVSECS 0.5 2>/dev/null)
  assert_out "$got" "0.5" "a two-dot value falls back rather than spinning sleep"
  got=$(FM_TEST_ENVSECS="$(printf '0.5\n%s' "$STUCK_BUFFER_LINE")" \
          _env_secs FM_TEST_ENVSECS 9 2>/dev/null)
  assert_out "$got" "0.5" "a buffer-polluted override recovers its real first-line value"
  pass "_env_secs: malformed fractional overrides fall back instead of spinning sleep"
}

# The warning path must not be able to trip the fault it reports: a malformed
# FM_INT_WARN_INTERVAL_MIN would make `find -mmin` error out, disengaging the
# throttle and putting the unbounded stderr flood back.
test_int_warn_throttle_survives_a_garbage_interval() {
  local state first second
  state=$(new_state intwarn-badenv)
  first="$state/first.err"
  second="$state/second.err"
  (
    FM_DAEMON_WARN_STATE="$state" FM_INT_WARN_INTERVAL_MIN=" x "
    export FM_DAEMON_WARN_STATE FM_INT_WARN_INTERVAL_MIN
    _as_int "nope" 0 'throttle-probe' >/dev/null 2>"$first"
    _as_int "nope" 0 'throttle-probe' >/dev/null 2>"$second"
  )
  assert_grep "unreadable numeric value" "$first" "the first occurrence still warns on stderr"
  [ -s "$second" ] && fail "a garbage warn interval disengaged the stderr throttle"
  pass "_int_warn: a garbage throttle interval falls back instead of flooding stderr"
}

# --- 5. trim_log: the reported line -----------------------------------------

# The reported error site fed `[` the raw padded `wc -c` output. Exercise the
# real function with a log big enough to trim and assert it neither aborts nor
# loses the trim.
test_trim_log_tolerates_padded_wc_output() {
  local dir err lines
  dir=$(new_state trimlog)
  err="$dir/trimlog.err"
  # 500 lines is comfortably over a 200-byte cap and over KEEP_LINES=10.
  awk 'BEGIN{for(i=1;i<=500;i++) print "[ts] daemon log line " i}' > "$dir/log"
  # Subshelled so LOG and the caps cannot reach any later case: the daemon's own
  # log() would start appending to this scratch log and quietly change what the
  # warning assertions below observe.
  ( LOG="$dir/log" FM_LOG_MAX_BYTES=200 FM_LOG_KEEP_LINES=10 trim_log ) 2>"$err"
  assert_no_grep "integer expression expected" "$err" "trim_log ran no aborted comparison"
  lines=$(wc -l < "$dir/log" | tr -d '[:space:]')
  assert_out "$lines" "10" "the oversized log was actually trimmed to KEEP_LINES"
  pass "trim_log: the padded wc size comparison trims instead of aborting"
}

# A garbage size cap must not abort trim_log either.
test_trim_log_survives_garbage_max_env() {
  local dir err
  dir=$(new_state trimlog-badenv)
  err="$dir/trimlog-badenv.err"
  printf 'one line\n' > "$dir/log"
  ( LOG="$dir/log" FM_LOG_MAX_BYTES="  " trim_log ) 2>"$err"
  assert_no_grep "integer expression expected" "$err" "a garbage cap does not abort trim_log"
  pass "trim_log: a garbage FM_LOG_MAX_BYTES falls back instead of aborting"
}

# The cap has to ride the housekeeping TICK, not a watcher wake. _int_warn logs
# every occurrence, away mode's other trim only runs after a wake, and a quiet
# fleet can be hours from one - so a persistently polluted read would pile up
# megabytes of daemon log during the very full-disk condition that caused it.
test_housekeeping_tick_caps_the_daemon_log() {
  local dir lines
  dir=$(new_state housekeep-trim)
  awk 'BEGIN{for(i=1;i<=500;i++) print "[ts] daemon log line " i}' > "$dir/log"
  ( LOG="$dir/log" FM_LOG_MAX_BYTES=200 FM_LOG_KEEP_LINES=10 housekeeping "$dir" ) >/dev/null 2>&1
  lines=$(wc -l < "$dir/log" | tr -d '[:space:]')
  assert_out "$lines" "10" "the housekeeping tick trimmed the oversized daemon log"
  pass "housekeeping: the tick caps the daemon log without waiting for a wake"
}

# --- 6. THE OUTERMOST CAPTURE: the reported line itself ---------------------
#
# Everything above stubs a value INSIDE a helper and proves the helper coerces
# it. That is not where the reported failure happened, and no case above can
# see the reported failure, which is why it survived a round of hardening.
#
# The reported line is `[ "$(_in_flight_count "$state")" -gt 0 ]`, the first
# line of _backstop_should_arm. The daemon's own stderr recorded the operand
# that aborted there:
#   bin/fm-supervise-daemon.sh: line 725: [: ...watcher beacon stale 461s with
#   3 in flight; launching backstop re-arm
#   3: integer expression expected
# The stale log line, then a newline, then "3" - and the log text embedded in it
# says "with 3 in flight", so that trailing 3 is the counter's OWN real output
# with the stuck buffer prepended. The value was already clean when the counter
# printed it; the pollution landed on the CAPTURE. A coercion that returns on
# stdout cannot close that, because its result has to cross a $( ) to be read.
#
# So these cases stub the producer's stdout - the outermost capture's content -
# and require the decision to survive it. They fail against a daemon whose
# decisions read their operands through $( ), and pass against one whose
# decisions read them from variables.

# Replace one function's stdout for the duration of a single call, and restore
# it afterwards. Used to put the field's exact polluted value on the wire that
# the pre-fix code captured.
with_stub_stdout() {  # <fn-name> <emitted-stdout> <fn> [args...]
  local name=$1 emitted=$2; shift 2
  local saved rc
  saved=$(declare -f "$name")
  eval "$name() { printf '%s' \"\$FM_TEST_STUB_STDOUT\"; }"
  FM_TEST_STUB_STDOUT="$emitted" "$@"
  rc=$?
  eval "$saved"
  return $rc
}

# The 2026-07-15 operand, exactly: the stale log line, a newline, and the real
# in-flight count of 3. Three metas are present too, so the decision is right
# for the right reason once the capture is gone - the fixed daemon counts them
# itself instead of reading the stub, and must still arm.
test_backstop_arms_when_the_in_flight_capture_is_polluted() {
  local state err i
  state=$(new_state backstop-outermost)
  err="$state/backstop-outermost.err"
  for i in 1 2 3; do
    fm_write_meta "$state/foo-x$i.meta" "window=sess:fm-foo-x$i" "kind=ship"
  done
  # No beacon file at all: the age is the very-old sentinel, so the ONLY thing
  # that can suppress the arm is an aborted comparison.
  if with_stub_stdout _in_flight_count "$(printf '%s\n3' "$STUCK_BUFFER_LINE")" \
       _backstop_should_arm "$state" 2>"$err"; then
    :
  else
    fail "backstop did not arm when the in-flight capture carried the stuck buffer"
  fi
  assert_no_grep "integer expression expected" "$err" \
    "the in-flight comparison ran without aborting"
  pass "_backstop_should_arm: the reported in-flight operand no longer aborts the decision"
}

# The same boundary, one operand further along: the beacon age. Pre-fix this was
# `age=$(_file_age ...)`, so a flush on that capture aborted the grace
# comparison and returned "no arm needed" on a 59-minute-stale beacon.
test_backstop_arms_when_the_beacon_age_capture_is_polluted() {
  local state err
  state=$(new_state backstop-outermost-age)
  err="$state/backstop-outermost-age.err"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  if with_stub_stdout _file_age "$(printf '3540\n%s' "$STUCK_BUFFER_LINE")" \
       _backstop_should_arm "$state" 2>"$err"; then
    :
  else
    fail "backstop did not arm when the beacon-age capture carried the stuck buffer"
  fi
  assert_no_grep "integer expression expected" "$err" \
    "the grace comparison ran without aborting"
  pass "_backstop_should_arm: a polluted beacon-age capture no longer aborts the decision"
}

# And the third operand, the configured grace. Pre-fix this was
# `grace=$(_env_int ...)`, the right-hand side of the same comparison.
test_backstop_arms_when_the_grace_capture_is_polluted() {
  local state err
  state=$(new_state backstop-outermost-grace)
  err="$state/backstop-outermost-grace.err"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  if with_stub_stdout _env_int "$(printf '300\n%s' "$STUCK_BUFFER_LINE")" \
       _backstop_should_arm "$state" 2>"$err"; then
    :
  else
    fail "backstop did not arm when the grace capture carried the stuck buffer"
  fi
  assert_no_grep "integer expression expected" "$err" \
    "the grace comparison ran without aborting"
  pass "_backstop_should_arm: a polluted grace capture no longer aborts the decision"
}

# The stranded-wake poke is the one mechanism that re-invokes the LLM session,
# so its operands get the same treatment: a polluted queue-age or threshold
# capture must not turn the poke into silence.
test_poke_fires_when_its_operand_captures_are_polluted() {
  local state err now
  state=$(new_state poke-outermost)
  err="$state/poke-outermost.err"
  now=$(date +%s)
  printf '%s\t1\tsignal\tfoo-x1\tsignal: foo-x1\n' "$(( now - 3600 ))" > "$state/.wake-queue"
  if with_stub_stdout _env_int "$(printf '120\n%s' "$STUCK_BUFFER_LINE")" \
       poke_should_fire "$state" 2>"$err"; then
    :
  else
    fail "the stranded-wake poke fell silent when a threshold capture was polluted"
  fi
  assert_no_grep "integer expression expected" "$err" \
    "the poke thresholds compared without aborting"
  pass "poke_should_fire: polluted threshold captures no longer silence the poke"
}

# The structural half of the same guarantee, and the half that keeps measuring
# something once the behavioural cases above can no longer reach the old code
# path: NO numeric comparison in a liveness decision may read an operand across
# a command substitution. Arithmetic expansion $(( )) is not a capture and is
# not matched. The compare count is asserted first as a positive control, so a
# renamed or gutted decision fails loudly instead of passing vacuously.
test_liveness_decisions_compare_only_variables() {
  local fn compares offenders
  for fn in _backstop_should_arm throttle_ready poke_should_fire handle_wake \
            housekeeping trim_log; do
    compares=$(declare -f "$fn" | grep -cE '\-(gt|ge|lt|le|eq|ne) ')
    [ "$compares" -gt 0 ] \
      || fail "$fn has no numeric comparison left, so this case measures nothing"
    offenders=$(declare -f "$fn" | grep -E '\-(gt|ge|lt|le|eq|ne) ' \
                  | grep -E '\$\([^(]' || true)
    [ -z "$offenders" ] \
      || fail "$fn compares a value read across a command substitution: $offenders"
  done
  pass "liveness decisions: every numeric operand is read from a variable, not a capture"
}

# --- 7. a cadence that feeds `sleep` must stay positive ---------------------
#
# Integer-ness is not enough for the values that pace the loops. `sleep 0`
# returns instantly and `sleep -1` fails outright, and either one spins the
# present-mode loop through ensure_watcher_backstop / poke_session / trim_log
# continuously. Zero and negative stay meaningful where they DISABLE a feature,
# so the floor belongs to the cadence read, not to the shared coercion.
# Driven WITHOUT a subshell: fail() exits, and an exit inside a subshell would
# leave the case reporting success on a failed assertion.
test_env_pos_int_floors_non_positive_cadences() {
  local got
  unset FM_TEST_CADENCE
  _env_pos_int_into got FM_TEST_CADENCE 30 2>/dev/null
  assert_out "$got" "30" "an unset cadence takes its default"
  FM_TEST_CADENCE=0 _env_pos_int_into got FM_TEST_CADENCE 30 2>/dev/null
  assert_out "$got" "30" "a zero cadence falls back to the default"
  [ "$got" -gt 0 ] || fail "a zero cadence produced a non-positive sleep argument"
  FM_TEST_CADENCE=-1 _env_pos_int_into got FM_TEST_CADENCE 30 2>/dev/null
  assert_out "$got" "30" "a negative cadence falls back to the default"
  [ "$got" -gt 0 ] || fail "a negative cadence produced a non-positive sleep argument"
  FM_TEST_CADENCE="  " _env_pos_int_into got FM_TEST_CADENCE 30 2>/dev/null
  assert_out "$got" "30" "a malformed cadence falls back to the default"
  FM_TEST_CADENCE=" 5 " _env_pos_int_into got FM_TEST_CADENCE 30 2>/dev/null
  assert_out "$got" "5" "a padded positive cadence is honoured"
  unset FM_TEST_CADENCE
  pass "_env_pos_int_into: a non-positive cadence cannot reach sleep"
}

# A non-positive cadence is announced, not silently corrected: the daemon is
# then pacing itself differently from what the operator configured.
test_env_pos_int_warns_on_a_non_positive_cadence() {
  local state err got
  state=$(new_state cadence-warn)
  err="$state/cadence.err"
  FM_TEST_CADENCE=0 _env_pos_int_into got FM_TEST_CADENCE 30 2>"$err"
  unset FM_TEST_CADENCE
  assert_grep "unreadable numeric value" "$err" "the non-positive cadence is announced"
  assert_grep "FM_TEST_CADENCE" "$err" "the warning names the override"
  pass "_env_pos_int_into: a non-positive cadence falls back loudly"
}

# The floor is only worth anything if the loops actually read through it, so the
# five overrides that reach a `sleep` are pinned to the positive-floor form.
test_sleep_cadences_are_read_through_the_positive_floor() {
  local var
  for var in FM_PRESENT_TICK FM_HOUSEKEEPING_TICK FM_SECONDMATE_PROBE_TICK \
             FM_CRASH_NORMAL_SLEEP FM_CRASH_BACKOFF FM_INJECT_FAIL_SLEEP; do
    grep -qE "_env_pos_int_into [A-Z_]+ $var " "$DAEMON" \
      || fail "$var still feeds sleep without a positive floor"
  done
  # The two overrides where a non-positive value legitimately DISABLES a feature
  # must keep reading it literally.
  for var in FM_ESCALATE_BATCH_SECS FM_MAX_DEFER_SECS; do
    grep -qE "_env_pos_int_into [A-Za-z_]+ $var " "$DAEMON" \
      && fail "$var was floored, which would break disabling it with 0"
  done
  pass "loop cadences: every sleep-feeding override is read with a positive floor"
}

test_as_int_strips_whitespace_padding
test_as_int_keeps_first_line_of_polluted_value
test_as_int_passes_clean_values_through
test_as_int_falls_back_loudly_on_garbage
test_as_int_rejects_near_misses
test_file_age_survives_padded_mtime
test_file_age_survives_polluted_mtime
test_file_age_unusable_reads_as_stale_not_fresh
test_backstop_still_arms_when_beacon_read_is_polluted
test_backstop_still_arms_when_beacon_read_is_padded
test_backstop_arms_when_beacon_read_is_unusable
test_backstop_survives_garbage_grace_env
test_backstop_still_quiet_on_a_fresh_beacon
test_now_refuses_to_invent_an_epoch
test_age_since_reads_an_unusable_clock_as_very_old
test_poke_still_fires_when_the_clock_read_is_unusable
test_poke_survives_garbage_poke_env
test_stamp_now_never_writes_a_fabricated_epoch
test_stale_marker_never_stores_a_fabricated_epoch
test_throttle_fires_every_call_on_an_unusable_clock
test_throttle_uses_the_wall_clock_when_it_is_readable
test_backstop_bounds_on_a_readable_clock
test_backstop_arms_every_tick_on_an_unusable_clock
test_backstop_is_bounded_on_an_intermittent_clock
test_backstop_still_arms_when_the_state_dir_cannot_be_written
test_backstop_still_arms_when_a_stale_marker_cannot_be_refreshed
test_wedge_realarm_keeps_its_cadence_on_a_readable_clock
test_wedge_realarm_keeps_alarming_on_an_unusable_clock
test_wedge_realarm_fires_again_after_a_delivered_digest
test_age_phrase_renders_the_sentinel_as_an_explicit_unknown
test_wedge_alarm_text_carries_no_sentinel_duration
test_env_int_coerces_malformed_overrides
test_env_secs_coerces_malformed_fractional_overrides
test_int_warn_throttle_survives_a_garbage_interval
test_trim_log_tolerates_padded_wc_output
test_trim_log_survives_garbage_max_env
test_housekeeping_tick_caps_the_daemon_log
test_backstop_arms_when_the_in_flight_capture_is_polluted
test_backstop_arms_when_the_beacon_age_capture_is_polluted
test_backstop_arms_when_the_grace_capture_is_polluted
test_poke_fires_when_its_operand_captures_are_polluted
test_liveness_decisions_compare_only_variables
test_env_pos_int_floors_non_positive_cadences
test_env_pos_int_warns_on_a_non_positive_cadence
test_sleep_cadences_are_read_through_the_positive_floor

echo "all fm-daemon-numeric tests passed"
