# shellcheck shell=bash
# Shared core.hooksPath setup for a launch target, so a project's *committed* git
# hooks apply automatically instead of depending on a remembered per-clone step.
# Usage: . bin/fm-hooks-path-lib.sh
#
# Why this exists at all. A project that wants its hooks to be reviewable and to
# travel with the repo has to commit them, and the only way git runs a committed
# hooks directory is core.hooksPath. The alternative, .git/hooks, is not
# version-controlled and does not survive a fresh clone - and crews here do not
# work in long-lived clones, they work in treehouse pools that are created and
# destroyed constantly, so "dies on a fresh pool" is the routine case rather than
# the rare one. That makes core.hooksPath the only workable mechanism, and its
# one real drawback is that it needs a config step per clone.
#
# LOAD-BEARING - fm-spawn IS THAT CONFIG STEP. It already sets repo-local git config in
# every worktree and home it launches into (user.name/user.email, see
# fm-git-author-lib.sh), so setting core.hooksPath in the same place converts a
# remembered manual step into an automatic one. The coupling that creates is
# deliberate but load-bearing and must not be discovered by accident: if
# fm-spawn ever stops calling fm_hooks_path_apply, every project's committed
# hooks silently stop applying to every crew worktree, with no error anywhere -
# a missing hook is not a git failure, it is simply nothing happening. See the
# matching note in AGENTS.md section 7 (Spawn).
#
# SAFETY - core.hooksPath OVERRIDES .git/hooks entirely. Setting it in a repo
# that relies on .git/hooks would silently disable those hooks, and fm-spawn
# launches into every project in the fleet, not only the ones adopting committed
# hooks. So this is deliberately conditional and conservative: it writes only
# into a repo that demonstrably has the committed hooks directory, and it never
# overwrites an explicitly-set value. Three separate conditions must hold, and
# every one of them that fails leaves the repo exactly as it was:
#
#   1. The hooks directory ($FM_HOOKS_DIR, default .githooks) must be tracked in
#      the launch target's index AND present on disk with at least one file.
#      Tracked-only would fire on a branch where the directory is not checked
#      out; on-disk-only would let a stray untracked directory take over the
#      repo's hooks. An empty directory is not adoption either - it would
#      suppress .git/hooks while supplying no hook of its own.
#   2. No conflicting core.hooksPath may already be set, in ANY scope. This
#      reads the effective value rather than only --local, which is stricter
#      than the git-author precedent, deliberately: an identity falls back to a
#      value git derives on its own, so a --local write there overrides nothing
#      a human chose, whereas a core.hooksPath in global config is by definition
#      something a human set on purpose and a --local write would silently
#      defeat it.
#   3. The repo's real hooks directory must hold no active hook. Sample files
#      (*.sample) are git's inert scaffolding and do not count. This is the
#      condition that directly guards the stated risk: a repo actually using
#      .git/hooks keeps them and is reported, never quietly overridden. A hook
#      installed as a symlink counts as active - husky and hand-rolled setups
#      install hooks that way, and a dangling one counts too, because the write
#      would override it just as silently either way. The probe is deliberately
#      OVER-inclusive: any non-sample entry blocks, regardless of name or
#      executable bit, because failing loud and wrong beats failing silent and
#      wrong. The warning therefore names every entry it found rather than one
#      example: a permanent block plus a recurring per-spawn warning that turns
#      out to be a stray .DS_Store is exactly how a real warning becomes
#      background noise people learn to skip, and an ignored warning is a
#      documented gotcha with extra steps. Naming the files makes a false
#      positive diagnosable and clearable in seconds instead of a mystery block
#      someone works around. This condition also fails CLOSED: if the repo's
#      real hooks directory cannot be resolved at all, the write is skipped
#      rather than proceeding unguarded, matching every other condition here in
#      leaving the repo exactly as it was - and it says so, because a silent
#      fail-closed on an older git would disable committed hooks fleet-wide
#      while being indistinguishable from working.
#
# Before any of those three, OUR OWN repo-local core.hooksPath is VALIDATED
# rather than short-circuited past: if it names a directory that does not exist,
# that is reported. Order matters here, and it is the whole point - condition 1
# returns as soon as the hooks directory is missing, so a value left behind
# after a project drops the directory would be hidden by the same short-circuit
# that prevents it ever being re-evaluated, and a defect that disables its own
# detection is strictly worse than one that merely fails quietly. The blast
# radius earns the check: git pointed at a directory that no longer exists runs
# no committed hook and no check gate for that project, with no signal, in a
# long-lived fleet-synced clone that is never recreated the way a crew worktree
# is. The stale value itself is named in the warning, because a warning that
# says something is stale without saying what is a mystery, and a mystery
# warning gets skipped.
#
# This check is deliberately SCOPED - to --local, and to a value equal to the
# committed hooks directory this library writes - and that scoping is what keeps
# it honest, unlike condition 2 which must keep reading the effective value
# across every scope. Reading an effective value here would call a
# correctly-configured project broken: husky legitimately sets
# core.hooksPath=.husky/_ while .husky/_ is gitignored, so a fresh treehouse
# worktree lacks it until npm install and every single spawn would warn, with a
# suggested remedy ("corrected or unset") that would BREAK that project. A
# core.hooksPath set globally would warn the same way while being wrongly
# attributed to this worktree's path. Scoping loses nothing the check was for:
# a project that adopts the committed hooks directory and later drops it is
# still caught, because that value is ours.
#
# The value written is RELATIVE (.githooks), never absolute, and that is a
# correctness requirement rather than a style choice. git config --local from a
# linked worktree resolves to the pooled clone's shared common config, so the
# write is pool-wide: every checkout in that pool sees it. A relative path is
# re-resolved against each worktree's own working-tree root (verified: it also
# resolves correctly when git runs from a subdirectory), so each checkout runs
# its own committed hooks. That re-resolution is also why a pool-mate checkout
# whose branch lacks the directory simply runs no hook, silently and with no
# error, which is correct: nothing is configuring that checkout, and its own
# spawn will validate it when one happens. The stale check above is not in
# tension with that - it speaks only about the launch target this call is
# configuring right now, where "the directory our own value names is not here"
# is precisely the difference between the committed hooks working and this
# project's check gate being silently absent. An absolute path would instead
# pin the whole pool to one crew worktree's copy and break the moment that
# worktree is torn down.
#
# CONTAINMENT - the pool-wide write is not only "each checkout runs its own
# committed hooks". Because --local lands in the pool's shared common config, it
# also reaches the projects/<name> PRIMARY checkout, which firstmate operates
# automatically and unattended (bootstrap fleet-syncs every session, teardown
# fetches and deletes branches), in the session holding the fleet's credentials
# and .env. Without a counterweight this write turns a project's committed
# post-checkout/post-merge/reference-transaction hooks into project code running
# on a schedule inside firstmate's own automation, where before it only ever ran
# in a crewmate's worktree. So it ships WITH that counterweight, in the same
# change: every git call firstmate automation makes goes through fm_git, which
# disables hooks for that invocation (bin/fm-git-contain-lib.sh). Known
# boundary, stated rather than papered over: treehouse's own `git worktree add`
# fires post-checkout from inside the treehouse binary, which a helper in bin/
# cannot reach - the class is closed for firstmate's own git calls, not
# treehouse's.
#
# Like fm-git-author-lib.sh this is advisory: it always returns 0, because a
# hook is a safety net and failing to install one must never fail a spawn.

# The non-config git calls here go through fm_git, which disables committed hooks:
# firstmate automation must never execute repo-committed code (see
# bin/fm-git-contain-lib.sh). The `git ... config` reads and writes below stay
# bare, and that is the whole carve-out: `git -c core.hooksPath=/dev/null config
# core.hooksPath` reports /dev/null, which would make condition 2 below believe
# every repo already carried a conflicting value and skip the write everywhere.
# Config reads and writes run no hook, so nothing here is left uncontained.
# shellcheck source=bin/fm-git-contain-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-git-contain-lib.sh"

# fm_hooks_path_apply <target-dir> [report-conflict]: set repo-local
# core.hooksPath in the git repo at <target-dir> when that repo carries a
# committed hooks directory and nothing would be silently overridden. With a
# truthy second argument a preserved conflict, our own repo-local value pointing
# at a directory that no longer exists, and a skip that leaves committed hooks
# not running are reported to stderr, otherwise they are left silently. Never
# writes global or system config. Always returns 0.
fm_hooks_path_apply() {
  local dir=$1 report=${2:-} rel=${FM_HOOKS_DIR:-.githooks} cur local_cur target common legacy

  fm_git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Validate OUR OWN repo-local value BEFORE condition 1 can short-circuit on
  # the hooks directory being gone. Scoped to --local AND to a value equal to
  # $rel: a foreign value is somebody else's correct configuration (husky sets
  # core.hooksPath=.husky/_ with .husky/_ gitignored, so a fresh worktree lacks
  # it), and a global one is not this worktree's to report at all - see the
  # header. A relative value re-resolves against this worktree's own root, which
  # is what makes it safe pool-wide and also what makes it silently point at
  # nothing once the directory stops being checked out here.
  local_cur=$(git -C "$dir" config --local core.hooksPath 2>/dev/null || true)
  if [ "$local_cur" = "$rel" ]; then
    case "$rel" in
      '~') target=$HOME ;;
      '~'/*) target="$HOME/${rel#'~'/}" ;;
      /*) target=$rel ;;
      *) target="$dir/$rel" ;;
    esac
    if [ ! -d "$target" ] && [ -n "$report" ]; then
      printf 'warning: %s has core.hooksPath set to "%s", which does not exist; no committed hook and no check gate runs there until that value is corrected or unset\n' \
        "$dir" "$rel" >&2
    fi
  fi

  # Condition 2 reads the EFFECTIVE value across every scope, deliberately: a
  # core.hooksPath set globally is something a human chose on purpose and a
  # --local write would silently defeat it.
  cur=$(git -C "$dir" config core.hooksPath 2>/dev/null || true)

  # Condition 1: committed (tracked in this worktree's index) and actually
  # checked out here with at least one file in it.
  fm_git -C "$dir" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 0
  [ -d "$dir/$rel" ] || return 0
  [ -n "$(ls -A "$dir/$rel" 2>/dev/null)" ] || return 0

  # Condition 2: no conflicting value already set, in any scope.
  if [ -n "$cur" ]; then
    if [ "$cur" != "$rel" ] && [ -n "$report" ]; then
      printf 'warning: %s keeps a different core.hooksPath ("%s"); leaving it unchanged, committed hooks in %s will not run\n' \
        "$dir" "$cur" "$rel" >&2
    fi
    return 0
  fi

  # Condition 3: no active hook in the repo's real hooks directory that this
  # would override. Resolved from --git-common-dir rather than
  # `rev-parse --git-path hooks`, because that form already honours
  # core.hooksPath and so cannot report what is being overridden. An
  # unresolvable common dir (older git without --path-format, or any other
  # rev-parse failure) leaves this guard unable to answer, so it skips the write
  # rather than proceeding blind past the one condition protecting .git/hooks -
  # and says why, since a silent skip here disables committed hooks for every
  # project in the fleet while looking exactly like nothing being wrong.
  common=$(fm_git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$common" ]; then
    if [ -n "$report" ]; then
      printf 'warning: %s cannot resolve its git common dir (git older than 2.31 has no rev-parse --path-format; any other rev-parse failure lands here too), so the .git/hooks guard cannot answer; not setting core.hooksPath, committed hooks in %s will not run\n' \
        "$dir" "$rel" >&2
    fi
    return 0
  fi
  if [ -d "$common/hooks" ]; then
    # Every match is named, not just the first: see the header on why an
    # unexplained recurring block becomes noise people learn to skip.
    legacy=$(find "$common/hooks" -maxdepth 1 \( -type f -o -type l \) ! -name '*.sample' 2>/dev/null \
      | sed 's|.*/||' | sort | awk 'BEGIN { ORS = "" } NR > 1 { print ", " } { print }')
    if [ -n "$legacy" ]; then
      if [ -n "$report" ]; then
        printf 'warning: %s has active hooks in %s (%s); not setting core.hooksPath, which would silently disable them\n' \
          "$dir" "$common/hooks" "$legacy" >&2
      fi
      return 0
    fi
  fi

  git -C "$dir" config --local core.hooksPath "$rel" 2>/dev/null || true
  return 0
}
