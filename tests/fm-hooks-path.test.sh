#!/usr/bin/env bash
# Behavior tests for committed-hooks wiring (bin/fm-hooks-path-lib.sh and its
# wiring point, fm-spawn.sh).
#
# A project's committed hooks directory only runs through core.hooksPath, and
# fm-spawn is the config step that sets it in every worktree and home it
# launches into. Because core.hooksPath OVERRIDES .git/hooks entirely and
# fm-spawn launches into every project in the fleet, the write is deliberately
# conditional; these tests pin the conditions, since a wrongly-set or
# wrongly-skipped hooksPath produces no error at all - just a hook that silently
# does not run. The guarantees under test:
#   - apply sets core.hooksPath when the hooks directory is both tracked in the
#     launch target's index and checked out non-empty;
#   - the value written is RELATIVE (.githooks), never absolute, because
#     `git config --local` from a linked worktree lands in the pool's shared
#     common config and an absolute value would pin the whole pool to one crew
#     worktree's copy;
#   - apply is a no-op when the directory is absent, tracked-but-not-checked-out,
#     empty, or present-but-untracked;
#   - an already-set core.hooksPath is preserved and reported (never clobbered),
#     including one set in a non-local scope;
#   - a configured core.hooksPath pointing at a directory that no longer exists
#     is REPORTED rather than short-circuited past, naming the stale value, since
#     the short-circuit that would hide it is the same one that stops it ever
#     being re-evaluated;
#   - an active hook in the repo's real hooks directory blocks the write - a
#     regular file, a symlinked hook, and a dangling symlink all count as active,
#     while *.sample scaffolding does not - and the warning names every entry it
#     found, so a false positive is diagnosable rather than a mystery block;
#   - an unresolvable git common dir fails CLOSED (no write) and says why;
#   - fm-spawn sets core.hooksPath in the isolated worktree it launches into, and
#     reports a conflicting pool value instead of skipping silently.
# All hermetic over temp git repos and fakebins; never touches global git config,
# and fm_git_isolate neutralizes the host's global/system config so a developer
# who sets core.hooksPath or init.templateDir does not see false failures - this
# suite reads the EFFECTIVE config, not just --local, so that leak is real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-hooks-path-lib.sh
. "$ROOT/bin/fm-hooks-path-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

TMP_ROOT=$(fm_test_tmproot fm-hooks-path)
fm_git_identity fmtest fmtest@example.invalid
fm_git_isolate

HOOK_DIR='.githooks'

hooks_path() { git -C "$1" config --local core.hooksPath 2>/dev/null || true; }

# A fresh repo on `main` whose committed .githooks/pre-push is tracked and
# checked out. Echoes the repo path.
make_repo_with_hooks() {
  local dir=$1
  git init -q -b main "$dir"
  mkdir -p "$dir/$HOOK_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$dir/$HOOK_DIR/pre-push"
  chmod +x "$dir/$HOOK_DIR/pre-push"
  git -C "$dir" add "$HOOK_DIR/pre-push"
  git -C "$dir" commit -q -m 'add committed hooks'
  printf '%s\n' "$dir"
}

# A fresh repo on `main` with one commit and no committed hooks directory.
make_bare_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- T1: sets core.hooksPath when the hooks dir is tracked and checked out ----
test_sets_when_committed() {
  local repo out
  repo=$(make_repo_with_hooks "$TMP_ROOT/set")
  [ -z "$(hooks_path "$repo")" ] || fail "precondition: fresh repo should have no core.hooksPath"

  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero"
  [ -z "$out" ] || fail "a clean adoption must be silent, got: $out"

  [ "$(hooks_path "$repo")" = "$HOOK_DIR" ] || fail "core.hooksPath not set on a committed hooks dir"
  pass "T1 apply sets core.hooksPath when the hooks dir is tracked and checked out non-empty"
}

# --- T1b: the value written is RELATIVE, never absolute ------------------------
# An absolute path would pin a whole treehouse pool to one crew worktree's copy
# (the --local write lands in the pool's shared common config) and break the
# moment that worktree is torn down. A relative path re-resolves per worktree.
test_value_is_relative() {
  local repo pool_wt value resolved
  repo=$(make_repo_with_hooks "$TMP_ROOT/rel")
  fm_hooks_path_apply "$repo"

  value=$(hooks_path "$repo")
  [ "$value" = "$HOOK_DIR" ] || fail "expected the relative '$HOOK_DIR', got '$value'"
  case "$value" in
    /*) fail "core.hooksPath was written as an absolute path: $value" ;;
  esac
  case "$value" in
    *"$repo"*) fail "core.hooksPath embeds the worktree path: $value" ;;
  esac

  # A second, independent worktree of the same pool re-resolves that one shared
  # value against its own root rather than the first worktree's copy.
  pool_wt="$TMP_ROOT/rel-wt"
  git -C "$repo" worktree add -q --detach "$pool_wt" >/dev/null 2>&1
  # `pwd -P` so a symlinked temp root (macOS /var -> /private/var) compares equal
  # to the physical path git reports.
  resolved=$(cd "$pool_wt" && pwd -P)
  [ "$(git -C "$pool_wt" rev-parse --path-format=absolute --git-path hooks)" = "$resolved/$HOOK_DIR" ] \
    || fail "the pool-wide value does not resolve to the sibling worktree's own hooks dir"
  pass "T1b the written value is relative, so each worktree in a pool runs its own committed hooks"
}

# --- T2: no-op when the hooks directory does not exist ------------------------
test_noop_when_absent() {
  local repo out
  repo=$(make_bare_repo "$TMP_ROOT/absent")

  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply must return 0 with no hooks dir"
  [ -z "$out" ] || fail "a repo with no committed hooks must be silent, got: $out"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set with no committed hooks dir"
  pass "T2 apply is a silent no-op when the project has no committed hooks directory"
}

# --- T3: no-op when tracked but not checked out here --------------------------
# The index still carries the directory, but this checkout does not have it, so
# pointing git at it would leave the repo running no hook at all.
test_noop_when_not_checked_out() {
  local repo
  repo=$(make_repo_with_hooks "$TMP_ROOT/not-out")
  rm -rf "${repo:?}/$HOOK_DIR"
  git -C "$repo" ls-files --error-unmatch -- "$HOOK_DIR" >/dev/null 2>&1 \
    || fail "precondition: the hooks dir should still be tracked in the index"

  fm_hooks_path_apply "$repo" report 2>/dev/null || fail "apply returned non-zero"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set for a dir that is not checked out here"
  pass "T3 apply does not set core.hooksPath when the hooks dir is tracked but not checked out"
}

# --- T4: no-op when the checked-out hooks directory is empty ------------------
# An empty directory is not adoption: it would suppress .git/hooks while
# supplying no hook of its own.
test_noop_when_empty() {
  local repo
  repo=$(make_repo_with_hooks "$TMP_ROOT/empty")
  rm -f "$repo/$HOOK_DIR/pre-push"
  [ -d "$repo/$HOOK_DIR" ] || fail "precondition: the hooks dir should still exist"

  fm_hooks_path_apply "$repo" report 2>/dev/null || fail "apply returned non-zero"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set for an empty hooks dir"
  pass "T4 apply does not set core.hooksPath when the checked-out hooks dir is empty"
}

# --- T5: no-op when the hooks directory is present but untracked --------------
# A stray untracked directory must not be allowed to take over the repo's hooks.
test_noop_when_untracked() {
  local repo
  repo=$(make_bare_repo "$TMP_ROOT/untracked")
  mkdir -p "$repo/$HOOK_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$repo/$HOOK_DIR/pre-push"
  chmod +x "$repo/$HOOK_DIR/pre-push"

  fm_hooks_path_apply "$repo" report 2>/dev/null || fail "apply returned non-zero"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set for an untracked hooks dir"
  pass "T5 apply does not set core.hooksPath for a present-but-untracked hooks dir"
}

# --- T6: an already-set core.hooksPath is preserved and reported --------------
test_preserves_existing_local_value() {
  local repo out
  repo=$(make_repo_with_hooks "$TMP_ROOT/conflict")
  # The conflicting directory exists, so this test sees the conflict warning
  # alone - which doubles as the control that the staleness check (T9) stays
  # quiet about a value that still points at something.
  mkdir -p "$repo/custom-hooks"
  git -C "$repo" config --local core.hooksPath 'custom-hooks'

  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero on conflict"
  assert_contains "$out" "different core.hooksPath" "the conflicting value was not reported"
  assert_not_contains "$out" "does not exist" "an existing conflicting dir was wrongly reported as stale"
  [ "$(hooks_path "$repo")" = 'custom-hooks' ] || fail "the explicitly-set core.hooksPath was clobbered"

  # Without the report flag the same conflict is preserved, but silently.
  out=$(fm_hooks_path_apply "$repo" 2>&1) || fail "silent apply returned non-zero"
  [ -z "$out" ] || fail "conflict must be silent without the report flag, got: $out"
  [ "$(hooks_path "$repo")" = 'custom-hooks' ] || fail "the silent path clobbered the value"

  # A value that already matches is neither reported nor rewritten.
  git -C "$repo" config --local core.hooksPath "$HOOK_DIR"
  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero on a matching value"
  [ -z "$out" ] || fail "a matching value must be silent, got: $out"
  [ "$(git -C "$repo" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" = 1 ] \
    || fail "re-apply appended a duplicate core.hooksPath entry"
  pass "T6 apply preserves an explicitly-set core.hooksPath (reporting only when asked)"
}

# --- T6b: a value set in a NON-LOCAL scope is preserved too -------------------
# This is deliberately stricter than the git-author precedent: a core.hooksPath
# in global config is by definition something a human set on purpose, and a
# --local write would silently defeat it.
test_preserves_non_local_scope_value() {
  local repo fakehome out
  repo=$(make_repo_with_hooks "$TMP_ROOT/global-scope")
  fakehome="$TMP_ROOT/global-scope-home"
  mkdir -p "$fakehome/global-hooks"
  printf '[core]\n\thooksPath = %s/global-hooks\n' "$fakehome" > "$fakehome/.gitconfig"

  # A subshell so the fake global config never leaks into the rest of the suite.
  # GIT_CONFIG_GLOBAL is what the suite-wide fm_git_isolate pins to /dev/null and
  # it outranks HOME, so this test points it at the fixture rather than relying
  # on HOME alone.
  out=$(
    export GIT_CONFIG_GLOBAL="$fakehome/.gitconfig" \
      HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" GIT_CONFIG_NOSYSTEM=1
    [ -n "$(git -C "$repo" config core.hooksPath)" ] || { printf 'NO_GLOBAL\n'; exit 0; }
    fm_hooks_path_apply "$repo" report 2>&1
  ) || fail "apply returned non-zero with a global core.hooksPath"
  assert_not_contains "$out" "NO_GLOBAL" "precondition: the fake global core.hooksPath was not visible to git"
  assert_contains "$out" "different core.hooksPath" "the global-scope value was not reported"
  [ -z "$(hooks_path "$repo")" ] || fail "a --local write silently defeated the global core.hooksPath"
  pass "T6b apply preserves and reports a core.hooksPath set in a non-local scope"
}

# --- T6c: a configured core.hooksPath that no longer exists is REPORTED -------
# The failure this pins: a long-lived pooled clone adopts .githooks, the project
# later drops the directory, and the value survives in the clone's shared common
# config. Condition 1 then returns as soon as the directory is missing, so the
# short-circuit that hides the stale value is the same one that stops it ever
# being re-evaluated - and git pointed at a directory that does not exist runs no
# committed hook and no check gate at all. So this test does it the hard way: set
# the value, DELETE what it points at, and require that apply notices.
test_reports_stale_hooks_path() {
  local repo out
  repo=$(make_repo_with_hooks "$TMP_ROOT/stale")
  fm_hooks_path_apply "$repo"
  [ "$(hooks_path "$repo")" = "$HOOK_DIR" ] || fail "precondition: adoption should have set core.hooksPath"

  # The project drops its committed hooks directory; the clone keeps the value.
  git -C "$repo" rm -rq "$HOOK_DIR"
  git -C "$repo" commit -q -m 'drop committed hooks'
  if [ -d "$repo/$HOOK_DIR" ]; then fail "precondition: the hooks dir should be gone"; fi

  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero on a stale value"
  assert_contains "$out" "does not exist" "the stale core.hooksPath was short-circuited past, silently"
  assert_contains "$out" "$HOOK_DIR" "the warning does not name the stale value"
  [ "$(hooks_path "$repo")" = "$HOOK_DIR" ] || fail "the stale value was changed; this path only reports"

  # Silent without the report flag, like every other advisory here.
  out=$(fm_hooks_path_apply "$repo" 2>&1) || fail "silent apply returned non-zero on a stale value"
  [ -z "$out" ] || fail "the stale report must be silent without the report flag, got: $out"

  # An absolute value is checked the same way.
  git -C "$repo" config --local core.hooksPath "$TMP_ROOT/stale-abs"
  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero on a stale absolute value"
  assert_contains "$out" "$TMP_ROOT/stale-abs" "an absolute stale core.hooksPath was not reported"

  # The control that keeps this honest: create the directory that value names
  # and the warning stops. The check keys on the target existing, not merely on
  # a value being set, so a blanket "always warn" would fail here.
  mkdir -p "$TMP_ROOT/stale-abs"
  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero on a live absolute value"
  [ -z "$out" ] || fail "a core.hooksPath whose target exists must not be reported stale, got: $out"
  pass "T6c a core.hooksPath pointing at a deleted directory is reported, naming the stale value"
}

# --- T7: an active hook in the repo's real hooks dir blocks the write ---------
# core.hooksPath overrides .git/hooks entirely, so a repo actually using
# .git/hooks keeps them and is reported, never quietly overridden.
assert_legacy_hook_blocks() {
  local repo=$1 label=$2 out
  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero ($label)"
  assert_contains "$out" "has active hooks" "the active .git/hooks hook was not reported ($label)"
  assert_contains "$out" "(pre-commit)" "the warning did not name the blocking entry ($label)"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set over an active .git/hooks hook ($label)"
}

test_active_legacy_hook_blocks() {
  local repo out

  # A plain executable hook file.
  repo=$(make_repo_with_hooks "$TMP_ROOT/legacy-file")
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  assert_legacy_hook_blocks "$repo" "regular file"

  # A hook installed as a symlink - husky and hand-rolled setups do this, and
  # find's default -P reports it as type l, not type f.
  repo=$(make_repo_with_hooks "$TMP_ROOT/legacy-symlink")
  printf '#!/bin/sh\nexit 0\n' > "$repo/real-pre-commit"
  chmod +x "$repo/real-pre-commit"
  ln -s "$repo/real-pre-commit" "$repo/.git/hooks/pre-commit"
  assert_legacy_hook_blocks "$repo" "symlinked hook"

  # A dangling symlink still counts: the write would override it just as
  # silently, and the repo plainly means to have a hook there.
  repo=$(make_repo_with_hooks "$TMP_ROOT/legacy-dangling")
  ln -s "$TMP_ROOT/does-not-exist" "$repo/.git/hooks/pre-commit"
  assert_legacy_hook_blocks "$repo" "dangling symlink"

  # Sample files are git's inert scaffolding and must NOT block adoption. A
  # stock `git init` already leaves them behind, so counting them would make
  # this feature never fire anywhere.
  repo=$(make_repo_with_hooks "$TMP_ROOT/legacy-samples")
  rm -f "$repo"/.git/hooks/*
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-commit.sample"
  chmod +x "$repo/.git/hooks/pre-commit.sample"
  ln -s "$TMP_ROOT/whatever" "$repo/.git/hooks/pre-push.sample"
  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero (samples only)"
  [ -z "$out" ] || fail "sample files must not be reported as active hooks, got: $out"
  [ "$(hooks_path "$repo")" = "$HOOK_DIR" ] || fail "sample scaffolding wrongly blocked adoption"
  pass "T7 an active .git/hooks hook blocks the write (file, symlink, dangling); *.sample does not"
}

# --- T7a: the block names EVERY entry it found, not one example ---------------
# The probe is deliberately over-inclusive (any non-sample entry blocks,
# whatever its name or mode), so the block is only diagnosable if the warning
# says which files caused it. One basename behind "e.g." turns a stray
# .DS_Store into a mystery block someone works around.
test_active_hook_warning_names_every_entry() {
  local repo out
  repo=$(make_repo_with_hooks "$TMP_ROOT/legacy-many")
  rm -f "$repo"/.git/hooks/*
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-push"
  chmod +x "$repo/.git/hooks/pre-push"
  # A non-hook leftover: it blocks too, and naming it is what makes the block
  # clearable in seconds instead of a permanent unexplained one.
  printf 'noise\n' > "$repo/.git/hooks/.DS_Store"

  out=$(fm_hooks_path_apply "$repo" report 2>&1) || fail "apply returned non-zero (several entries)"
  assert_contains "$out" ".DS_Store" "the warning did not name the stray entry"
  assert_contains "$out" "pre-commit" "the warning did not name the first hook"
  assert_contains "$out" "pre-push" "the warning did not name the second hook"
  [ -z "$(hooks_path "$repo")" ] || fail "core.hooksPath was set over active .git/hooks entries"
  pass "T7a the active-hook warning names every entry it found, not just the first"
}

# --- T7b: an unresolvable git common dir fails CLOSED -------------------------
# The common dir is how condition 3 finds the hooks it must not override, so a
# rev-parse that cannot answer leaves the guard blind and the write is skipped.
test_unresolvable_common_dir_fails_closed() {
  local repo fakebin out
  repo=$(make_repo_with_hooks "$TMP_ROOT/no-common")
  fakebin=$(fm_fakebin "$TMP_ROOT/no-common-fake")
  # A git shim that answers every probe the earlier conditions make, but fails
  # the --git-common-dir resolution (as an older git without --path-format does).
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = '--git-common-dir' ]; then
    printf 'fatal: unknown option\n' >&2
    exit 129
  fi
done
exec $(command -v git) "\$@"
SH
  chmod +x "$fakebin/git"

  # A subshell so the shimmed PATH never leaks into the rest of the suite.
  # The controls matter: this is the one test that swaps out the git binary, so a
  # shim that broke an EARLIER probe would make apply return at condition 1 and
  # the "nothing was written" assertion would pass while proving nothing about
  # the fail-closed branch. Each control reports a marker instead of writing, so
  # a broken shim fails the test loudly.
  out=$(
    export PATH="$fakebin:$BASE_PATH"
    hash -r 2>/dev/null || true
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { printf 'SHIM_BROKE_WORKTREE_PROBE\n'; exit 0; }
    git -C "$repo" ls-files --error-unmatch -- "$HOOK_DIR" >/dev/null 2>&1 \
      || { printf 'SHIM_BROKE_TRACKED_PROBE\n'; exit 0; }
    [ -z "$(git -C "$repo" config core.hooksPath 2>/dev/null)" ] \
      || { printf 'SHIM_BROKE_CONFIG_PROBE\n'; exit 0; }
    git -C "$repo" rev-parse --path-format=absolute --git-common-dir >/dev/null 2>&1 \
      && { printf 'SHIM_RESOLVED_COMMON_DIR\n'; exit 0; }
    fm_hooks_path_apply "$repo" report 2>&1
  ) || fail "apply returned non-zero with an unresolvable common dir"

  assert_not_contains "$out" "SHIM_BROKE_WORKTREE_PROBE" \
    "control: the shim broke the is-inside-work-tree probe, so apply never reached condition 3"
  assert_not_contains "$out" "SHIM_BROKE_TRACKED_PROBE" \
    "control: the shim broke the tracked-hooks probe, so apply never reached condition 3"
  assert_not_contains "$out" "SHIM_BROKE_CONFIG_PROBE" \
    "control: the shim broke the core.hooksPath probe, so apply never reached condition 3"
  assert_not_contains "$out" "SHIM_RESOLVED_COMMON_DIR" \
    "control: the shim did not actually fail --git-common-dir, so nothing was under test"
  [ -z "$(hooks_path "$repo")" ] \
    || fail "core.hooksPath was written past a guard that could not check .git/hooks: $out"
  # Failing closed silently would disable committed hooks fleet-wide while
  # looking exactly like nothing being wrong, so the skip must say WHY.
  assert_contains "$out" "cannot resolve its git common dir" \
    "the fail-closed skip was silent, so a fleet-wide disable would leave no signal"
  assert_contains "$out" "2.31" "the fail-closed warning does not name the likely cause"

  # The closing control: with the real git back, this very repo adopts. That
  # proves the skip above was caused by the unresolvable common dir alone and
  # not by some other unmet condition in the fixture.
  fm_hooks_path_apply "$repo" || fail "apply returned non-zero with the real git"
  [ "$(hooks_path "$repo")" = "$HOOK_DIR" ] \
    || fail "control: the fixture never adopts even with a working git, so T7b proves nothing"
  pass "T7b an unresolvable git common dir fails closed, leaving the repo unchanged"
}

# --- T8: fm-spawn sets core.hooksPath in the worktree it launches into --------
# Mirror the ship-spawn stub pattern: a fake tmux that reports FM_FAKE_PANE_PATH
# as the post-`treehouse get` pane cwd, a real project repo, and a genuine
# isolated linked worktree the spawn resolves into.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --why captain 2>&1
}

test_spawn_sets_worktree_hooks_path() {
  local home proj wt fakebin out
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo_with_hooks "$TMP_ROOT/spawn-proj")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/spawn-wt"
  [ -z "$(hooks_path "$wt")" ] || fail "precondition: fresh worktree should have no core.hooksPath"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")

  out=$(run_spawn "$home" hooks-a1 "$proj" "$wt" "$fakebin") || fail "spawn failed: $out"

  assert_contains "$out" "spawned hooks-a1" "spawn did not report success"
  [ "$(hooks_path "$wt")" = "$HOOK_DIR" ] || fail "spawn did not set the worktree's core.hooksPath"
  pass "T8 fm-spawn sets core.hooksPath in the isolated worktree it launches into"
}

# --- T8b: fm-spawn reports a conflicting pool value, never silently -----------
test_spawn_reports_conflict() {
  local home proj wt fakebin out
  home="$TMP_ROOT/spawn-conf-home"
  mkdir -p "$home/data"
  proj=$(make_repo_with_hooks "$TMP_ROOT/spawn-conf-proj")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-conf-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/spawn-conf-wt"
  git -C "$wt" config --local core.hooksPath 'pool-hooks'
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-conf-fake")

  out=$(run_spawn "$home" hooks-b2 "$proj" "$wt" "$fakebin") || fail "spawn failed: $out"

  assert_contains "$out" "spawned hooks-b2" "spawn did not report success"
  assert_contains "$out" "different core.hooksPath" "spawn did not report the conflicting pool value"
  [ "$(hooks_path "$wt")" = 'pool-hooks' ] || fail "spawn clobbered the pool's core.hooksPath"
  pass "T8b fm-spawn reports a conflicting pool core.hooksPath instead of skipping silently"
}

test_sets_when_committed
test_value_is_relative
test_noop_when_absent
test_noop_when_not_checked_out
test_noop_when_empty
test_noop_when_untracked
test_preserves_existing_local_value
test_preserves_non_local_scope_value
test_reports_stale_hooks_path
test_active_legacy_hook_blocks
test_active_hook_warning_names_every_entry
test_unresolvable_common_dir_fails_closed
test_spawn_sets_worktree_hooks_path
test_spawn_reports_conflict

echo "# all fm-hooks-path tests passed"
