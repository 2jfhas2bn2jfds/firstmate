#!/usr/bin/env bash
# Behavior tests for the claude background-shell busy signature (incident
# fm-busyshell-t4, reproduced live 2026-07-12).
#
# A claude crew that ends its turn but is idle-WAITING on its own running
# background shell (a no-mistakes pipeline, a long RN build, a test run) shows NO
# "esc to interrupt" spinner - the turn is over - only a footer segment naming the
# still-running shell(s). Two live forms:
#   "✻ Cooked for 1m 4s · 1 shell still running"
#   "⏵⏵ bypass permissions on · 1 shell · ← for agents"
# plus the original report's "N shell(s) still running". Before this, the pane
# fallback did not recognize the footer, so the watcher fired repeat false stale
# ("possible wedge") wakes on a healthy crew during long validations.
#
# Two layers are pinned:
#   1. fm_pane_has_bg_shell (bin/fm-tmux-lib.sh) - the pure text signature: both
#      footer forms match; shell talk buried in the transcript body does NOT
#      (footer-tail anchoring); a footer-region "1 shell" without the "·" anchor
#      or "still running" phrase does NOT.
#   2. fm-crew-state.sh - the fallback consults it ONLY for harness=claude, and
#      the run-step-first order is unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-busyshell)
fm_git_identity fmtest fmtest@example.invalid

# --- fm_pane_has_bg_shell: pure signature over a fake pane -------------------

# A fake tmux whose capture-pane cats a fixture pane file (FM_FAKE_PANE) and whose
# display-message succeeds (so pane_readable is true). Mirrors the real
# `capture-pane -p` plain path the busy scanners use.
make_pane_tmux() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane)    cat "${FM_FAKE_PANE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Assert fm_pane_has_bg_shell's verdict for a fixture pane written to <file>.
assert_bg_shell() {  # <fakebin> <pane-file> <want:yes|no> <msg>
  local fb=$1 pane=$2 want=$3 msg=$4
  if PATH="$fb:$PATH" FM_FAKE_PANE="$pane" fm_pane_has_bg_shell "win"; then
    [ "$want" = yes ] || fail "$msg (matched but should not have)"
  else
    [ "$want" = no ] || fail "$msg (did not match but should have)"
  fi
}

test_bg_shell_matches_cooked_form() {
  local dir fb pane; dir="$TMP_ROOT/cooked"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'Ran the review step\nWriting the report\n✻ Cooked for 1m 4s · 1 shell still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "Cooked '1 shell still running' footer is busy"
  pass "fm_pane_has_bg_shell: the 'Cooked ... 1 shell still running' footer counts"
}

test_bg_shell_matches_permissions_form() {
  local dir fb pane; dir="$TMP_ROOT/perms"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'kicked off the build\n⏵⏵ bypass permissions on · 1 shell · ← for agents\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'· 1 shell ·' footer segment is busy"
  pass "fm_pane_has_bg_shell: the '· 1 shell ·' permission-footer segment counts"
}

# Monitors (found by datefit-mate 2026-07-31). claude counts background MONITORS
# alongside shells and renders them as ONE comma-separated list before a single
# trailing "still running". The original pattern required "shells" to be followed
# directly by "still", and its "·"-anchored alternative required whitespace or
# end-of-line after the noun, so both alternatives missed the comma-separated
# list: a crew idle-waiting on its own monitor read as stale and woke firstmate
# for nothing.
test_bg_shell_matches_shell_and_monitor_form() {
  local dir fb pane; dir="$TMP_ROOT/monitor"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  # The exact footer reported from the field.
  printf 'waiting on the suite\n2 shells, 1 monitor still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'2 shells, 1 monitor still running' is busy"
  # The same list inside the "Cooked" footer form.
  printf 'waiting on the suite\n✻ Cooked for 2m 1s · 1 shell, 1 monitor still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'· 1 shell, 1 monitor still running' is busy"
  # A monitor with no shell at all.
  printf 'waiting on the suite\n1 monitor still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'1 monitor still running' alone is busy"
  # Plural monitors, and a longer list.
  printf 'waiting on the suite\n3 shells, 2 monitors still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'3 shells, 2 monitors still running' is busy"
  # The compact permission-footer segment, where a comma terminates the noun.
  printf 'waiting\n⏵⏵ bypass permissions on · 2 shells, 1 monitor · ← for agents\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'· 2 shells, 1 monitor ·' footer segment is busy"
  pass "fm_pane_has_bg_shell: shell+monitor footer forms count"
}

# The monitor noun must not weaken either anchor: prose in the footer region
# naming a monitor, with no "·" and no "still running", must still NOT count.
test_bg_shell_ignores_unanchored_footer_monitor() {
  local dir fb pane; dir="$TMP_ROOT/unanchored-monitor"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'done working\n✔ added 1 monitor to the dashboard\n> \n' > "$pane"
  assert_bg_shell "$fb" "$pane" no "footer 'added 1 monitor' without the anchor does not count"
  printf 'done working\n✔ the monitor is still running fine\n> \n' > "$pane"
  assert_bg_shell "$fb" "$pane" no "'the monitor is still running' with no count does not count"
  pass "fm_pane_has_bg_shell: an unanchored footer monitor does not false-positive"
}

test_bg_shell_matches_plural_forms() {
  local dir fb pane; dir="$TMP_ROOT/plural"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'building for release\n2 shells still running\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "bare 'N shells still running' (long RN build) is busy"
  printf 'building for release\n⏵⏵ bypass permissions on · 3 shells · ← for agents\n' > "$pane"
  assert_bg_shell "$fb" "$pane" yes "'· 3 shells ·' plural footer segment is busy"
  pass "fm_pane_has_bg_shell: plural shell forms count"
}

# Negative 1 - footer-tail anchoring: the phrase in ordinary transcript prose,
# more than 6 non-blank lines above an idle footer, must NOT count.
test_bg_shell_ignores_transcript_body_prose() {
  local dir fb pane; dir="$TMP_ROOT/body-prose"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  {
    printf 'I left 2 shells still running on the staging box earlier\n'
    printf 'then I fixed the failing test\nupdated the docs\nran the linter\n'
    printf 'pushed the branch\nopened the PR\nall checks are green\n'
    printf '⏵⏵ bypass permissions on · ← for agents\n'
  } > "$pane"
  assert_bg_shell "$fb" "$pane" no "shell prose in the body (outside the footer tail) does not count"
  pass "fm_pane_has_bg_shell: transcript-body shell prose does not false-positive"
}

# Negative 2 - anchor within the footer region: a footer-region "1 shell" with no
# leading "·" and no "still running" phrase must NOT count.
test_bg_shell_ignores_unanchored_footer_shell() {
  local dir fb pane; dir="$TMP_ROOT/unanchored"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'done working\n✔ wrote 1 shell script for the build\n> \n' > "$pane"
  assert_bg_shell "$fb" "$pane" no "footer 'wrote 1 shell script' without the anchor does not count"
  pass "fm_pane_has_bg_shell: an unanchored footer 'N shell' does not false-positive"
}

# An ordinary busy pane (esc to interrupt) is NOT a background-shell footer - the
# two signatures stay distinct (fm_pane_is_busy owns the spinner case).
test_bg_shell_distinct_from_spinner() {
  local dir fb pane; dir="$TMP_ROOT/spinner"; mkdir -p "$dir"
  fb=$(make_pane_tmux "$dir"); pane="$dir/pane.txt"
  printf 'thinking hard\nesc to interrupt\n' > "$pane"
  assert_bg_shell "$fb" "$pane" no "a plain busy spinner is not a background-shell footer"
  pass "fm_pane_has_bg_shell: the spinner footer is not a background-shell footer"
}

# --- fm-crew-state.sh: gated fallback + preserved run-step order -------------

make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# A fakebin with a fake no-mistakes (empty run output unless FM_FAKE_AXI_STATUS is
# set) and a fake tmux that serves the fixture pane (FM_FAKE_PANE) plus a live
# display-message, so the fallback path is reached with a readable pane.
make_crewstate_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = axi ] || exit 0
shift
case "${1:-}" in
  status)
    shift
    if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
    else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
  '') printf '%s\n' "${FM_FAKE_AXI_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane)    cat "${FM_FAKE_PANE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_FAKE_PANE="$1/pane.txt" \
    "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# harness=claude + no run + a background-shell footer -> working via the pane.
test_crewstate_claude_bg_shell_is_working() {
  local d; d=$(new_case cs-claude)
  make_repo_on_branch "$d/wt" fm/feat-cl
  make_crewstate_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cl.meta" \
    "window=fm:fm-feat-cl" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'building\n✻ Cooked for 1m 4s · 1 shell still running\n' > "$d/pane.txt"
  local out; out=$(FM_FAKE_AXI_STATUS="" FM_FAKE_AXI_LIST="" run_crew_state "$d" feat-cl)
  assert_contains "$out" "state: working" "claude bg-shell footer -> working"
  assert_contains "$out" "source: pane" "claude bg-shell footer -> pane source"
  assert_contains "$out" "background shell running" "detail names the background shell"
  pass "fm-crew-state: a claude background-shell footer reads working"
}

# End to end, the case that produced the false stale wake on 2026-07-31: a claude
# crew idle-waiting on its own monitor must read as WORKING, not as stale.
test_crewstate_claude_monitor_footer_is_working() {
  local d; d=$(new_case cs-monitor)
  make_repo_on_branch "$d/wt" fm/feat-mon
  make_crewstate_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-mon.meta" \
    "window=fm:fm-feat-mon" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'running the suite\n2 shells, 1 monitor still running\n' > "$d/pane.txt"
  local out; out=$(FM_FAKE_AXI_STATUS="" FM_FAKE_AXI_LIST="" run_crew_state "$d" feat-mon)
  assert_contains "$out" "state: working" "shell+monitor footer -> working"
  assert_contains "$out" "background shell running" "detail names the background shell"
  pass "fm-crew-state: a shell+monitor footer reads working, not stale"
}

# Same footer under harness=codex must NOT count (the signature is claude-specific).
# With no run, no spinner, and no status log, the codex crew falls to unknown/none.
test_crewstate_codex_bg_shell_not_gated() {
  local d; d=$(new_case cs-codex)
  make_repo_on_branch "$d/wt" fm/feat-cx
  make_crewstate_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cx.meta" \
    "window=fm:fm-feat-cx" "worktree=$d/wt" "kind=ship" "harness=codex"
  printf 'building\n✻ Cooked for 1m 4s · 1 shell still running\n' > "$d/pane.txt"
  local out; out=$(FM_FAKE_AXI_STATUS="" FM_FAKE_AXI_LIST="" run_crew_state "$d" feat-cx)
  assert_not_contains "$out" "background shell running" "codex does not use the claude footer"
  assert_not_contains "$out" "source: pane" "codex bg-shell footer is not a busy pane"
  assert_contains "$out" "state: unknown" "codex bg-shell footer + no other source -> unknown"
  pass "fm-crew-state: the background-shell footer is gated to harness=claude"
}

# The run-step stays authoritative: an active run + a bg-shell pane -> run-step,
# never the pane fallback (the ordering is unchanged by this feature).
test_crewstate_runstep_still_wins_over_bg_shell() {
  local d; d=$(new_case cs-runstep)
  make_repo_on_branch "$d/wt" fm/feat-rs
  make_crewstate_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rs.meta" \
    "window=fm:fm-feat-rs" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'building\n✻ Cooked for 1m 4s · 1 shell still running\n' > "$d/pane.txt"
  local run_out out
  run_out=$(cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat-rs
  status: running
  head: "abc1234"
  pr: ""
  findings: none
EOF
)
  out=$(FM_FAKE_AXI_STATUS="$run_out" FM_FAKE_AXI_LIST="" run_crew_state "$d" feat-rs)
  assert_contains "$out" "source: run-step" "active run stays authoritative over the pane"
  assert_not_contains "$out" "background shell running" "run-step path never reaches the pane fallback"
  pass "fm-crew-state: run-step-first order is preserved"
}

test_bg_shell_matches_cooked_form
test_bg_shell_matches_permissions_form
test_bg_shell_matches_plural_forms
test_bg_shell_matches_shell_and_monitor_form
test_bg_shell_ignores_unanchored_footer_monitor
test_bg_shell_ignores_transcript_body_prose
test_bg_shell_ignores_unanchored_footer_shell
test_bg_shell_distinct_from_spinner
test_crewstate_claude_bg_shell_is_working
test_crewstate_claude_monitor_footer_is_working
test_crewstate_codex_bg_shell_not_gated
test_crewstate_runstep_still_wins_over_bg_shell

echo "all fm-busyshell tests passed"
