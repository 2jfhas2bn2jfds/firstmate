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

test_file_age_survives_padded_mtime() {
  local state now got
  state=$(new_state age-padded)
  : > "$state/.last-watcher-beat"
  now=$(date +%s)
  got=$(with_stub_mtime "  $(( now - 461 ))" _file_age "$state/.last-watcher-beat" 2>/dev/null)
  assert_out "$got" "461" "a padded mtime still yields the true age"
  pass "_file_age: a whitespace-padded mtime yields a bare integer age"
}

test_file_age_survives_polluted_mtime() {
  local state now got err
  state=$(new_state age-polluted)
  err="$state/age-polluted.err"
  : > "$state/.last-watcher-beat"
  now=$(date +%s)
  got=$(with_stub_mtime "$(printf '%s\n%s' "$(( now - 461 ))" "$STUCK_BUFFER_LINE")" \
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
  LOG="$dir/log" FM_LOG_MAX_BYTES=200 FM_LOG_KEEP_LINES=10 trim_log 2>"$err"
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
  LOG="$dir/log" FM_LOG_MAX_BYTES="  " trim_log 2>"$err"
  assert_no_grep "integer expression expected" "$err" "a garbage cap does not abort trim_log"
  pass "trim_log: a garbage FM_LOG_MAX_BYTES falls back instead of aborting"
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
test_trim_log_tolerates_padded_wc_output
test_trim_log_survives_garbage_max_env

echo "all fm-daemon-numeric tests passed"
