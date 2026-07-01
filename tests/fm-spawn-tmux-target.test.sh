#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's tmux session-target robustness.
#
# fm-spawn creates the crewmate window with `tmux new-window -t <session>`. tmux
# parses a new-window `-t` as a target-WINDOW, so a bare numeric or auto-named
# session (the common in-tmux case where '#S' is "0") is read as window index 0 and
# fails with "index 0 in use", or lands the window in the wrong place under a
# non-default `base-index`. The fix targets the session with a trailing colon
# ("$SES:") so tmux places the window at the session's next free index. This test
# drives fm-spawn over a fake tmux that records the `-t` value it receives and
# asserts both the existence check (list-windows) and the creation (new-window) carry
# the trailing colon, for an auto-named numeric session and a named session, while the
# spawn still completes end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-tmux-target)
fm_git_identity fmtest fmtest@example.invalid

# A fake tmux that:
#  - answers '#{pane_current_path}' with FM_FAKE_PANE_PATH so the worktree-resolution
#    loop resolves to a path we control,
#  - answers display-message '#S' with FM_FAKE_SES (the session name under test),
#  - records the value following `-t` for list-windows and new-window into logs,
#  - swallows every other tmux call.
make_fake_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
cmd=${1:-}
shift || true
# Capture the argument following the first -t.
tflag=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-t" ]; then tflag="$a"; break; fi
  prev="$a"
done
case "$cmd" in
  display-message) printf '%s\n' "${FM_FAKE_SES:-0}"; exit 0 ;;
  list-windows) [ -n "${FM_LISTWIN_LOG:-}" ] && printf '%s\n' "$tflag" >> "$FM_LISTWIN_LOG"; exit 0 ;;
  new-window) [ -n "${FM_NEWWIN_LOG:-}" ] && printf '%s\n' "$tflag" >> "$FM_NEWWIN_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_spawn <home> <id> <proj> <pane> <fakebin> <session> <newlog> <listlog>
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 session=$6 newlog=$7 listlog=$8
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_SES="$session" FM_NEWWIN_LOG="$newlog" FM_LISTWIN_LOG="$listlog" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_new_window_target_carries_trailing_colon() {
  local home proj wt fakebin out status n i
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/proj"
  fm_git_init_commit "$proj"
  # A genuine isolated linked worktree, detached on the default branch.
  wt="$TMP_ROOT/wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_fake_tmux "$TMP_ROOT/fake")

  i=0
  # "0" is the bug case (an auto-named/numeric session); "firstmate" is a named
  # session - both must be targeted as "<session>:".
  for session in 0 firstmate; do
    i=$((i + 1))
    local newlog="$TMP_ROOT/newwin-$i.log" listlog="$TMP_ROOT/listwin-$i.log"
    : > "$newlog"
    : > "$listlog"
    out=$(run_spawn "$home" "tgt-$i" "$proj" "$wt" "$fakebin" "$session" "$newlog" "$listlog")
    status=$?
    expect_code 0 "$status" "spawn with session '$session' should succeed"
    assert_contains "$out" "spawned tgt-$i" "spawn with session '$session' did not report success"

    n=$(cat "$newlog")
    [ "$n" = "$session:" ] || fail "new-window target for session '$session' must be '$session:' (got '$n')"
    n=$(cat "$listlog")
    [ "$n" = "$session:" ] || fail "list-windows target for session '$session' must be '$session:' (got '$n')"
  done
  pass "fm-spawn: new-window and list-windows target the session with a trailing colon"
}

test_new_window_target_carries_trailing_colon
