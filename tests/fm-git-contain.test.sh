#!/usr/bin/env bash
# Behavior tests for hook containment in firstmate's own git automation
# (bin/fm-git-contain-lib.sh and the call sites that route through it).
#
# FIRSTMATE'S OWN AUTOMATED GIT OPERATIONS MUST NEVER EXECUTE REPO-COMMITTED
# CODE. Setting core.hooksPath (bin/fm-hooks-path-lib.sh) writes into the pool's
# SHARED common config, so it reaches the projects/<name> primary checkout that
# firstmate fleet-syncs, merges and tears down unattended, in the session holding
# the fleet's credentials and .env. Without containment a project's committed
# hooks would run there on a schedule with nobody watching.
#
# The guarantees under test:
#   - a project whose committed post-checkout, post-merge AND reference-transaction
#     hooks are wired through core.hooksPath sees NONE of them fire when firstmate
#     automation (fleet-sync, local merge, review-diff) operates on it;
#   - the POSITIVE CONTROL: those same hooks DO fire for exactly those git
#     operations without containment. A containment test that never saw the hook
#     fire is vacuous and would pass against a broken harness, so every
#     containment assertion here is paired with one that proves the fixture is
#     live;
#   - the class stays closed: bin/ carries no uncontained git call site, so a git
#     call added to firstmate automation later cannot silently opt out.
#
# Scope note: the containment is scoped by "does this touch refs or the
# worktree", not by hook name - reference-transaction fires on nearly every
# ref-touching operation, plain branch creation included. The verbs exercised
# here (fetch, merge --ff-only, checkout, branch -D) are every ref/worktree
# touching verb bin/ uses; the lint covers the rest of the call sites
# structurally.
#
# Known boundary, asserted nowhere because no helper in bin/ can close it:
# treehouse fires post-checkout from inside its own `git worktree add`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
fm_git_isolate

TMP_ROOT=$(fm_test_tmproot fm-git-contain)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HOOK_DIR='.githooks'
N=0

# --- fixture ----------------------------------------------------------------

# make_fleet <label>: build an isolated FM_HOME holding projects/<label>, a clone
# of a bare origin whose committed .githooks/ carries post-checkout, post-merge
# and reference-transaction hooks, each appending its own name to a fire log.
# The clone gets core.hooksPath=.githooks exactly as a spawn into that pool would
# leave it (the write lands in the shared common config, so the primary checkout
# inherits it). The origin is then advanced by one commit and a merged side
# branch is deleted on the remote, so a fleet-sync has a fetch, a fast-forward
# and a prune to do.
#
# Echoes "<home> <clone> <firelog>".
make_fleet() {
  local label=$1 home work remote clone fired remote_abs hook
  N=$((N + 1))
  home="$TMP_ROOT/$label-$N"
  work="$home/work"
  remote="$home/remote.git"
  clone="$home/projects/$label"
  fired="$home/fired"
  mkdir -p "$home/projects" "$home/state" "$home/data"
  : > "$fired"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  mkdir -p "$work/$HOOK_DIR"
  for hook in post-checkout post-merge reference-transaction; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> %s\nexit 0\n' "$hook" "$fired" > "$work/$HOOK_DIR/$hook"
    chmod +x "$work/$HOOK_DIR/$hook"
  done
  printf 'v0\n' > "$work/file.txt"
  git -C "$work" add -A
  git -C "$work" commit -qm C0

  # A side branch that exists on the remote at clone time and is deleted after,
  # so the clone ends up with a local branch whose upstream is [gone] - the shape
  # fleet-sync's prune (branch -D) keys on.
  git -C "$work" branch merged-side

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q --track merged-side origin/merged-side
  # The pool-wide value a spawn leaves behind. From here on, every git command
  # run against this clone would run the committed hooks unless contained.
  git -C "$clone" config --local core.hooksPath "$HOOK_DIR"
  [ -x "$clone/$HOOK_DIR/post-merge" ] || fail "fixture: committed hooks are not checked out in the clone"

  # Advance the remote and drop the side branch, giving the sync real work.
  printf 'v1\n' > "$work/file.txt"
  git -C "$work" add -A
  git -C "$work" commit -qm C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete merged-side

  : > "$fired"
  printf '%s %s %s\n' "$home" "$clone" "$fired"
}

fired_list() { tr '\n' ' ' < "$1" | sed 's/ *$//'; }

assert_no_hooks_fired() {
  local fired=$1 what=$2
  [ -s "$fired" ] && fail "$what executed repo-committed hook code: $(fired_list "$fired")"
  return 0
}

assert_hooks_fired() {
  local fired=$1 what=$2
  [ -s "$fired" ] || fail "positive control is vacuous: $what fired no committed hook, so the fixture proves nothing"
  return 0
}

run_fleet_sync() {
  local home=$1
  FM_HOME="$home" FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-fleet-sync.sh" 2>&1
}

# --- P1: POSITIVE CONTROL - the committed hooks really do fire --------------
# Run the very operations firstmate automation runs, but as plain git. If these
# do not fire the hooks, every containment assertion below is vacuous.
test_positive_control_hooks_fire() {
  local out _home clone fired
  out=$(make_fleet control); read -r _home clone fired <<< "$out"

  git -C "$clone" fetch origin --prune --quiet 2>/dev/null
  assert_hooks_fired "$fired" "an uncontained fetch"
  assert_contains "$(fired_list "$fired")" "reference-transaction" \
    "an uncontained fetch did not fire reference-transaction"

  : > "$fired"
  git -C "$clone" merge --ff-only origin/main >/dev/null 2>&1
  assert_hooks_fired "$fired" "an uncontained merge --ff-only"
  assert_contains "$(fired_list "$fired")" "post-merge" \
    "an uncontained fast-forward did not fire post-merge"

  : > "$fired"
  git -C "$clone" branch -D merged-side >/dev/null 2>&1
  assert_hooks_fired "$fired" "an uncontained branch -D"

  : > "$fired"
  git -C "$clone" checkout --quiet -B side-checkout >/dev/null 2>&1
  assert_hooks_fired "$fired" "an uncontained checkout"
  assert_contains "$(fired_list "$fired")" "post-checkout" \
    "an uncontained checkout did not fire post-checkout"
  pass "P1 positive control: fetch, merge, branch -D and checkout DO run committed hooks uncontained"
}

# --- P1b: the containment flag itself suppresses them ------------------------
# The mechanism, pinned directly against the same live fixture, so a failure in
# the call-site tests below can be told apart from a failure of the mechanism.
test_flag_suppresses_hooks() {
  local out _home clone fired
  out=$(make_fleet flag); read -r _home clone fired <<< "$out"

  git -c core.hooksPath=/dev/null -C "$clone" fetch origin --prune --quiet 2>/dev/null
  git -c core.hooksPath=/dev/null -C "$clone" merge --ff-only origin/main >/dev/null 2>&1
  git -c core.hooksPath=/dev/null -C "$clone" branch -D merged-side >/dev/null 2>&1
  git -c core.hooksPath=/dev/null -C "$clone" checkout --quiet -B side-checkout >/dev/null 2>&1
  assert_no_hooks_fired "$fired" "the contained git invocations"

  # And the fixture is still live afterwards: the same repo fires without the flag.
  git -C "$clone" checkout --quiet -B still-live >/dev/null 2>&1
  assert_hooks_fired "$fired" "the fixture after the contained run"
  pass "P1b core.hooksPath=/dev/null suppresses committed hooks for that invocation"
}

# --- P2: fm-fleet-sync runs no committed hook -------------------------------
# The path bootstrap runs on EVERY session start, unattended. It fetches,
# fast-forwards and prunes - three ref/worktree touching operations.
test_fleet_sync_contained() {
  local out home clone fired sync
  out=$(make_fleet sync); read -r home clone fired <<< "$out"

  sync=$(run_fleet_sync "$home")
  assert_contains "$sync" "synced" "fixture: fleet-sync did not actually fast-forward, so nothing was under test"
  assert_contains "$sync" "pruned merged-side" "fixture: fleet-sync did not actually prune, so branch -D was not exercised"
  assert_no_hooks_fired "$fired" "fm-fleet-sync.sh"
  [ -x "$clone/$HOOK_DIR/post-merge" ] \
    || fail "fixture: the committed hooks vanished from the clone, so nothing could have fired anyway"
  pass "P2 fm-fleet-sync fetches, fast-forwards and prunes without running committed hooks"
}

# --- P2b: fm-fleet-sync's detached-HEAD recovery (checkout) is contained -----
test_fleet_sync_recovery_contained() {
  local out home clone fired sync
  out=$(make_fleet recover); read -r home clone fired <<< "$out"
  # The one drift fleet-sync self-heals: clean detached HEAD holding no unique
  # commits. Recovery does a real `checkout`, which is what fires post-checkout.
  git -c core.hooksPath=/dev/null -C "$clone" checkout --quiet --detach HEAD
  : > "$fired"

  sync=$(run_fleet_sync "$home")
  assert_contains "$sync" "recovered" "fixture: fleet-sync did not take the recovery path, so checkout was not exercised"
  assert_no_hooks_fired "$fired" "fm-fleet-sync.sh recovery checkout"
  pass "P2b fm-fleet-sync's re-attach checkout runs no committed hook"
}

# --- P3: fm-merge-local runs no committed hook -------------------------------
# The captain-approved local merge: a real fast-forward into the project's own
# default branch, i.e. firstmate writing inside a project on purpose.
test_merge_local_contained() {
  local out home clone fired merged
  out=$(make_fleet merge); read -r home clone fired <<< "$out"
  git -c core.hooksPath=/dev/null -C "$clone" branch -f --no-track "fm/ml-a1" origin/main 2>/dev/null
  fm_write_meta "$home/state/ml-a1.meta" \
    "window=firstmate:fm-ml-a1" "worktree=$clone" "project=$clone" \
    "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
  : > "$fired"

  merged=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" ml-a1 2>&1) || fail "merge-local failed: $merged"
  assert_contains "$merged" "merged fm/ml-a1" "fixture: merge-local did not actually merge"
  assert_no_hooks_fired "$fired" "fm-merge-local.sh"
  pass "P3 fm-merge-local fast-forwards local main without running committed hooks"
}

# --- P4: fm-review-diff runs no committed hook -------------------------------
# It fetches into the crew worktree, which shares the pool's config and so also
# inherits core.hooksPath.
test_review_diff_contained() {
  local out home clone fired wt diff
  out=$(make_fleet review); read -r home clone fired <<< "$out"
  wt="$home/wt-rd-b2"
  git -c core.hooksPath=/dev/null -C "$clone" worktree add -q -b "fm/rd-b2" "$wt" origin/main
  fm_write_meta "$home/state/rd-b2.meta" \
    "window=firstmate:fm-rd-b2" "worktree=$wt" "project=$clone" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  : > "$fired"

  diff=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-review-diff.sh" rd-b2 --stat 2>&1) || fail "review-diff failed: $diff"
  assert_contains "$diff" "diff base: origin/main" "fixture: review-diff did not resolve the remote base, so no fetch ran"
  assert_no_hooks_fired "$fired" "fm-review-diff.sh"
  pass "P4 fm-review-diff fetches the base without running committed hooks"
}

# --- P5: the class is closed - no uncontained git call site in bin/ ----------
# This is the assertion that keeps containment from decaying one commit at a
# time. Fixing the instances and not the class is the failure being corrected
# here, so a NEW `git -C ...` or `git clone ...` in bin/ fails this test and has
# to go through fm_git.
#
# Scope: command-position git invocations naming a repo (`git -C`) or creating
# one (`git clone`) - the two forms firstmate automation uses. The single
# allowance is `git ... config`, which runs no hook and must stay bare because
# the containment flag is itself config and would perturb the values
# fm-git-author-lib.sh and fm-hooks-path-lib.sh inspect.
test_no_uncontained_call_sites() {
  local offenders
  offenders=$(
    grep -nE '(^|[;&|(]|\$\(|`|then |else |do |! |&& |\|\| )[[:space:]]*git[[:space:]]+(-C[[:space:]]|clone[[:space:]])' \
      "$ROOT"/bin/*.sh 2>/dev/null \
      | grep -vE ':[0-9]+:[[:space:]]*#' \
      | grep -vE 'git[[:space:]]+-C[[:space:]]+"[^"]*"[[:space:]]+config[[:space:]]' \
      | grep -v '/bin/fm-brief.sh:' \
      || true
  )
  [ -n "$offenders" ] \
    && fail "uncontained git call sites in bin/ (route them through fm_git, see bin/fm-git-contain-lib.sh):"$'\n'"$offenders"

  # The other half of the same coupling: a script that calls fm_git without
  # sourcing the helper would die at runtime, not silently run hooks - but it
  # would still be a broken automation path, so it is caught here rather than in
  # production.
  local f unsourced=''
  for f in "$ROOT"/bin/*.sh; do
    [ "$f" = "$ROOT/bin/fm-git-contain-lib.sh" ] && continue
    grep -qE '(^|[^[:alnum:]_-])fm_git[[:space:]]' "$f" || continue
    grep -q 'fm-git-contain-lib.sh"' "$f" || unsourced="$unsourced $f"
  done
  [ -n "$unsourced" ] && fail "these call fm_git without sourcing bin/fm-git-contain-lib.sh:$unsourced"
  pass "P5 no uncontained git call site in bin/ - a new one must go through fm_git"
}

# --- P5b: the lint is not vacuous -------------------------------------------
# A grep that matches nothing would pass P5 forever. Plant an uncontained call
# site in a scratch copy of bin/ and require the same rule to catch it.
test_lint_catches_a_new_call_site() {
  local scratch hits
  scratch="$TMP_ROOT/lint-scratch"
  mkdir -p "$scratch/bin"
  cat > "$scratch/bin/fm-new-thing.sh" <<'SH'
#!/usr/bin/env bash
sync_it() {
  git -C "$dir" fetch origin --prune --quiet
}
SH
  hits=$(
    grep -nE '(^|[;&|(]|\$\(|`|then |else |do |! |&& |\|\| )[[:space:]]*git[[:space:]]+(-C[[:space:]]|clone[[:space:]])' \
      "$scratch"/bin/*.sh 2>/dev/null \
      | grep -vE ':[0-9]+:[[:space:]]*#' \
      | grep -vE 'git[[:space:]]+-C[[:space:]]+"[^"]*"[[:space:]]+config[[:space:]]' \
      || true
  )
  [ -n "$hits" ] || fail 'the call-site lint does not catch a plainly uncontained "git -C ... fetch", so P5 proves nothing'
  pass "P5b the call-site lint catches a newly added uncontained git call"
}

# --- P6: fm_git is a transparent wrapper ------------------------------------
# Containment must not change what a caller sees, or call sites would drift back
# to bare git to get their output.
test_fm_git_passthrough() {
  local repo out code
  # shellcheck source=bin/fm-git-contain-lib.sh
  . "$ROOT/bin/fm-git-contain-lib.sh"
  repo="$TMP_ROOT/passthrough"
  git init -q "$repo"
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  git -C "$repo" commit -q --allow-empty -m only

  out=$(fm_git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$out" = main ] || fail "fm_git did not pass stdout through: got '$out'"

  set +e
  fm_git -C "$repo" rev-parse --verify --quiet refs/heads/nope >/dev/null 2>&1
  code=$?
  set -e
  [ "$code" != 0 ] || fail "fm_git swallowed a non-zero exit status"

  # It never persists the override: the repo's own config is untouched.
  fm_git -C "$repo" fetch --quiet 2>/dev/null || true
  [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ] \
    || fail "fm_git wrote core.hooksPath into the repo's config"
  pass "P6 fm_git passes stdout and exit status through and persists no config"
}

test_positive_control_hooks_fire
test_flag_suppresses_hooks
test_fleet_sync_contained
test_fleet_sync_recovery_contained
test_merge_local_contained
test_review_diff_contained
test_no_uncontained_call_sites
test_lint_catches_a_new_call_site
test_fm_git_passthrough

echo "# all fm-git-contain tests passed"
