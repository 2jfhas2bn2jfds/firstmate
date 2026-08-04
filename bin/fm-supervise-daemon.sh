#!/usr/bin/env bash
# fm-supervise-daemon.sh - always-on liveness daemon + away-mode sub-supervisor.
#
# This one detached, home-scoped, singleton daemon runs in TWO modes, chosen per
# loop iteration by the presence of the durable away-mode flag state/.afk:
#
# AWAY MODE (state/.afk present) - the away-mode sub-supervisor (closes #27's P2),
# UNCHANGED. It wraps bin/fm-watch.sh: runs it as a child, classifies each wake
# reason, and either SELF-HANDLES the routine majority in bash (no firstmate turn)
# or ESCALATES a batched, distilled digest to the supervisor pane on
# captain-relevant events only. Routine signal/stale/heartbeat wakes cost zero
# firstmate context; only done/needs-decision/blocked/failed/persistent-wedge/
# check-output events reach the LLM, and even then as one pre-read digest per
# batch window. Injection is presence-gated: escalations inject ONLY while
# state/.afk exists. Any buffered escalations that remain while afk is off survive
# in state/.subsuper-escalations and flush on the next "while you were out"
# catch-up or when afk is re-entered.
#
# PRESENT MODE (state/.afk absent) - a MINIMAL always-on liveness layer. It does
# NOT own the watcher, classify, batch, or absorb wakes: the always-on triage in
# bin/fm-watch.sh owns that. It only closes the two single-points-of-failure that
# a firstmate-armed watcher alone cannot:
#   (2) Watcher-liveness backstop: if state/.last-watcher-beat goes stale beyond
#       FM_GUARD_GRACE while a task is in flight (the harness reaped firstmate's
#       watcher-arm task), re-arm the home-scoped watcher via fm-watch-arm.sh.
#   (3) Stranded-wake session poke: when actionable wakes sit in state/.wake-queue
#       older than FM_POKE_AFTER_SECS with no active turn, inject ONE marked
#       one-line poke telling firstmate to drain the queue and re-arm. This is
#       what re-invokes the LLM when the harness dropped the arm's wake exit.
# Behavior (4), the secondmate dead-turn probe, runs in BOTH modes (enqueue-only,
# so it is additive to afk). See the "always-on liveness layer" section below.
#
# IN-BAND SENTINEL MARKER. Every daemon injection is prefixed with
# FM_INJECT_MARK (ASCII unit separator, 0x1f) — a byte a human would never type
# at the start of a message. Firstmate's contract: a message that starts with
# the marker is an internal escalation (stay afk); a message without it means
# the captain is back (exit afk, flush catch-up, resume per-wake responsiveness).
# The marker and the busy-guard solve the same problem — the daemon and the
# human share one input channel — so they live together under /afk.
#
# Reliability model (see the /afk skill):
#   - Nothing is lost in away mode: while state/.afk exists, the watcher reverts
#     to daemon-owned one-shot behavior and enqueues every wake to
#     state/.wake-queue BEFORE advancing its suppression markers, so a
#     crash/restart/missed injection is recovered on the next fm-wake-drain.sh.
#     The daemon does not touch the queue; it only reads the watcher's stdout
#     reason.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane is escalated only after it has been
#     idle for STALE_ESCALATE_SECS (configurable), rechecked once. A wedged
#     crewmate is therefore detected within STALE_ESCALATE_SECS + a tick, never
#     lost. Crewmates are autonomous, so a delayed stale response does not stall
#     a healthy crewmate's own progress.
#     Buffered escalation delivery also has a max-defer alarm: if a digest stays
#     undelivered past FM_MAX_DEFER_SECS, the daemon retries a normal flush and
#     writes state/.subsuper-inject-wedged if submit still cannot be confirmed.
#   - Cheap heartbeat catch-all: every HEARTBEAT_SCAN_SECS the daemon greps all
#     state/*.status for a captain-relevant line the per-wake classifier might
#     have missed (e.g. a status verb outside CAPTAIN_RE) and escalates it.
#
# The robustness shell from the prior always-inject version is preserved:
# single-instance lock (portable helper, no flock dependency), crash-loop
# backoff, pane-gone guard, and a signal-trapped shutdown that flushes buffered
# escalations before exit.
#
# Usage: fm-supervise-daemon.sh
#          Long-lived background loop. Normally ensured at session start by
#          fm-bootstrap.sh, and also started by the /afk skill (which sets
#          state/.afk first) or from the fm-guard.sh banner. Env knobs:
#          FM_SUPERVISOR_TARGET     supervisor tmux target (override; otherwise
#                                   auto-discovered from TMUX_PANE, then
#                                   firstmate:0 fallback)
#          FM_INJECT_SKIP           |-prefixes force-self-handle bypassing
#                                   classification (default "heartbeat"); empty
#                                   disables. Use sparingly: it overrides the
#                                   captain-relevant escalation for matching
#                                   kinds.
#          FM_STALE_ESCALATE_SECS   idle seconds before a stale pane escalates
#                                   as a possible wedge (default 240)
#          FM_ESCALATE_BATCH_SECS   buffer window for batched escalation
#                                   digests; 0 = flush immediately (default 90)
#          FM_HEARTBEAT_SCAN_SECS   cadence for the catch-all status scan
#                                   (default 300)
#          FM_HOUSEKEEPING_TICK     seconds between housekeeping passes while
#                                   the watcher is mid-cycle (default 15)
#          --- present-mode (always-on) liveness knobs ---
#          FM_GUARD_GRACE           beacon-staleness threshold before the
#                                   watcher-liveness backstop re-arms; the single
#                                   liveness threshold shared with fm-guard.sh /
#                                   fm-watch-arm.sh (default 300)
#          FM_POKE_AFTER_SECS       seconds a wake may sit in state/.wake-queue
#                                   before a session poke fires (default 120)
#          FM_POKE_MIN_INTERVAL     hard cap between session pokes regardless of
#                                   new wakes (default 600)
#          FM_PRESENT_TICK          present-mode loop cadence (default 5)
#          FM_BACKSTOP_ARM_THROTTLE min seconds between backstop arm launches
#                                   (default 30)
#          FM_SECONDMATE_DEADTURN_RE OR-ed harness dead-turn error signatures
#                                   scanned in a secondmate pane's recent tail
#                                   (default 'API Error|ConnectionRefused')
#          FM_SECONDMATE_PROBE_TICK seconds between secondmate dead-turn probes
#                                   (default = FM_HOUSEKEEPING_TICK)
#          FM_WATCH_ARM_BIN         watcher-arm script the backstop launches
#                                   (override for tests; default the sibling
#                                   bin/fm-watch-arm.sh)
#          FM_INT_WARN_INTERVAL_MIN minutes between repeated stderr warnings for
#                                   the SAME unreadable numeric value; the daemon
#                                   log records every occurrence (default 10)
#          FM_BUSY_REGEX            OR-ed busy signatures (mirrors fm-watch.sh)
#          FM_COMPOSER_IDLE_RE      empty-composer regex applied after dim-ghost
#                                   and structural border stripping (default:
#                                   bare prompt glyphs plus busy footers)
#          FM_MAX_DEFER_SECS        max seconds a buffered escalation may sit
#                                   undelivered before one normal flush attempt;
#                                   if that cannot confirm a submit, a wedge
#                                   alarm fires (default 300; 0 disables)
#          FM_INJECT_CONFIRM_RETRIES Enter-retry attempts on a swallowed Enter
#                                   (default 3); the digest is typed once, only
#                                   Enter is retried. Composer-empty detection is
#                                   structural and style-aware (bin/fm-tmux-lib.sh):
#                                   it drops dim/faint ghost text and strips the
#                                   harness's box borders before deciding, so a
#                                   ghost-only or bordered-but-empty composer is
#                                   not misread as pending input.
#          FM_INJECT_CONFIRM_SLEEP  seconds between daemon submit checks
#                                   (default 0.5)
#          FM_LOG_MAX_BYTES / FM_LOG_KEEP_LINES / FM_CRASH_*  log + crash guards
#          FM_STATE_OVERRIDE        alternate state dir (testing)
#          Logs each wake to state/.supervise-daemon.log (size-capped). Single
#          instance via portable lock on state/.supervise-daemon.lock. Trapped
#          SIGTERM/SIGINT shut down within ~1s, flush escalations, release the
#          lock. A crashing fm-watch.sh is logged and restarted, never killing
#          the daemon; a tight crash-restart spin is detected and backed off.
set -u

FM_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_DAEMON_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared tmux pane primitives (busy/composer detection + verify-retry submit).
# Sourced at top level so BOTH the executed daemon and the unit tests (which
# source this file for its pure functions) get the corrected composer detection.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_DAEMON_DIR/fm-tmux-lib.sh"

# Shared wake classifier (last_status_line, status_is_captain_relevant,
# window_to_task, scan_captain_relevant_statuses). The SAME library backs the
# always-on watcher's triage, so the captain-relevant verb set and the
# classification predicates have exactly one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_DAEMON_DIR/fm-classify-lib.sh"

# --- tunables ---------------------------------------------------------------
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
HOUSEKEEPING_TICK_DEFAULT=15
# Max time a buffered escalation may sit undelivered before the daemon retries
# the normal flush path and, if that cannot confirm a submit, raises a loud wedge
# alarm. The escape hatch makes a guard false-positive visible instead of silent.
MAX_DEFER_SECS_DEFAULT=300
# The captain-relevant verb set and the status classifiers (last_status_line,
# status_is_captain_relevant, window_to_task, scan_captain_relevant_statuses) now
# live in bin/fm-classify-lib.sh, shared with the always-on watcher.
# Busy footers + composer-empty detection now live in bin/fm-tmux-lib.sh
# (FM_TMUX_BUSY_REGEX_DEFAULT / fm_tmux_composer_state); FM_BUSY_REGEX still
# overrides the busy set here, as before.
INJECT_FAIL_SLEEP_DEFAULT=30
INJECT_CONFIRM_RETRIES_DEFAULT=3
INJECT_CONFIRM_SLEEP_DEFAULT=0.5
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000
# Minutes between repeated stderr warnings about the SAME unreadable numeric
# value (see _int_warn). The daemon log records every occurrence regardless.
INT_WARN_INTERVAL_MIN_DEFAULT=10

# --- always-on (present-mode) liveness tunables -----------------------------
# These drive the minimal liveness layer the daemon runs while afk is INACTIVE.
# In present mode the daemon does NOT own the watcher or classify wakes (the
# always-on triage in bin/fm-watch.sh owns that); it only (1) re-arms the
# watcher when its liveness beacon goes stale with work in flight, (2) pokes the
# firstmate session when actionable wakes sit stranded in the queue with no
# active turn, and (3) probes secondmate panes for a dead-turn harness error.
# Beacon staleness reuses FM_GUARD_GRACE, the single liveness threshold shared
# with fm-guard.sh and fm-watch-arm.sh.
GUARD_GRACE_DEFAULT=300
# Seconds a wake may sit in state/.wake-queue before the daemon pokes the
# session to drain it (present mode only).
POKE_AFTER_SECS_DEFAULT=120
# Hard cap: never poke more than once per this many seconds, regardless of new
# wakes. Combined with the queue-signature dedupe (no re-poke of an unchanged
# stranded queue), this keeps pokes rare and quiet.
POKE_MIN_INTERVAL_DEFAULT=600
# Present-mode loop cadence: how often the liveness jobs run while afk is off.
PRESENT_TICK_DEFAULT=5
# Minimum seconds between backstop watcher-arm launches, so a stale-beacon window
# does not spawn a burst of arms before the first one beats.
BACKSTOP_ARM_THROTTLE_DEFAULT=30
# Harness dead-turn error signatures scanned in a secondmate pane's recent tail.
# A shell variable so the pattern list can grow; overridable via the env var.
SECONDMATE_DEADTURN_RE_DEFAULT='API Error|ConnectionRefused'

# The watcher-arm script the present-mode backstop launches. Overridable so tests
# can stub it; absent, it is the verified sibling script.
FM_WATCH_ARM_BIN="${FM_WATCH_ARM_BIN:-$FM_DAEMON_DIR/fm-watch-arm.sh}"

# --- presence-gating + sentinel marker --------------------------------------
# The in-band sentinel: ASCII unit separator (0x1f). Invisible and untypable on
# a normal keyboard, so no real user message starts with it. Every daemon
# injection is prefixed with this byte; firstmate treats a leading marker as an
# internal escalation (stay afk) and its absence as "captain is back" (exit afk).
# Portable across harnesses: it travels with the message text, independent of
# any harness-level typed-vs-injected distinction.
FM_INJECT_MARK=$'\x1f'
AFK_FLAG_NAME=".afk"

# Resolve the effective state dir. FM_STATE_OVERRIDE wins (testing); otherwise
# $FM_HOME/state. Kept as a function so the pure
# classifiers can take an explicit state arg without depending on globals.
_state_root() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }

# --- portable stat (same trap as fm-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# --- numeric coercion (incident daemon-rearm-fix-d8) ------------------------
# Every liveness decision below is an integer comparison over a value read from
# a command (stat, date, wc) or a state file, and a bare `[ "$v" -ge N ]` aborts
# with "integer expression expected" the moment that value is not a clean
# integer. Two real pollutions were observed in this home's own daemon stderr:
#   - BSD `wc` LEFT-PADS its count, so `sz=$(wc -c < "$LOG")` is "  192505".
#     Padding ALONE is tolerated by bash's `[` and by $(( )), so it is not by
#     itself the abort; it is the carrier that made the next one fatal here.
#   - When the disk fills, a bash builtin's output write fails and the undrained
#     buffer is flushed into a LATER command substitution, so `$(date +%s)` and
#     `$(wc -c ...)` come back with a stale log line APPENDED:
#       "1784687492\n[2026-07-15T05:17:47-0300] watcher beacon stale 461s ..."
#     A multi-line operand aborts both `[` and $(( )).
# That killed the watcher-liveness backstop from 2026-07-15: `[` errored,
# _backstop_should_arm returned non-zero, and a lapsed watcher chain was never
# re-armed - for three weeks, silently, because nothing checked.
#
# So no comparison consumes a raw value any more. _as_int keeps the FIRST line
# (the real value under both pollutions), strips surrounding whitespace, and
# yields a bare integer or falls back LOUDLY. Every fallback in the liveness
# path is chosen to fail toward ACTION (arm the watcher) rather than toward
# silence, because a redundant arm is a no-op while a missed one is an outage.
_as_int() {  # <raw> <fallback> [context] -> a bare integer (or <fallback>) on stdout
  local raw=$1 fallback=$2 ctx=${3:-value} v digits
  v=${raw%%$'\n'*}                    # first line only
  v="${v#"${v%%[![:space:]]*}"}"      # strip leading whitespace
  v="${v%"${v##*[![:space:]]}"}"      # strip trailing whitespace
  digits=${v#-}
  case "$digits" in
    ''|*[!0-9]*) _int_warn "$ctx" "$raw"; printf '%s' "$fallback"; return ;;
  esac
  printf '%s' "$v"
}

# Never silent. An unreadable numeric value means a liveness decision just ran
# on a fallback, which is precisely the failure that hid for three weeks. Every
# occurrence goes to the daemon log (size-capped by trim_log); stderr gets one
# line per context per FM_INT_WARN_INTERVAL_MIN minutes, because the full disk
# that causes this pollution is not helped by megabytes of warnings. The
# throttle is an mtime probe via `find -mmin`, deliberately NOT arithmetic, so
# the warning path cannot itself trip the fault it is reporting.
_int_warn() {  # <context> <raw>
  local ctx=$1 raw=$2 marker state mins
  raw=$(printf '%s' "$raw" | tr '\n\t' '  ' | cut -c1-120)
  log "ERROR: unreadable numeric value for ${ctx} (raw='${raw}'); decision fell back"
  state=${FM_DAEMON_WARN_STATE:-}
  if [ -n "$state" ] && [ -d "$state" ]; then
    marker="$state/.subsuper-intwarn-$(printf '%s' "$ctx" | tr -c '[:alnum:]' '-')"
    # Validated inline rather than through _as_int, because this IS the
    # fallback path and a coercion call here would recurse. A malformed value
    # would otherwise make `find` error out, silently disengaging the throttle
    # and putting the unbounded stderr flood back.
    mins=${FM_INT_WARN_INTERVAL_MIN:-$INT_WARN_INTERVAL_MIN_DEFAULT}
    case "$mins" in ''|*[!0-9]*) mins=$INT_WARN_INTERVAL_MIN_DEFAULT ;; esac
    if [ -e "$marker" ] && [ -n "$(find "$marker" -mmin "-$mins" 2>/dev/null)" ]; then
      return 0
    fi
    : > "$marker" 2>/dev/null || true
  fi
  printf 'fm-supervise-daemon: ERROR: unreadable numeric value for %s (raw=%s); decision fell back\n' \
    "$ctx" "$raw" >&2
}

# Read an integer-valued environment override BY NAME through the same
# coercion. An override is just another untrusted numeric input: a stray-quoted
# entry in a sourced env file feeding a bare `[` aborts the comparison and
# silently disables the very liveness decision it configures, which is the class
# of failure this hardening exists to end. Every integer-valued env read below
# goes through here, and the one fractional-seconds override goes through
# _env_secs, so the hardening is uniform rather than spot-applied.
_env_int() {  # <var-name> <default> -> a bare integer on stdout
  local name=$1 def=$2 raw
  raw=${!name-}
  [ -n "$raw" ] || { printf '%s' "$def"; return; }
  _as_int "$raw" "$def" "$name"
}

# The one numeric override that is NOT an integer: a sub-second poll delay fed
# straight to `sleep`. It cannot go through _as_int (which would reject its own
# 0.5 default), but it must not stay raw either: `sleep` exits immediately on a
# malformed argument, turning a paced retry into a spin.
_env_secs() {  # <var-name> <default> -> a bare decimal on stdout
  local name=$1 def=$2 raw v
  raw=${!name-}
  [ -n "$raw" ] || { printf '%s' "$def"; return; }
  v=${raw%%$'\n'*}                    # first line only, as _as_int does
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    ''|.|*[!0-9.]*|*.*.*) _int_warn "$name" "$raw"; printf '%s' "$def"; return ;;
  esac
  printf '%s' "$v"
}

# Current epoch seconds as a bare integer, or NOTHING plus a non-zero status
# when the clock read is unusable. There is deliberately no fallback epoch: 0 is
# not a conservative default but a 1970 timestamp, and it propagates - every age
# derived from it is absurdly large or negative, and one written into a marker
# that is read back BY CONTENT is believed for as long as that marker lives.
# Callers choose the policy explicitly instead: _age_since turns an unusable
# clock into the "very old" sentinel (fail toward action) and _stamp_now refuses
# to fabricate a stamp.
_now() {
  local v
  v=$(_as_int "$(date +%s)" '' 'clock')
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# The "very old" sentinel an unmeasurable age reads as. Named because it is a
# policy, not a magic number: an age the daemon cannot measure must fail toward
# ACTION, and "very old" is what makes it do so. That is the right reading for a
# liveness age (is the beacon stale? is a queued wake stranded?) and, as
# throttle_ready explains, for a throttle age too: the condition that makes an
# age unmeasurable is the incident, and a check that goes quiet during its own
# incident is not a check.
AGE_UNKNOWN=999999

# Seconds elapsed since <epoch-raw>. The ONE place the coerce-both-operands /
# subtract / clamp-negative sequence lives, so the arithmetic cannot drift
# between the beacon age, the escalation-buffer age, the stale-marker age, the
# wake-queue age and the throttle ages. It reports an unmeasurable age as a
# NON-ZERO status so the sentinel is applied in exactly one place (_age_since)
# instead of being re-derived, differently, per caller.
_elapsed_since() {  # <epoch-raw> <context> -> age on stdout + status 0, or status 1
  local raw=$1 ctx=$2 epoch now age
  epoch=$(_as_int "$raw" '' "$ctx")
  [ -n "$epoch" ] || return 1
  now=$(_now) || return 1
  age=$(( now - epoch ))
  [ "$age" -lt 0 ] && age=0   # a future epoch is fresh, never a negative age
  printf '%s' "$age"
}

# The LIVENESS reading of an elapsed time: an unusable stored epoch or clock
# reads as the AGE_UNKNOWN "very old" sentinel, so a check built on an age errs
# toward acting rather than toward doing nothing.
_age_since() {  # <epoch-raw> [context] -> age in seconds, or AGE_UNKNOWN
  local age
  age=$(_elapsed_since "$1" "${2:-epoch}") || { echo "$AGE_UNKNOWN"; return; }
  echo "$age"
}

# Render an age for a human-readable line. The sentinel is not a duration, and
# printing it as one puts a fabricated-looking number in front of the captain
# that reads exactly like a measured one; a real measurement still prints as a
# duration.
_age_phrase() {  # <age> -> "<n>s" or an explicit unknown
  case "$1" in
    "$AGE_UNKNOWN") printf 'for an unknown duration' ;;
    *) printf '%ss' "$1" ;;
  esac
}

# Stamp the current epoch into a marker file. Some markers are read back by
# CONTENT (the stale marker, the escalation-since sidecar) and some only by
# MTIME (the throttle markers), so an unusable clock truncates the file instead
# of writing a fabricated epoch: the mtime still advances, keeping every throttle
# honest, while a content reader sees an empty value that _age_since turns into
# the "very old" sentinel rather than a believable 1970 timestamp.
_stamp_now() {  # <file>
  local f=$1 v
  if v=$(_now); then printf '%s\n' "$v" > "$f"; return 0; fi
  : > "$f" 2>/dev/null || true
  return 1
}

_file_age() {  # seconds since mtime; the AGE_UNKNOWN sentinel when unknown/missing
  local m
  m=$(_stat_file_mtime "$1") || { echo "$AGE_UNKNOWN"; return; }
  _age_since "$m" "mtime:$1"
}

# The ONE rate limiter for every periodic action in the daemon: 0 when the action
# is due to run again, measured as the age of <marker>, which its caller stamps
# each time it acts.
#
# A marker that is not there means the action has never run, and it fires at
# once: a throttle must never delay an action's first run. That is also what a
# marker _stamp_now could not create looks like on a full disk, so the action
# keeps happening rather than waiting on a file the disk will not accept.
#
# The age is read through _file_age, so an unreadable clock reads as very old and
# the action fires on every tick until the clock comes back. That direction is
# deliberate, and it is the whole policy: the condition that makes the clock
# unreadable is a full filesystem, which is precisely the incident the gated
# actions exist to survive, so a fallback that limited the rate there would go
# quiet during its own incident. A check the feared condition makes quieter is
# not a check. The cost settles it too: fm-watch-arm.sh no-ops against a healthy
# watcher, so a redundant firing costs a process check while a missed one is an
# unsupervised fleet.
#
# Nothing here keeps state of its own, on disk or in memory. The marker its
# caller already stamps is the entire record, so there is no counter for a full
# disk to pin shut and none to strand across episodes when a marker is removed.
throttle_ready() {  # <marker> <min-gap-secs>
  [ -e "$1" ] || return 0
  [ "$(_file_age "$1")" -ge "$2" ]
}

_hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d ' ' -f1; fi
}

# --- presence-gating helpers (PURE-ish: side-effect-free reads of state) -----
# afk_active: 0 if the durable away-mode flag exists, 1 otherwise.
afk_active() {  # <state>
  [ -e "$1/$AFK_FLAG_NAME" ]
}

# afk_enter / afk_exit: write/clear the away-mode flag. Called by the /afk
# skill (enter) and by firstmate on user return (exit). Durable: a plain file,
# so recovery (§5) re-enters afk if it is present after a restart.
afk_enter() {  # <state>
  mkdir -p "$1"
  date '+%s' > "$1/$AFK_FLAG_NAME"
}

afk_exit() {  # <state>
  rm -f "$1/$AFK_FLAG_NAME"
}

# should_exit_afk: encodes firstmate's afk-exit contract as a testable function.
#   afk inactive            -> 1 (nothing to exit)
#   message has marker      -> 1 (internal escalation; stay afk)
#   message is /afk command -> 1 (re-entering/extending afk; stay afk)
#   anything else           -> 0 (captain is back; exit afk)
# Bias toward exit: only the marker and an explicit /afk invocation keep afk
# alive. A false exit is self-correcting (the captain re-runs /afk).
should_exit_afk() {  # <state> <message-text>
  local state=$1 msg=$2
  afk_active "$state" || return 1
  message_is_injection "$msg" && return 1
  case "$msg" in
    /afk*) return 1 ;;
  esac
  return 0
}

# message_is_injection: 0 if the given message text starts with the sentinel
# marker (a daemon escalation), 1 otherwise (a real user message). Firstmate's
# afk-exit contract uses this: marker present -> stay afk; absent -> captain is
# back. Bias ambiguous cases toward exit (a false exit is self-correcting).
message_is_injection() {  # <message-text>
  local msg=$1
  [ -n "$msg" ] || return 1
  case "$msg" in
    "$FM_INJECT_MARK"*) return 0 ;;
  esac
  return 1
}

# strip_injection_marker: remove the leading sentinel marker (if present) so the
# digest text is clean for classification/relay. The afk-exit contract keys off
# the marker's PRESENCE; once detected, the marker byte should not appear in the
# distilled content firstmate relays to the captain or feeds back to classifiers.
strip_injection_marker() {  # <message-text>
  local msg=$1
  printf '%s' "${msg#"$FM_INJECT_MARK"}"
}

# Collapse all newlines to a literal " - " separator so the injected digest is
# a single line. Submission via send-keys + Enter is then unambiguous regardless
# of how the target TUI handles embedded newlines in its composer.
_collapse_newlines() {  # <text>
  local s=$1
  s=${s//$'\n'/ - }
  printf '%s' "$s"
}

# Auto-discover the supervisor pane at startup. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) — caller passes it in.
#   2. $TMUX_PANE — tmux sets this in every pane's environment; inherited by
#      the daemon when the /afk skill launches it from firstmate's own pane.
#   3. firstmate:0 — legacy fallback (may not resolve if the session is named
#      differently). The caller logs a warning in that case.
# Returns the resolved target on stdout; returns 1 if only the fallback is left
# AND the fallback does not resolve to a live pane.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# --- classification helpers (PURE: no side effects, testable) ---------------
# last_status_line, status_is_captain_relevant, window_to_task, and
# scan_captain_relevant_statuses come from bin/fm-classify-lib.sh (sourced above),
# the single classifier shared with bin/fm-watch.sh. The decision-string wrappers
# and dedup state below layer the daemon's escalation-digest concerns on top.
#
# Decision protocol: every classifier prints exactly one line on stdout of the
# form "<action>|<distilled>" where action is "self" or "escalate". The distilled
# field for "self" is informational (logged); for "escalate" it is the pre-read
# summary firstmate would otherwise have to re-read.

classify_signal() {  # <reason-after-colon> <state>
  local reason=$1 state=$2 f last distilled="" rel="" all_seen=1 task seen
  for f in $reason; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_captain_relevant "$last" || continue
    rel=1
    # Dedupe against the catch-all scan: if this status was already escalated
    # (seen marker matches), skip escalating again. The seen marker is the
    # single source of truth shared between the per-wake signal path and the
    # heartbeat scan. all_seen stays 1 only if EVERY relevant file was seen.
    task=$(basename "$f"); task="${task%.status}"
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] || all_seen=0
  done
  # strip a trailing " | " separator so the distilled line is clean
  distilled="${distilled% | }"
  if [ -z "$rel" ]; then
    printf 'self|routine signal: %s' "$distilled"
  elif [ "$all_seen" = "1" ]; then
    # Every relevant status was already escalated by the catch-all scan;
    # self-handle to avoid a duplicate entry in the digest.
    printf 'self|signal already escalated (catch-all scan): %s' "$distilled"
  else
    printf 'escalate|%s' "$distilled"
  fi
}

# classify_stale decides the WAKE itself (one-shot per distinct hash). On a
# first sight of a non-terminal stale it returns "self" and the caller records a
# timestamp marker; persistence is escalated by housekeeping's recheck, not here.
classify_stale() {  # <window> <state>
  local win=$1 state=$2 task last seen
  task=$(window_to_task "$win")
  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    # Dedupe against the signal path: if this status was already escalated
    # (seen marker matches), self-handle to avoid a duplicate in the digest.
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    if [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ]; then
      printf 'self|stale + terminal (already escalated by signal): %s' "$last"
      return
    fi
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  # Non-terminal (or no status): defer to the persistence recheck. The caller
  # records/refreshes the stale marker so housekeeping can age it.
  printf 'self|transient stale (%s): %s' "$win" "${last:-no status}"
}

classify_check() {  # <full reason>  — check scripts print only when firstmate should wake
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  # The wake itself is routine; the catch-all scan runs separately in
  # housekeeping on the HEARTBEAT_SCAN_SECS cadence.
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale marker + escalation buffer (stateful, but via explicit state dir) -
# Marker:   state/.subsuper-stale-<key>   contains the epoch first seen idle.
# Buffer:   state/.subsuper-escalations    one distilled line per escalation.
# Seen:     state/.subsuper-seen-status-<task>  last status line the scan
#           escalated, so the catch-all does not re-fire the same terminal.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

stale_marker_record() {  # <window> <state>  — create if absent
  local win=$1 state=$2 key marker
  key=$(_stale_key "$(window_to_task "$win")")
  marker="$state/.subsuper-stale-$key"
  [ -e "$marker" ] || _stamp_now "$marker"
}

stale_marker_remove() {  # <window> <state>
  local win=$1 state=$2 key
  key=$(_stale_key "$(window_to_task "$win")")
  rm -f "$state/.subsuper-stale-$key"
}

# Record the seen-status marker for a captain-relevant status line so the
# heartbeat catch-all scan does not re-fire it. The single source of truth for
# the .subsuper-seen-status-<task> dedup state: called from both the per-wake
# escalate path and the catch-all scan.
mark_status_seen() {  # <state> <task> <last-line>
  local state=$1 task=$2 line=$3
  printf '%s' "$line" > "$state/.subsuper-seen-status-$(_stale_key "$task")"
}

# Mark every captain-relevant status line a per-wake classification escalated as
# seen, so the catch-all scan does not re-escalate the same line within
# HEARTBEAT_SCAN_SECS. Mirrors classify_signal/classify_stale's relevance test.
mark_escalated_seen() {  # <kind> <arg> <state>
  local kind=$1 arg=$2 state=$3 f last task
  case "$kind" in
    signal)
      for f in $arg; do
        [ -e "$f" ] || continue
        last=$(last_status_line "$f")
        [ -n "$last" ] || continue
        status_is_captain_relevant "$last" || continue
        task=$(basename "$f"); task="${task%.status}"
        mark_status_seen "$state" "$task" "$last"
      done ;;
    stale)
      task=$(window_to_task "$arg")
      last=$(last_status_line "$state/$task.status")
      [ -n "$last" ] && status_is_captain_relevant "$last" \
        && mark_status_seen "$state" "$task" "$last" ;;
  esac
}

# Busy + composer-empty detection are the shared primitives in fm-tmux-lib.sh
# (one source of truth with fm-send.sh). These thin wrappers keep the daemon's
# call sites and the unit tests stable.
#
# pane_input_pending returns 0 (pending) when the cursor line holds real
# unsubmitted text - a human's half-typed line (the return race) or a previous
# injection whose Enter was swallowed. The detector drops dim/faint ghost text and
# strips the harness's composer box borders, so a ghost-only or idle bordered
# claude composer ("│ > … │") is correctly read as empty, not pending (incidents
# afk-invx-i5 and composer-robust).
pane_is_busy() { fm_pane_is_busy "$@"; }        # <window>
pane_input_pending() { fm_pane_input_pending "$@"; }  # <target>

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _stamp_now "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched, single-line digest to the
# supervisor pane. Returns 0 on successful inject (or empty buffer), non-zero on
# inject failure (buffer preserved for retry / catch-up).
escalate_flush() {  # <state>
  local state=$1 buf item n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  n=$(_as_int "$(wc -l < "$buf" 2>/dev/null || echo 0)" 0 'escalation-count')
  # Join buffered items with the literal " | " separator into one digest line.
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  # Single-line wrapper: no embedded newlines (inject_msg also collapses as a
  # safety net, but keeping the source single-line makes the intent explicit).
  msg=$(printf 'Supervisor escalate (%s event(s)): %s (pre-read; re-arm not needed — watcher daemon-managed)' "$n" "$msg")
  # A delivered digest ends the wedge episode, and the wedge marker is that
  # episode's whole record, so dropping it is what lets the next wedge alarm at
  # once instead of waiting out a window it had nothing to do with.
  if inject_msg "$msg" "$state"; then
    : > "$buf"
    rm -f "${buf}.since" "$state/.subsuper-inject-wedged"
    return 0
  fi
  return 1
}

# Raise a loud alarm when escalations cannot be delivered after max-defer (the
# supervisor pane is genuinely busy/wedged, or the submit's Enter is swallowed).
# The daemon must NEVER silently wedge: this logs
# an ERROR, drops a durable marker firstmate/recovery can surface, and flashes
# the supervisor client's status line. Nothing is lost — the buffer and the
# wake-queue both survive — but the stall stops being invisible.
#
# The rate limit lives in ONE place: housekeeping's max-defer escape gate, which
# is the only caller and which has already proved the same .subsuper-inject-wedged
# marker is a max-defer window old. A second gate here added nothing on the wall
# clock path and could only ever make the alarm quieter, and an alarm that mutes
# itself during the incident it announces is not an alarm.
inject_wedge_alarm() {  # <state> <age-seconds>
  local state=$1 age=$2 marker target
  marker="$state/.subsuper-inject-wedged"
  log "ERROR: away-mode escalation undelivered $(_age_phrase "$age"); inject could not confirm a submit (supervisor pane busy or wedged). Buffer + wake-queue preserved; alarm marker written."
  {
    printf 'fm away-mode inject WEDGED: undelivered %s as of %s\n' "$(_age_phrase "$age")" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'The supervisor pane could not accept an escalation. Buffered items:\n'
    cat "$state/.subsuper-escalations" 2>/dev/null
  } > "$marker" 2>/dev/null || true
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  tmux display-message -t "$target" "fm: away-mode escalations WEDGED $(_age_phrase "$age") - see $marker" 2>/dev/null || true
}

_oldest_line_age() {  # <buf> -> seconds since the oldest buffered item first arrived (sidecar epoch)
  local f=$1 since
  [ -s "$f" ] || { echo "$AGE_UNKNOWN"; return; }
  since="${f}.since"
  [ -r "$since" ] || { echo "$AGE_UNKNOWN"; return; }
  _age_since "$(cat "$since" 2>/dev/null || true)" 'escalation-since'
}

# --- housekeeping (runs every tick while the watcher is mid-cycle) ----------
# Five cheap jobs, each guarded so an empty/quiet fleet costs near zero:
#  1) batch flush: if the escalation buffer's oldest content is older than
#     ESCALATE_BATCH_SECS (or batching is disabled), inject one digest.
#  1b) max-defer escape: if the buffer is STILL undelivered past MAX_DEFER_SECS,
#     attempt one normal delivery; if it cannot confirm, raise the wedge alarm.
#     Never silently defer forever.
#  2) stale recheck: for each pending stale marker past STALE_ESCALATE_SECS,
#     re-peek the pane; still idle -> escalate (wedge); resumed -> clear marker.
#  3) heartbeat scan: every HEARTBEAT_SCAN_SECS, grep state/*.status for a
#     captain-relevant line the per-wake classifier missed and escalate it.
#  4) log cap: trim the daemon log. It belongs on the TICK, not on a wake: away
#     mode's only other trim runs after a watcher wake, which a quiet fleet can
#     be hours from, while _int_warn logs every occurrence and the loop reads
#     several ages per second - so a persistently polluted read would pile up
#     megabytes of log during the very full-disk condition that causes the
#     pollution. Present mode calls trim_log directly (it runs no housekeeping).
housekeeping() {  # <state>
  local state=$1 due f key task win marker age last max_defer oldest batch stale_after
  batch=$(_env_int FM_ESCALATE_BATCH_SECS "$ESCALATE_BATCH_SECS_DEFAULT")

  # (1) batch flush
  if [ "$batch" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "$batch" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (1b) max-defer escape. If anything is still buffered past MAX_DEFER_SECS,
  # retry the normal delivery path. If that still cannot confirm, raise a loud
  # wedge alarm while preserving the buffer.
  max_defer=$(_env_int FM_MAX_DEFER_SECS "$MAX_DEFER_SECS_DEFAULT")
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && [ -s "$state/.subsuper-escalations" ]; then
    oldest=$(_oldest_line_age "$state/.subsuper-escalations")
    # The ONLY throttle on this retry and on the wedge alarm it can raise: once
    # per max-defer window, with the wedge marker doubling as the throttle.
    # A successful flush clears the buffer; a failed one alarms and waits.
    if [ "$oldest" -ge "$max_defer" ] \
       && throttle_ready "$state/.subsuper-inject-wedged" "$max_defer"; then
      if escalate_flush "$state"; then
        log "inject recovered: max-defer flush succeeded; undelivered $(_age_phrase "$oldest")"
        rm -f "$state/.subsuper-inject-wedged"
      else
        inject_wedge_alarm "$state" "$oldest"
      fi
    fi
  fi

  # (2) stale persistence recheck
  stale_after=$(_env_int FM_STALE_ESCALATE_SECS "$STALE_ESCALATE_SECS_DEFAULT")
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    # An unreadable marker reads as very old, so the recheck below still runs;
    # it escalates only on a live pane probe that confirms the crewmate is idle,
    # so failing toward action here costs a pane read, never a false wedge.
    age=$(_age_since "$(cat "$marker" 2>/dev/null || true)" "stale-marker:$key")
    [ "$age" -ge "$stale_after" ] || continue
    # Reconstruct the window name from the key (best-effort: session is unknown,
    # so probe the live fm-* windows for one whose task matches).
    win=$(window_for_task "$key" 2>/dev/null || true)
    if [ -z "$win" ]; then
      # Window gone (task torn down): drop the marker, nothing to escalate.
      rm -f "$marker"; continue
    fi
    if pane_is_busy "$win"; then
      rm -f "$marker"   # crewmate resumed: benign
    else
      escalate_add "$state" "stale persisted $(_age_phrase "$age") (possible wedge): $win"
      stale_marker_remove "$win" "$state"
    fi
  done

  # (3) heartbeat scan (catch-all for a captain-relevant status the per-wake
  #     classifier may have missed). Cheap: status files only, no tmux. The
  #     captain-relevant filtering is the shared classifier's
  #     scan_captain_relevant_statuses; the daemon layers its digest dedup on top.
  if throttle_ready "$state/.subsuper-last-scan" "$(_env_int FM_HEARTBEAT_SCAN_SECS "$HEARTBEAT_SCAN_SECS_DEFAULT")"; then
    _stamp_now "$state/.subsuper-last-scan"
    local seen
    while IFS="$(printf '\t')" read -r f task last; do
      [ -n "$f" ] || continue
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      mark_status_seen "$state" "$task" "$last"
    done < <(scan_captain_relevant_statuses "$state")
  fi

  # (4) log cap, on the tick rather than only on a wake (see the note above).
  trim_log
}

# Find a live fm-* window whose task id matches the given marker key.
window_for_task() {  # <task-key>
  local key=$1 w t
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep ':fm-' || true); do
    t=$(window_to_task "$w")
    [ "$(_stale_key "$t")" = "$key" ] && { printf '%s' "$w"; return 0; }
  done
  return 1
}

# --- injection --------------------------------------------------------------
# inject_msg: send one escalation digest to the supervisor pane.
# Returns 0 on successful inject (or empty buffer), non-zero if the pane is
# gone, the supervisor is busy, afk is inactive, or the verified submit cannot
# be confirmed after bounded retries. On non-zero the caller preserves
# the buffer so the escalation survives for the next cycle or the catch-up flush.
#
# Submit model:
#   - TYPE ONCE, then submit with Enter. Never retype the digest: a swallowed
#     Enter leaves our text in the composer, and retyping would concatenate two
#     sentinel-prefixed digests into one corrupted turn.
#   - SUBMIT ACK = the dim-ghost-aware and border-aware composer detector reports
#     empty after Enter.
#     Empty means the text was consumed; pending means Enter was swallowed; unknown
#     is treated as undelivered by this strict daemon path.
#   - COMPOSER GUARD before typing: if the cursor line already has real content
#     after dim/faint ghost text and borders are ignored (a human's half-typed
#     line, or a previous injection's unsent text), defer entirely - injecting
#     would merge with the human's text.
# _inject_marked: the SHARED marked-submit core, used by BOTH the afk escalation
# path (inject_msg, which adds the presence-gate) and the present-mode session
# poke (poke_session, which has no gate). Kept as one code path so the injection
# hardening - marker, single-line collapse, busy/pending composer guards, and the
# verified type-once-retry-Enter submit - cannot drift between the two callers.
# Returns 0 only when the composer is confirmed EMPTY afterward (submit landed);
# non-zero when the pane is gone, busy, holds pending input, or the submit could
# not be confirmed. Never gates on afk: the caller owns that policy.
_inject_marked() {  # <message> <target>
  local msg=$1 target=$2 retries sleep_s verdict
  # Single-line digest: collapse any embedded newlines so submission via
  # send-keys + Enter is unambiguous regardless of how the TUI composer treats
  # them. Then prepend the sentinel marker - firstmate keys off its presence at
  # the start of the message (afk escalation, or present-mode liveness poke).
  msg=$(_collapse_newlines "$msg")
  msg="${FM_INJECT_MARK}${msg}"
  tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1 || return 1
  # Busy-guard: never inject into an in-use pane. Two checks:
  #   a) pane_is_busy: the harness shows a busy footer (agent mid-turn).
  #   b) pane_input_pending: the cursor line has real unsubmitted text after
  #      dim/faint ghost text and borders are ignored (a human's half-typed line,
  #      or a previous injection whose Enter was swallowed).
  if pane_is_busy "$target"; then
    log "inject deferred: supervisor pane busy (agent mid-turn)"
    return 1
  fi
  if pane_input_pending "$target"; then
    log "inject deferred: supervisor pane has pending input (non-empty composer)"
    return 1
  fi
  # Type the digest ONCE, then submit with Enter (retry Enter only, never retype)
  # via the shared submit primitive. Success = the composer is confirmed EMPTY
  # afterward (the text was consumed). An unconfirmed/unknown pane does NOT count
  # as delivered.
  retries=$(_env_int FM_INJECT_CONFIRM_RETRIES "$INJECT_CONFIRM_RETRIES_DEFAULT")
  sleep_s=$(_env_secs FM_INJECT_CONFIRM_SLEEP "$INJECT_CONFIRM_SLEEP_DEFAULT")
  verdict=$(fm_tmux_submit_core "$target" "$msg" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    return 0  # Composer cleared → submit confirmed.
  fi
  log "inject failed: submit unconfirmed after $retries retries (verdict=$verdict, text may be in composer)"
  return 1
}

inject_msg() {  # <message> [state]
  local msg=$1 state target
  state="${2:-$(_state_root)}"
  # Presence-gate: escalations inject ONLY when afk is active. When afk is off,
  # the daemon self-handles and stays quiet; firstmate drives the normal always-on
  # watcher triage. Escalations buffer and survive for the next catch-up flush.
  # (The present-mode liveness poke is a separate path, poke_session, and is NOT
  # afk-gated - it is the whole point of the always-on layer.)
  afk_active "$state" || { log "inject deferred: afk inactive"; return 1; }
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  _inject_marked "$msg" "$target"
}

# ============================================================================
# ALWAYS-ON (present-mode) liveness layer. Everything below runs ONLY while afk
# is INACTIVE. It is deliberately minimal: it does NOT classify, batch, or absorb
# wakes (the always-on triage in bin/fm-watch.sh owns that). It only keeps the
# watcher alive, re-invokes a stalled firstmate session, and surfaces a dead
# secondmate turn the watcher structurally cannot see. All decisions take an
# explicit <state> dir and use injectable binaries so they are unit-testable.
# ============================================================================

# Count in-flight tasks (a state/<id>.meta exists). Mirrors fm-guard.sh.
_in_flight_count() {  # <state>
  local state=$1 meta n=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- (behavior 2) watcher-liveness backstop ---------------------------------
# _backstop_should_arm: 0 if the daemon should (re-)arm the watcher now - some
# task is in flight AND the watcher liveness beacon is missing or older than
# FM_GUARD_GRACE. Pure read (no side effects), so it is directly testable.
_backstop_should_arm() {  # <state>
  local state=$1 age grace
  [ "$(_in_flight_count "$state")" -gt 0 ] || return 1
  age=$(_file_age "$state/.last-watcher-beat")
  grace=$(_env_int FM_GUARD_GRACE "$GUARD_GRACE_DEFAULT")
  [ "$age" -ge "$grace" ]
}

# ensure_watcher_backstop: when _backstop_should_arm says so (throttled through
# throttle_ready to one launch per BACKSTOP_ARM_THROTTLE while the clock reads,
# so a stale window does not spawn a burst; when it does not read, the arm fires
# on every tick, because a redundant arm is a no-op against a healthy watcher and
# a missed one is the outage this backstop exists to end),
# launch fm-watch-arm.sh DETACHED. The arm blocks on its watcher child, so it is
# double-forked ( ... & ) inside a subshell that exits immediately: the arm is
# reparented away from the daemon (no zombie, never waited on) and re-establishes
# a watcher that beats the beacon and enqueues future wakes. Home-scoped
# (FM_STATE_OVERRIDE), never a broad pkill. The subshell first sources this
# home's X-mode/email-mode cadence configs when present, exactly as AGENTS.md
# sections 14 and 15 require of an arm caller, so the re-armed watcher keeps the
# opted-in FM_CHECK_INTERVAL (30s/60s) instead of degrading to the 300s default;
# the sourcing is scoped to the arm launch, never the daemon itself. The
# stranded-wake poke, not this, re-invokes the LLM; this only keeps the enqueue
# machinery and beacon alive.
ensure_watcher_backstop() {  # <state>
  local state=$1 age min_gap
  _backstop_should_arm "$state" || return 0
  min_gap=$(_env_int FM_BACKSTOP_ARM_THROTTLE "$BACKSTOP_ARM_THROTTLE_DEFAULT")
  throttle_ready "$state/.subsuper-last-backstop-arm" "$min_gap" || return 0
  _stamp_now "$state/.subsuper-last-backstop-arm"
  age=$(_file_age "$state/.last-watcher-beat")
  log "watcher beacon stale $(_age_phrase "$age") with $(_in_flight_count "$state") in flight; launching backstop re-arm"
  (
    # shellcheck disable=SC1090,SC1091
    [ -f "$FM_HOME/config/x-mode.env" ] && . "$FM_HOME/config/x-mode.env"
    # shellcheck disable=SC1090,SC1091
    [ -f "$FM_HOME/config/email-mode.env" ] && . "$FM_HOME/config/email-mode.env"
    FM_STATE_OVERRIDE="$state" "$FM_WATCH_ARM_BIN" >/dev/null 2>&1 &
  )
}

# --- (behavior 3) stranded-wake session poke --------------------------------
# The durable wake queue path for a given state dir.
_wake_queue_path() { printf '%s' "$1/.wake-queue"; }

# Age (seconds) of the OLDEST queued wake, or -1 when the queue is empty/missing.
# The queue is append-ordered "epoch<TAB>seq<TAB>...", so the first line's epoch
# is the oldest pending wake.
_poke_oldest_age() {  # <state>
  local state=$1 queue first epoch
  queue=$(_wake_queue_path "$state")
  [ -s "$queue" ] || { printf '%s' -1; return; }
  first=$(head -1 "$queue" 2>/dev/null)
  epoch=${first%%$'\t'*}
  case "$epoch" in ''|*[!0-9]*) printf '%s' -1; return ;; esac
  # Via _age_since, so an unusable clock reads as very old and the stranded-wake
  # poke still fires. This is the one mechanism that re-invokes the LLM session,
  # so it must never fail toward silence.
  printf '%s' "$(_age_since "$epoch" 'wake-queue')"
}

# Signature of the current queue content. Changes when a wake is added or the
# queue drains, which is exactly the "queue drained or a new wake arrived"
# condition that re-permits a poke.
_poke_queue_sig() {  # <state>
  local state=$1 queue
  queue=$(_wake_queue_path "$state")
  [ -s "$queue" ] || { printf ''; return; }
  _hash_text "$(cat "$queue" 2>/dev/null)"
}

# poke_should_fire: 0 if a stranded-wake poke is warranted right now:
#   - the oldest queued wake is at least FM_POKE_AFTER_SECS old, AND
#   - at least FM_POKE_MIN_INTERVAL has passed since the last poke (hard cap), AND
#   - the queue signature differs from the last poked one (dedupe: never re-poke
#     the same stranded state - only a drain or a new wake re-permits a poke).
# Pure read of state markers; the pane-busy guard is applied by _inject_marked at
# send time (and re-checked in poke_session), so this stays a cheap decision.
# The min-interval throttle deliberately keeps _file_age (and so the very-old
# sentinel) rather than throttle_ready: the burst guard here is the signature
# dedupe, which reads no clock at all, so an unreadable clock cannot produce a
# poke storm - while the poke itself is the one mechanism that re-invokes the
# LLM session and must never be gated behind a tick count.
poke_should_fire() {  # <state>
  local state=$1 age throttle sig last_sig
  age=$(_poke_oldest_age "$state")
  case "$age" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$age" -ge "$(_env_int FM_POKE_AFTER_SECS "$POKE_AFTER_SECS_DEFAULT")" ] || return 1
  throttle=$(_file_age "$state/.subsuper-poke-sig")
  [ "$throttle" -ge "$(_env_int FM_POKE_MIN_INTERVAL "$POKE_MIN_INTERVAL_DEFAULT")" ] || return 1
  sig=$(_poke_queue_sig "$state")
  last_sig=$(cat "$state/.subsuper-poke-sig" 2>/dev/null || true)
  [ "$sig" != "$last_sig" ]
}

# poke_session: inject ONE marked, single-line poke into the firstmate session
# telling it to drain the stranded queue and re-arm supervision. Marked (internal,
# never captain-facing) and gated by poke_should_fire + the shared busy/pending
# guards in _inject_marked, so a captain mid-turn never sees a poke and a stranded
# state is poked at most once. Records the poked signature (its mtime is the
# min-interval throttle) only on a confirmed submit, so a deferred/busy attempt is
# retried on the next tick rather than silently marked done.
poke_session() {  # <state>
  local state=$1 target n msg
  poke_should_fire "$state" || return 0
  target="${FM_SUPERVISOR_TARGET:-$FM_SUPERVISOR_TARGET_DEFAULT}"
  n=$(wc -l < "$(_wake_queue_path "$state")" 2>/dev/null | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  msg="Supervision liveness: ${n} wake(s) have sat unhandled in state/.wake-queue with no active turn. Drain them now (bin/fm-wake-drain.sh), handle each, then re-arm the watcher (bin/fm-watch-arm.sh)."
  if _inject_marked "$msg" "$target"; then
    _poke_queue_sig "$state" > "$state/.subsuper-poke-sig"
    log "poke sent: ${n} stranded wake(s) in queue"
  else
    log "poke deferred: pane busy/pending or submit unconfirmed"
  fi
}

# --- (behavior 4) secondmate dead-turn probe --------------------------------
# Enqueue one durable wake via the production wake library, in a subshell scoped
# to <state> so fm_wake_append targets the right queue and reuses its locking/seq
# discipline (never reimplemented here). Mirrors tests/wake-helpers.sh append_wake.
enqueue_liveness_wake() {  # <state> <kind> <key> <payload>
  local state=$1 kind=$2 key=$3 payload=$4
  # shellcheck source=bin/fm-wake-lib.sh
  ( FM_STATE_OVERRIDE="$state" . "$FM_DAEMON_DIR/fm-wake-lib.sh"
    fm_wake_append "$kind" "$key" "$payload" ) >/dev/null 2>&1
}

_meta_is_secondmate() { grep -q '^kind=secondmate$' "$1" 2>/dev/null; }
_meta_window() { grep '^window=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- ; }

# secondmate_deadturn_probe: the watcher structurally exempts secondmate panes
# from stale detection (an idle secondmate is normally healthy), so a secondmate
# whose harness turn DIED on a transient API error writes no status and is never
# surfaced. For each kind=secondmate meta this probe looks at the pane: a busy
# pane is healthy (clear any marker); an idle pane whose recent tail shows a
# harness error signature is a dead turn - enqueue a durable wake so the main
# firstmate recovers it through the normal drain path (present mode surfaces it
# via the poke; afk on the next drain). Deduped one-per-incident on the error
# line, cleared when the pane recovers, so a persistent error does not re-enqueue.
secondmate_deadturn_probe() {  # <state>
  local state=$1 meta win id key marker tail40 errline re
  re="${FM_SECONDMATE_DEADTURN_RE:-$SECONDMATE_DEADTURN_RE_DEFAULT}"
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    _meta_is_secondmate "$meta" || continue
    win=$(_meta_window "$meta")
    [ -n "$win" ] || continue
    id=$(basename "$meta"); id="${id%.meta}"
    key=$(_stale_key "$id")
    marker="$state/.subsuper-secondmate-deadturn-$key"
    # A busy pane means the secondmate is mid-turn: healthy. Clear any marker.
    if pane_is_busy "$win"; then
      rm -f "$marker"
      continue
    fi
    # Idle pane: a dead turn shows the harness error among the most-recent
    # non-blank lines (a recovered secondmate would have output below it). Look at
    # the last few lines only, mirroring fm_pane_is_busy's tail window.
    tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || continue
    errline=$(printf '%s\n' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
      | grep -iE "$re" | tail -1)
    if [ -z "$errline" ]; then
      rm -f "$marker"   # idle + no error = healthy resting secondmate
      continue
    fi
    # Dead turn. Dedupe one-per-incident on the exact error line.
    [ "$(cat "$marker" 2>/dev/null || true)" = "$errline" ] && continue
    printf '%s' "$errline" > "$marker"
    enqueue_liveness_wake "$state" stale "$win" "stale: $win (secondmate dead turn: $errline)"
    log "secondmate dead-turn on $win: $errline; enqueued recovery wake"
  done
}

# --- INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# A real watcher WAKE reason starts with one of these prefixes. Anything else on
# the watcher child's stdout (e.g. "watcher: already running" on a singleton-lock
# collision, reachable if the daemon was SIGKILL'd and its orphaned watcher child
# still holds the #29 singleton lock) is a STATUS line, not a wake: handling it
# as an unknown wake would flood the escalation buffer and restart the child with
# no crash backoff. The main loop treats a non-wake line as idle (log + sleep +
# continue), so a singleton collision cannot hot-loop escalations.
is_wake_reason() {  # <reason>
  local reason=$1
  case "$reason" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# --- dispatch one wake reason to self-handle or escalate --------------------
# Side effects: logging, marker records, escalation buffer appends.
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled
  local kind="" arg=""
  if should_force_self "$reason"; then
    log "wake force-self (FM_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) kind=signal; arg="${reason#signal: }"
              decision=$(classify_signal "$arg" "$state") ;;
    stale:*)  kind=stale; arg="${reason#stale: }"
              decision=$(classify_stale "$arg" "$state") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  if [ "$action" = "escalate" ]; then
    log "escalate: $reason -> $distilled"
    escalate_add "$state" "$distilled"
    # A terminal-stale escalate must not leave a persistence marker behind, or
    # housekeeping re-escalates the same pane as a false wedge later.
    [ "$kind" = "stale" ] && stale_marker_remove "$arg" "$state"
    mark_escalated_seen "$kind" "$arg" "$state"
    [ "$(_env_int FM_ESCALATE_BATCH_SECS "$ESCALATE_BATCH_SECS_DEFAULT")" -le 0 ] && { escalate_flush "$state" || true; }
  else
    # Transient (non-terminal) stale: record/refresh the marker so housekeeping
    # can age it; the persistence recheck, not this wake, escalates a wedge.
    [ "$kind" = "stale" ] && stale_marker_record "$arg" "$state"
    log "self-handle: $reason -> $distilled"
  fi
}

# --- log --------------------------------------------------------------------
# Uses LOG set by fm_super_main; harmless no-op-ish if unset (tests source fns
# directly and pass state explicitly, so they do not call log).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp max
  [ -n "${LOG:-}" ] || return 0
  # BSD wc left-pads ("  192505"), so this is one of the raw values that broke
  # the daemon's comparisons; 0 means "do not trim", the non-destructive default.
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  sz=$(_as_int "$sz" 0 'log-size')
  max=$(_env_int FM_LOG_MAX_BYTES "$LOG_MAX_BYTES_DEFAULT")
  [ "$sz" -ge "$max" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-daemon-log.XXXXXX") || return 0
  tail -n "$(_env_int FM_LOG_KEEP_LINES "$LOG_KEEP_LINES_DEFAULT")" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests (tests/fm-daemon.test.sh).
# ============================================================================

fm_super_main() {
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"
  # Where _int_warn keeps its per-context stderr throttle markers. Global (not
  # local) so command substitutions see it; unset when the pure functions are
  # sourced by tests, which then warn on every occurrence.
  FM_DAEMON_WARN_STATE="$STATE"

  # Source the portable lock helpers (works on macOS where flock is absent).
  # Export FM_STATE_OVERRIDE so the lib resolves the same state dir.
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$STATE" . "$FM_DAEMON_DIR/fm-wake-lib.sh"

  local WATCH="$FM_DAEMON_DIR/fm-watch.sh"
  local LOG="$STATE/.supervise-daemon.log"
  local WATCH_ERR="$STATE/.supervise-daemon.watcher.err"
  local LOCK="$STATE/.supervise-daemon.lock"
  local PIDFILE="$STATE/.supervise-daemon.pid"
  # Coerced like every other numeric input. These feed both `[` comparisons and
  # `sleep`, and a malformed value (FM_CRASH_NORMAL_SLEEP=" 5 ") makes `sleep`
  # exit immediately, turning the watcher-restart path into a tight spin rather
  # than merely disabling a check.
  local INJECT_FAIL_SLEEP CRASH_THRESHOLD CRASH_WINDOW CRASH_BACKOFF CRASH_NORMAL_SLEEP
  INJECT_FAIL_SLEEP=$(_env_int FM_INJECT_FAIL_SLEEP "$INJECT_FAIL_SLEEP_DEFAULT")
  CRASH_THRESHOLD=$(_env_int FM_CRASH_THRESHOLD "$CRASH_THRESHOLD_DEFAULT")
  CRASH_WINDOW=$(_env_int FM_CRASH_WINDOW "$CRASH_WINDOW_DEFAULT")
  CRASH_BACKOFF=$(_env_int FM_CRASH_BACKOFF "$CRASH_BACKOFF_DEFAULT")
  CRASH_NORMAL_SLEEP=$(_env_int FM_CRASH_NORMAL_SLEEP "$CRASH_NORMAL_SLEEP_DEFAULT")

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (portable lock, no flock dependency) ------------------
  if ! fm_lock_try_acquire "$LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      echo "error: another fm-supervise-daemon is already running (pid $FM_LOCK_HELD_PID, lock $LOCK held)" >&2
    else
      echo "error: another fm-supervise-daemon is already running (lock $LOCK held)" >&2
    fi
    exit 1
  fi
  echo "$$" > "$PIDFILE"

  # --- auto-discover the supervisor target (the pane running firstmate) -----
  # Priority: FM_SUPERVISOR_TARGET override > $TMUX_PANE (inherited from the
  # pane that launched the daemon, normally firstmate's own) > firstmate:0
  # fallback. Exporting the result into FM_SUPERVISOR_TARGET makes inject_msg
  # (which reads that env var) use the discovered pane without an extra global.
  local discovered target_source
  target_source="FM_SUPERVISOR_TARGET"
  if [ -z "${FM_SUPERVISOR_TARGET:-}" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      target_source="TMUX_PANE"
    else
      target_source="FALLBACK(firstmate:0)"
    fi
  fi
  if discovered=$(discover_supervisor_target); then
    : # resolved cleanly
  else
    echo "warn: could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET or TMUX_PANE); falling back to '$discovered' — verify this is firstmate's pane" >&2
  fi
  FM_SUPERVISOR_TARGET="$discovered"
  local TARGET="$FM_SUPERVISOR_TARGET"

  # --- validate supervisor target at startup (a missing target is a typo) ---
  if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
    echo "error: supervisor target '$TARGET' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET" >&2
    log "startup failed: target '$TARGET' not found"
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi

  local afk_status="off"
  afk_active "$STATE" && afk_status="on"
  # The COERCED values, which are what every decision below actually runs on. A
  # malformed override is replaced silently in the code, so printing the raw one
  # here would answer "what config is this daemon running with" with a value the
  # daemon is not using, and a buffer-polluted override would split this record.
  local cfg_stale cfg_batch cfg_grace cfg_poke cfg_poke_min
  cfg_stale=$(_env_int FM_STALE_ESCALATE_SECS "$STALE_ESCALATE_SECS_DEFAULT")
  cfg_batch=$(_env_int FM_ESCALATE_BATCH_SECS "$ESCALATE_BATCH_SECS_DEFAULT")
  cfg_grace=$(_env_int FM_GUARD_GRACE "$GUARD_GRACE_DEFAULT")
  cfg_poke=$(_env_int FM_POKE_AFTER_SECS "$POKE_AFTER_SECS_DEFAULT")
  cfg_poke_min=$(_env_int FM_POKE_MIN_INTERVAL "$POKE_MIN_INTERVAL_DEFAULT")
  log "daemon starting (pid $$); target=$TARGET; target_source=$target_source; afk=$afk_status; inject_skip='${FM_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${cfg_stale}s; batch=${cfg_batch}s; always-on liveness: guard_grace=${cfg_grace}s; poke_after=${cfg_poke}s; poke_min_interval=${cfg_poke_min}s"

  # --- shutdown: flush buffered escalations, reap child, release lock -------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${CUR_TMP:-}" ]; then
      rm -f "$CUR_TMP" 2>/dev/null || true
    fi
    fm_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -----------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    # An unusable clock cannot be stamped into the crash window without
    # poisoning it, so the window is left alone and the restart takes the normal
    # sleep. The daemon keeps restarting the watcher; only the burst detector
    # sits this one out.
    now=$(_now) || {
      log "ERROR: unreadable clock; crash-loop window not updated for this restart"
      backoff_secs=$CRASH_NORMAL_SLEEP
      return 0
    }
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
    WATCHER_PID=$!
  }

  # Loop cadences are coerced ONCE here: they feed both `[` comparisons and
  # `sleep`, and a malformed override that made `sleep` fail would turn this
  # into a busy loop rather than merely disabling a check.
  local rc reason PRESENT_TICK SECONDMATE_PROBE_TICK HOUSEKEEP_TICK
  PRESENT_TICK=$(_env_int FM_PRESENT_TICK "$PRESENT_TICK_DEFAULT")
  HOUSEKEEP_TICK=$(_env_int FM_HOUSEKEEPING_TICK "$HOUSEKEEPING_TICK_DEFAULT")
  SECONDMATE_PROBE_TICK=$(_env_int FM_SECONDMATE_PROBE_TICK "$HOUSEKEEP_TICK")
  while true; do
    # --- secondmate dead-turn probe (BOTH modes, tick-gated) ---------------
    # A dead secondmate turn writes no status and the watcher exempts secondmate
    # panes from stale detection, so this cheap pane probe is the only thing that
    # can surface it. It only enqueues a durable wake (no classification), so it
    # is additive to afk behavior; present mode surfaces it via the poke below.
    if throttle_ready "$STATE/.subsuper-last-secondmate-probe" "$SECONDMATE_PROBE_TICK"; then
      _stamp_now "$STATE/.subsuper-last-secondmate-probe"
      secondmate_deadturn_probe "$STATE"
    fi

    # --- present mode (afk INACTIVE): minimal liveness layer ---------------
    # The daemon does NOT own the watcher or classify wakes here - the always-on
    # triage in bin/fm-watch.sh owns that. It only backstops watcher liveness and
    # re-invokes a stalled session via a stranded-wake poke.
    if ! afk_active "$STATE"; then
      # Relinquish any watcher child owned during a prior afk stint, so the lock
      # is released for firstmate's own (or the backstop's) absorb-mode watcher.
      if [ -n "${WATCHER_PID:-}" ]; then
        kill "$WATCHER_PID" 2>/dev/null || true
        wait "$WATCHER_PID" 2>/dev/null || true
        WATCHER_PID=""
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "$CUR_TMP" 2>/dev/null || true
          CUR_TMP=""
        fi
        log "afk cleared: relinquished watcher child; entering present-mode liveness"
      fi
      ensure_watcher_backstop "$STATE"
      poke_session "$STATE"
      trim_log
      sleep "$PRESENT_TICK"
      continue
    fi

    # ======================================================================
    # AFK MODE (afk ACTIVE): the daemon owns the watcher, classifies each wake,
    # and injects batched escalations. Behavior below is unchanged.
    # ======================================================================
    # --- pane-gone guard (preserved) ---------------------------------------
    # With the #29 watcher's enqueue-before-suppress, a wake is no longer
    # swallowed by running the watcher with no injection target. We still back
    # off while the pane is gone: self-handling needs no pane, but escalation
    # has nowhere to go, and firstmate itself is the consumer of escalations.
    # Catch-up signals persist in state/*.status and flow on the next run, so
    # this delays rather than loses work.
    if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
      log "warn: supervisor target '$TARGET' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      # Flush is pointless with no pane; preserve any buffered escalations.
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited --------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        # child exited: reap + classify its wake reason
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        if [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ]; then
          reason=$(<"${CUR_TMP}")
        fi
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "${CUR_TMP}" 2>/dev/null || true
        fi
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        # Non-wake stdout (e.g. a watcher singleton-collision "already running"
        # status line) is NOT a wake: idling here prevents an escalation flood
        # and a backoff-less child restart. record_crash is intentionally
        # skipped (rc=0, this is normal idle, not a crash).
        if ! is_wake_reason "$reason"; then
          log "watcher non-wake stdout, idling: $reason"
          WATCHER_PID=""
          sleep "$HOUSEKEEP_TICK"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick (gated to HOUSEKEEPING_TICK), then poll -------
    # The watcher child runs on its own FM_POLL cadence internally; we only need
    # to detect its exit (the kill -0 above) promptly and run housekeeping often
    # enough that batch flushes, stale rechecks, and the catch-all scan fire on
    # cadence. Gating keeps a large fleet cheap between ticks.
    sleep 1
    if throttle_ready "$STATE/.subsuper-last-housekeep" "$HOUSEKEEP_TICK"; then
      _stamp_now "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_super_main "$@"
fi
