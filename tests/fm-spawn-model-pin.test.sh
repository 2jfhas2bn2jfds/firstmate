#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's model-pin hygiene.
#
# fm-spawn launches agents by sending a command line into a tmux pane, and a pane
# inherits its tmux SESSION environment. So a stale ANTHROPIC_MODEL recorded in a
# long-running firstmate session (set back when an older Opus was current) reached
# every agent launched in that session, forever - including brand-new crewmates
# spawned by an already-pinned secondmate, which is how the pin spread down the tree.
# The fix prefixes every launch with an `env -u` stripping the whole model-selection
# family, so the agent resolves its model from its own harness config instead of the
# inherited value. The family matters: ANTHROPIC_DEFAULT_OPUS_MODEL re-points the very
# `opus` alias that fallback relies on, so stripping ANTHROPIC_MODEL alone would leave
# the identical bug reachable through a sibling variable.
#
# Two halves, both behavioral:
#  1. drive fm-spawn over a fake tmux and assert the literal command it sends carries
#     the prefix on every launch path (ship, scout, secondmate, raw) while the rest of the
#     launch - harness binary, brief, secondmate FM_HOME overrides - survives intact.
#  2. prove the mechanism inside real tmux: in a session whose environment carries the
#     pins, a plainly-sent command's child DOES inherit them (the bug, reproduced) while
#     one sent through the strip prefix carries none of them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-model-pin)
fm_git_identity fmtest fmtest@example.invalid

PIN=claude-opus-4-8
# The whole model-selection family fm-spawn strips. ANTHROPIC_MODEL is the direct pin;
# the ANTHROPIC_DEFAULT_*_MODEL trio re-points the very aliases the harness config falls
# back on, and the last two redirect the background and subagent models the same way.
PINNED_VARS=(
  ANTHROPIC_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL
  ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL
)
# Derived from that one list, so adding a variable to the family updates both the expected
# launch prefix and the assertions that look for it.
PREFIX="env"
for pinned_var in "${PINNED_VARS[@]}"; do PREFIX="$PREFIX -u $pinned_var"; done
PREFIX="$PREFIX "
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
  local home proj wt subhome fakebin log out status launch kind ship_launch=
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

  for kind in ship scout secondmate raw; do
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
      raw)   out=$(FM_FAKE_PANE_PATH="$wt" run_spawn "$home" "$log" "$fakebin" "task-$kind" "$proj" 'mytool --flag') ;;
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
    if [ "$kind" = raw ]; then
      # The unverified-adapter escape hatch, whose harness name is scanned out of the raw
      # command rather than read from a template. The strip is prepended AFTER that scan,
      # so the recorded harness stays the raw command word; were it prepended before,
      # every raw spawn would record harness=env.
      assert_contains "$launch" "mytool --flag" "raw launch lost its command"
      assert_grep "harness=mytool" "$home/state/task-raw.meta" \
        "raw spawn recorded a harness from the strip prefix, not from its command word"
    else
      assert_contains "$launch" "codex " "$kind launch lost its harness command"
      assert_contains "$launch" "brief.md" "$kind launch lost its brief argument"
    fi
    if [ "$kind" = secondmate ]; then
      assert_contains "$launch" "FM_HOME=" "secondmate launch lost its FM_HOME override"
    fi
    if [ "$kind" = ship ]; then
      ship_launch=$launch
    fi
  done

  # The escape hatch: where these variables ARE the deliberate model selection
  # (Bedrock, Vertex), FM_KEEP_MODEL_ENV keeps them - the launch is then exactly the
  # default one without its strip prefix, harness command and brief untouched.
  log="$TMP_ROOT/sendkeys-optout.log"
  : > "$log"
  out=$(FM_KEEP_MODEL_ENV=1 FM_FAKE_PANE_PATH="$wt" \
    run_spawn "$home" "$log" "$fakebin" task-ship "$proj" codex)
  status=$?
  expect_code 0 "$status" "opt-out spawn should succeed"
  assert_contains "$out" "spawned " "opt-out spawn did not report success"
  launch=$(cat "$log")
  [ "$launch" = "${ship_launch#"$PREFIX"}" ] \
    || fail "FM_KEEP_MODEL_ENV must drop the strip prefix and change nothing else (got: $launch)"
  pass "fm-spawn: every launch path (ship, scout, secondmate, raw) strips the model-pin family"
}

# --- half 2: the mechanism inside real tmux --------------------------------------

# run_in_pinned_pane <window> <launch-prefix> <out>: run `<prefix>printenv` in a fresh
# window of the pinned session, writing the child's environment to <out>. Waits on a
# sentinel written only AFTER printenv exits, never on <out> merely being non-empty:
# a non-empty check goes true on the first flushed block, so an absence assertion could
# pass on partially written output and prove nothing. Echoes nothing; caller reads <out>.
run_in_pinned_pane() {
  local win=$1 prefix=$2 out=$3 done_marker="$3.done" i=0
  rm -f "$out" "$done_marker"
  tmux -L "$E2E_SOCKET" new-window -d -t "$E2E_SES:" -n "$win" -c "$TMP_ROOT" \
    bash --norc --noprofile
  tmux -L "$E2E_SOCKET" send-keys -t "$E2E_SES:$win" -l \
    "${prefix}printenv > '$out'; printf 'DONE\n' > '$done_marker'"
  tmux -L "$E2E_SOCKET" send-keys -t "$E2E_SES:$win" Enter
  while [ "$i" -lt 100 ]; do
    [ -s "$done_marker" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_env_unset_defeats_a_pinned_tmux_session() {
  local control="$TMP_ROOT/control.env" guarded="$TMP_ROOT/guarded.env" var
  # Skip gracefully if tmux is not installed; half 1 runs over a fake tmux regardless.
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  # Pane shells run with no rc files: tmux applies the session environment first and a
  # developer's own ~/.zshrc or ~/.bashrc exporting one of these variables would override
  # it afterwards, defeating the fixture. The session-environment inheritance this half
  # exists to prove is unaffected.
  tmux -L "$E2E_SOCKET" new-session -d -s "$E2E_SES" -x 200 -y 50 -c "$TMP_ROOT" \
    bash --norc --noprofile \
    || fail "could not create tmux session $E2E_SES on socket $E2E_SOCKET"
  # The stale pins, recorded in the SESSION environment exactly as a long-running
  # firstmate session carries them. Every window created afterwards inherits them.
  for var in "${PINNED_VARS[@]}"; do
    tmux -L "$E2E_SOCKET" set-environment -t "$E2E_SES" "$var" "$PIN"
  done

  run_in_pinned_pane control '' "$control" \
    || fail "control pane never wrote its environment"
  for var in "${PINNED_VARS[@]}"; do
    assert_grep "$var=$PIN" "$control" \
      "fixture is not exercising the bug: a plainly-launched child did not inherit $var"
  done

  # An assignment operand rides through the same prefix, because `env -u <flags>
  # NAME=VALUE <command>` is exactly the composition the claude template's own env prefix
  # and the secondmate FM_HOME overrides depend on: flags first, assignments after, and
  # BSD env rejects the reverse order. Asserting the operand arrives intact proves that
  # form executes, not just that it string-matches.
  run_in_pinned_pane guarded "${PREFIX}FM_MODEL_PIN_PROBE=kept " "$guarded" \
    || fail "guarded pane never wrote its environment"
  assert_grep "PATH=" "$guarded" \
    "the guarded child produced no environment: the strip prefix did not run printenv"
  assert_grep "FM_MODEL_PIN_PROBE=kept" "$guarded" \
    "an assignment operand after the strip prefix's -u flags did not reach the child"
  for var in "${PINNED_VARS[@]}"; do
    assert_no_grep "$var=" "$guarded" \
      "the strip prefix left $var in the launched process's environment"
  done
  pass "env -u strip: a child launched in a pinned tmux session carries no model pin"
}

test_launch_command_strips_pin_on_every_path
test_env_unset_defeats_a_pinned_tmux_session
