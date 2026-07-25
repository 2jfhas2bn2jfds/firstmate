#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's model-pin hygiene.
#
# fm-spawn launches agents by sending a command line into a tmux pane, and a pane
# inherits its tmux SESSION environment. So a stale ANTHROPIC_MODEL recorded in a
# long-running firstmate session (set back when an older Opus was current) reached
# every agent launched in that session, forever - including brand-new crewmates
# spawned by an already-pinned secondmate, which is how the pin spread down the tree.
# The fix prefixes every launch with `env -u ANTHROPIC_MODEL`, so the agent resolves
# its model from its own harness config instead of the inherited value.
#
# Two halves, both behavioral:
#  1. drive fm-spawn over a fake tmux and assert the literal command it sends carries
#     the prefix on every launch path (ship, scout, secondmate) while the rest of the
#     launch - harness binary, brief, secondmate FM_HOME overrides - survives intact.
#  2. prove the mechanism inside real tmux: in a session whose environment carries the
#     pin, a plainly-sent command's child DOES inherit it (the bug, reproduced) while
#     one sent through `env -u ANTHROPIC_MODEL` does NOT.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-model-pin)
fm_git_identity fmtest fmtest@example.invalid

PIN=claude-opus-4-8
PREFIX='env -u ANTHROPIC_MODEL '
# Half 2 drives a PRIVATE tmux server (its own socket), so it never touches the
# developer's live sessions and leaves nothing behind.
E2E_SOCKET="fm-model-pin-$$"
E2E_SES=pinned

cleanup() {
  tmux -L "$E2E_SOCKET" kill-server 2>/dev/null || true
  # kill-server can leave the socket file behind; drop it so runs leave no litter.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$E2E_SOCKET" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- half 1: the command fm-spawn sends ------------------------------------------

# A fake tmux that answers the pane-path and session queries fm-spawn makes, and
# records the literal (`-l`) send-keys payload - the launch command line - to
# FM_SENDKEYS_LOG. Every other tmux call is swallowed.
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
case "$cmd" in
  display-message) printf '%s\n' "${FM_FAKE_SES:-firstmate}"; exit 0 ;;
  send-keys)
    # Log only the literal payload (`send-keys -t <target> -l <launch>`), not the
    # separate Enter keypress that follows it.
    literal=
    for a in "$@"; do
      if [ "$literal" = pending ]; then literal=$a; break; fi
      [ "$a" = "-l" ] && literal=pending
    done
    if [ -n "$literal" ] && [ "$literal" != pending ] && [ -n "${FM_SENDKEYS_LOG:-}" ]; then
      printf '%s\n' "$literal" >> "$FM_SENDKEYS_LOG"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_spawn <home> <log> <fakebin> <spawn-args...>: drive fm-spawn against the fake
# tmux with the stale pin exported, mimicking a firstmate session that carries it.
run_spawn() {
  local home=$1 log=$2 fakebin=$3
  shift 3
  ANTHROPIC_MODEL="$PIN" \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_SES=firstmate \
    FM_SENDKEYS_LOG="$log" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

test_launch_command_strips_pin_on_every_path() {
  local home proj wt subhome fakebin log out status launch kind
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/proj"
  fm_git_init_commit "$proj"
  # A genuine isolated linked worktree, so fm-spawn's isolation guard is satisfied.
  wt="$TMP_ROOT/wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_fake_tmux "$TMP_ROOT/fake")

  # A seeded secondmate home: plain (non-git) so the pre-launch local sync skips
  # harmlessly, which is orthogonal to the environment behavior under test.
  subhome="$TMP_ROOT/subhome"
  mkdir -p "$subhome/bin" "$subhome/data"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'domain-z9\n' > "$subhome/.fm-secondmate-home"

  for kind in ship scout secondmate; do
    log="$TMP_ROOT/sendkeys-$kind.log"
    : > "$log"
    mkdir -p "$home/data/task-$kind"
    printf 'brief\n' > "$home/data/task-$kind/brief.md"
    case "$kind" in
      ship)  out=$(FM_FAKE_PANE_PATH="$wt" run_spawn "$home" "$log" "$fakebin" "task-$kind" "$proj" codex) ;;
      scout) out=$(FM_FAKE_PANE_PATH="$wt" run_spawn "$home" "$log" "$fakebin" "task-$kind" "$proj" codex --scout) ;;
      secondmate)
        mkdir -p "$home/data/domain-z9"
        printf 'charter\n' > "$home/data/domain-z9/brief.md"
        out=$(run_spawn "$home" "$log" "$fakebin" domain-z9 "$subhome" codex --secondmate)
        ;;
    esac
    status=$?
    expect_code 0 "$status" "$kind spawn should succeed"
    assert_contains "$out" "spawned " "$kind spawn did not report success"

    launch=$(cat "$log")
    [ -n "$launch" ] || fail "$kind spawn sent no literal launch command"
    case "$launch" in
      "$PREFIX"*) : ;;
      *) fail "$kind launch must start with '$PREFIX' (got: $launch)" ;;
    esac
    # The prefix must not swallow the rest of the launch.
    assert_contains "$launch" "codex " "$kind launch lost its harness command"
    assert_contains "$launch" "brief.md" "$kind launch lost its brief argument"
    if [ "$kind" = secondmate ]; then
      assert_contains "$launch" "FM_HOME=" "secondmate launch lost its FM_HOME override"
    fi
  done
  pass "fm-spawn: every launch path (ship, scout, secondmate) strips ANTHROPIC_MODEL"
}

# --- half 2: the mechanism inside real tmux --------------------------------------

# Send one command line into a fresh window of the pinned session and wait for the
# file it writes. Echoes nothing; the caller reads the file.
run_in_pinned_pane() {
  local win=$1 cmd=$2 out=$3 i=0
  tmux -L "$E2E_SOCKET" new-window -d -t "$E2E_SES:" -n "$win" -c "$TMP_ROOT"
  tmux -L "$E2E_SOCKET" send-keys -t "$E2E_SES:$win" -l "$cmd"
  tmux -L "$E2E_SOCKET" send-keys -t "$E2E_SES:$win" Enter
  while [ "$i" -lt 100 ]; do
    [ -s "$out" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_env_unset_defeats_a_pinned_tmux_session() {
  local control="$TMP_ROOT/control.env" guarded="$TMP_ROOT/guarded.env"
  command -v tmux >/dev/null || fail "tmux is required for this test"
  tmux -L "$E2E_SOCKET" new-session -d -s "$E2E_SES" -x 200 -y 50 -c "$TMP_ROOT" \
    || fail "could not create tmux session $E2E_SES on socket $E2E_SOCKET"
  # The stale pin, recorded in the SESSION environment exactly as a long-running
  # firstmate session carries it. Every window created afterwards inherits it.
  tmux -L "$E2E_SOCKET" set-environment -t "$E2E_SES" ANTHROPIC_MODEL "$PIN"

  : > "$control"
  run_in_pinned_pane control "printenv > '$control'" "$control" \
    || fail "control pane never wrote its environment"
  assert_grep "ANTHROPIC_MODEL=$PIN" "$control" \
    "fixture is not exercising the bug: a plainly-launched child did not inherit the session pin"

  : > "$guarded"
  run_in_pinned_pane guarded "${PREFIX}printenv > '$guarded'" "$guarded" \
    || fail "guarded pane never wrote its environment"
  assert_no_grep "ANTHROPIC_MODEL" "$guarded" \
    "'$PREFIX' did not strip the session pin from the launched process"
  pass "env -u ANTHROPIC_MODEL: a child launched in a pinned tmux session carries no pin"
}

test_launch_command_strips_pin_on_every_path
test_env_unset_defeats_a_pinned_tmux_session
