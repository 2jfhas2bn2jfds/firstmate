#!/usr/bin/env bash
# tests/fm-liveness-daemon.test.sh - the always-on (present-mode) liveness layer
# of bin/fm-supervise-daemon.sh: the watcher-liveness backstop decision + launch,
# the stranded-wake session-poke decision matrix + marked injection, and the
# secondmate dead-turn probe (detect / enqueue / dedupe / recovery). These are the
# NEW behaviors that run while afk is INACTIVE (plus the secondmate probe, which
# runs in both modes); the afk classification/injection units live in
# tests/fm-daemon.test.sh and are unchanged.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions once; its main loop is BASH_SOURCE-guarded.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-liveness-tests)

# Write an aged wake-queue with one entry whose epoch is <secs> ago.
_write_aged_queue() {  # <state> <secs-ago>
  local state=$1 secs=$2 epoch
  epoch=$(( $(date +%s) - secs ))
  printf '%s\t1\tsignal\tfoo-x1.status\tsignal: foo-x1.status\n' "$epoch" > "$state/.wake-queue"
}

# --- (behavior 2) watcher-liveness backstop ---------------------------------

test_backstop_arms_when_inflight_and_stale() {
  local dir state
  dir=$(make_supercase backstop-stale); state="$dir/state"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  # No beacon file => age is effectively infinite => stale beyond grace.
  if _backstop_should_arm "$state"; then
    pass "backstop arms with a task in flight and a stale/absent beacon"
  else
    fail "backstop did not arm with in-flight work and a stale beacon"
  fi
}

test_backstop_no_arm_when_beacon_fresh() {
  local dir state
  dir=$(make_supercase backstop-fresh); state="$dir/state"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  touch "$state/.last-watcher-beat"
  if _backstop_should_arm "$state"; then
    fail "backstop armed while the beacon was fresh"
  else
    pass "backstop stays quiet while the watcher beacon is fresh"
  fi
}

test_backstop_no_arm_when_no_inflight() {
  local dir state
  dir=$(make_supercase backstop-idle); state="$dir/state"
  # Stale/absent beacon but NO in-flight meta: nothing to supervise.
  if _backstop_should_arm "$state"; then
    fail "backstop armed with no task in flight"
  else
    pass "backstop stays quiet with no task in flight"
  fi
}

test_ensure_backstop_launches_home_scoped_arm() {
  local dir state armlog i
  dir=$(make_supercase backstop-launch); state="$dir/state"
  armlog="$dir/arm-invoked"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  cat > "$dir/fake-arm.sh" <<SH
#!/usr/bin/env bash
echo "armed state=\${FM_STATE_OVERRIDE:-none}" >> "$armlog"
SH
  chmod +x "$dir/fake-arm.sh"
  FM_WATCH_ARM_BIN="$dir/fake-arm.sh" ensure_watcher_backstop "$state"
  # The arm is launched detached (double-fork); poll for its marker.
  i=0
  while [ "$i" -lt 30 ] && [ ! -s "$armlog" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$armlog" ] || fail "ensure_watcher_backstop did not launch the arm"
  grep -q "state=$state" "$armlog" || fail "backstop arm not scoped to this home's state"
  [ -e "$state/.subsuper-last-backstop-arm" ] || fail "backstop did not record its throttle marker"
  pass "ensure_watcher_backstop launches a home-scoped detached arm and throttles"
}

test_ensure_backstop_throttles_second_launch() {
  local dir state armlog i n
  dir=$(make_supercase backstop-throttle); state="$dir/state"
  armlog="$dir/arm-invoked"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  cat > "$dir/fake-arm.sh" <<SH
#!/usr/bin/env bash
echo armed >> "$armlog"
SH
  chmod +x "$dir/fake-arm.sh"
  FM_WATCH_ARM_BIN="$dir/fake-arm.sh" ensure_watcher_backstop "$state"
  FM_WATCH_ARM_BIN="$dir/fake-arm.sh" ensure_watcher_backstop "$state"
  i=0
  while [ "$i" -lt 20 ] && [ ! -s "$armlog" ]; do sleep 0.1; i=$((i + 1)); done
  n=$(grep -c armed "$armlog" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "backstop launched $n times within the throttle window (expected 1)"
  pass "ensure_watcher_backstop throttles a burst to one launch"
}

# The backstop is an arm caller, so it must source this home's opted-in cadence
# configs before launching the arm (AGENTS.md sections 14 and 15); otherwise a
# recovery re-arm silently degrades X/email polling to the 300s default.
_run_backstop_cadence_case() {  # <case-name> <cadence-file> <cadence-body> <expect>
  local name=$1 cadence=$2 body=$3 expect=$4 dir state armlog i
  dir=$(make_supercase "$name"); state="$dir/state"
  armlog="$dir/arm-invoked"
  fm_write_meta "$state/foo-x1.meta" "window=sess:fm-foo-x1" "kind=ship"
  mkdir -p "$dir/config"
  printf '%s\n' "$body" > "$dir/config/$cadence"
  cat > "$dir/fake-arm.sh" <<SH
#!/usr/bin/env bash
echo "interval=\${FM_CHECK_INTERVAL:-none}" >> "$armlog"
SH
  chmod +x "$dir/fake-arm.sh"
  FM_HOME="$dir" FM_WATCH_ARM_BIN="$dir/fake-arm.sh" ensure_watcher_backstop "$state"
  i=0
  while [ "$i" -lt 30 ] && [ ! -s "$armlog" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$armlog" ] || fail "$name: ensure_watcher_backstop did not launch the arm"
  grep -q "interval=$expect" "$armlog" || fail "$name: backstop arm did not inherit FM_CHECK_INTERVAL=$expect from config/$cadence (got: $(cat "$armlog"))"
}

test_ensure_backstop_sources_x_cadence() {
  _run_backstop_cadence_case backstop-x-cadence x-mode.env 'export FM_CHECK_INTERVAL=30' 30
  pass "ensure_watcher_backstop sources config/x-mode.env so the re-armed watcher keeps the 30s cadence"
}

test_ensure_backstop_sources_email_cadence() {
  _run_backstop_cadence_case backstop-email-cadence email-mode.env 'export FM_CHECK_INTERVAL=60' 60
  pass "ensure_watcher_backstop sources config/email-mode.env so the re-armed watcher keeps the 60s cadence"
}

# --- (behavior 3) stranded-wake session poke --------------------------------

test_poke_fires_on_aged_queue() {
  local dir state
  dir=$(make_supercase poke-aged); state="$dir/state"
  _write_aged_queue "$state" 200
  if poke_should_fire "$state"; then
    pass "poke fires when a wake has sat stranded past the threshold"
  else
    fail "poke did not fire on an aged stranded queue"
  fi
}

test_poke_no_fire_on_fresh_queue() {
  local dir state
  dir=$(make_supercase poke-fresh); state="$dir/state"
  _write_aged_queue "$state" 10
  if poke_should_fire "$state"; then
    fail "poke fired on a freshly-queued wake (below threshold)"
  else
    pass "poke stays quiet while a queued wake is still fresh"
  fi
}

test_poke_no_fire_on_empty_queue() {
  local dir state
  dir=$(make_supercase poke-empty); state="$dir/state"
  if poke_should_fire "$state"; then
    fail "poke fired with an empty queue"
  else
    pass "poke stays quiet with an empty queue"
  fi
}

test_poke_dedupes_unchanged_queue() {
  local dir state
  dir=$(make_supercase poke-dedupe); state="$dir/state"
  _write_aged_queue "$state" 200
  # Record the CURRENT signature as already-poked; min-interval disabled so only
  # the signature dedupe can block.
  _poke_queue_sig "$state" > "$state/.subsuper-poke-sig"
  if FM_POKE_MIN_INTERVAL=0 poke_should_fire "$state"; then
    fail "poke re-fired for an unchanged stranded queue"
  else
    pass "poke dedupes an unchanged stranded queue (no re-poke)"
  fi
}

test_poke_refires_on_new_wake() {
  local dir state
  dir=$(make_supercase poke-newwake); state="$dir/state"
  _write_aged_queue "$state" 200
  # A stale/different signature means the queue changed since the last poke.
  printf 'OLD-SIGNATURE' > "$state/.subsuper-poke-sig"
  if FM_POKE_MIN_INTERVAL=0 poke_should_fire "$state"; then
    pass "poke re-permits after a new wake changes the queue signature"
  else
    fail "poke did not re-fire after the queue changed"
  fi
}

test_poke_throttled_by_min_interval() {
  local dir state
  dir=$(make_supercase poke-throttle); state="$dir/state"
  _write_aged_queue "$state" 200
  # Signature differs (would allow) but the marker was just written, so the
  # min-interval hard cap must still block.
  printf 'OLD-SIGNATURE' > "$state/.subsuper-poke-sig"
  if poke_should_fire "$state"; then
    fail "poke ignored the min-interval hard cap"
  else
    pass "poke honors the min-interval hard cap even when the queue changed"
  fi
}

test_poke_session_injects_marked_and_records_sig() {
  local dir state sent
  dir=$(make_supercase poke-inject); state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  printf '> \n' > "$dir/pane.txt"
  _write_aged_queue "$state" 200
  PATH="$dir/fakebin:$PATH" FM_SUPERVISOR_TARGET=fakepane \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.02 poke_session "$state"
  grep -q 'Supervision liveness' "$sent" || fail "poke_session did not inject a liveness poke"
  # The injected line carries the sentinel marker (0x1f), never a bare human line.
  grep -q "$(printf '\037')" "$sent" || fail "poke was not sentinel-marked"
  [ -s "$state/.subsuper-poke-sig" ] || fail "poke_session did not record the poked signature"
  pass "poke_session injects a marked liveness poke and records the signature"
}

test_poke_session_defers_when_pane_busy() {
  local dir state sent
  dir=$(make_supercase poke-busy); state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  printf 'thinking... esc to interrupt\n' > "$dir/pane.txt"
  _write_aged_queue "$state" 200
  PATH="$dir/fakebin:$PATH" FM_SUPERVISOR_TARGET=fakepane \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_SENT="$sent" \
    poke_session "$state"
  [ -s "$sent" ] && fail "poke_session injected into a busy pane"
  [ -e "$state/.subsuper-poke-sig" ] && fail "poke_session recorded a signature despite a deferred inject"
  pass "poke_session defers on a busy pane and does not mark the poke done"
}

# --- (behavior 4) secondmate dead-turn probe --------------------------------

test_secondmate_probe_enqueues_on_deadturn() {
  local dir state
  dir=$(make_supercase sm-deadturn); state="$dir/state"
  fm_write_secondmate_meta "$state/dm.meta" "$dir/home" "sess:fm-dm" "alpha"
  printf 'ran a step\nAPI Error: ConnectionRefused (Connection refused)\n> \n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    secondmate_deadturn_probe "$state"
  [ -s "$state/.wake-queue" ] || fail "dead-turn probe did not enqueue a wake"
  grep -q 'secondmate dead turn' "$state/.wake-queue" || fail "enqueued wake did not describe the dead turn"
  [ -e "$state/.subsuper-secondmate-deadturn-dm" ] || fail "dead-turn incident marker was not written"
  pass "secondmate probe enqueues a durable recovery wake on an idle pane showing a harness error"
}

test_secondmate_probe_dedupes_same_incident() {
  local dir state before after
  dir=$(make_supercase sm-dedupe); state="$dir/state"
  fm_write_secondmate_meta "$state/dm.meta" "$dir/home" "sess:fm-dm" "alpha"
  printf 'API Error: ConnectionRefused\n> \n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  before=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  after=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  [ "$before" = "$after" ] || fail "same dead-turn incident re-enqueued ($before -> $after)"
  pass "secondmate probe dedupes one wake per incident on the error line"
}

test_secondmate_probe_clears_marker_on_recovery() {
  local dir state
  dir=$(make_supercase sm-recover); state="$dir/state"
  fm_write_secondmate_meta "$state/dm.meta" "$dir/home" "sess:fm-dm" "alpha"
  printf 'API Error: ConnectionRefused\n> \n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  [ -e "$state/.subsuper-secondmate-deadturn-dm" ] || fail "precondition: incident marker not set"
  # Secondmate resumes work: a busy pane clears the incident marker.
  printf 'back to work... esc to interrupt\n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  [ -e "$state/.subsuper-secondmate-deadturn-dm" ] && fail "incident marker not cleared after recovery"
  pass "secondmate probe clears its incident marker once the pane recovers"
}

test_secondmate_probe_ignores_healthy_idle() {
  local dir state
  dir=$(make_supercase sm-idle); state="$dir/state"
  fm_write_secondmate_meta "$state/dm.meta" "$dir/home" "sess:fm-dm" "alpha"
  # Idle is the healthy resting state for a secondmate: no error signature.
  printf 'waiting for routed work\n> \n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  [ -s "$state/.wake-queue" ] && fail "healthy idle secondmate was flagged as a dead turn"
  pass "secondmate probe leaves a healthy idle secondmate alone"
}

test_secondmate_probe_ignores_non_secondmate() {
  local dir state
  dir=$(make_supercase sm-ship); state="$dir/state"
  fm_write_meta "$state/foo.meta" "window=sess:fm-foo" "kind=ship"
  printf 'API Error: ConnectionRefused\n> \n' > "$dir/pane.txt"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" secondmate_deadturn_probe "$state"
  [ -s "$state/.wake-queue" ] && fail "a non-secondmate task was probed for a dead turn"
  pass "secondmate probe scopes itself to kind=secondmate metas"
}

test_backstop_arms_when_inflight_and_stale
test_backstop_no_arm_when_beacon_fresh
test_backstop_no_arm_when_no_inflight
test_ensure_backstop_launches_home_scoped_arm
test_ensure_backstop_throttles_second_launch
test_ensure_backstop_sources_x_cadence
test_ensure_backstop_sources_email_cadence
test_poke_fires_on_aged_queue
test_poke_no_fire_on_fresh_queue
test_poke_no_fire_on_empty_queue
test_poke_dedupes_unchanged_queue
test_poke_refires_on_new_wake
test_poke_throttled_by_min_interval
test_poke_session_injects_marked_and_records_sig
test_poke_session_defers_when_pane_busy
test_secondmate_probe_enqueues_on_deadturn
test_secondmate_probe_dedupes_same_incident
test_secondmate_probe_clears_marker_on_recovery
test_secondmate_probe_ignores_healthy_idle
test_secondmate_probe_ignores_non_secondmate
