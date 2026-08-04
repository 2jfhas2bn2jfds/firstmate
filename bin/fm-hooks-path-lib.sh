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
#      would override it just as silently either way. This condition also fails
#      CLOSED: if the repo's real hooks directory cannot be resolved at all, the
#      write is skipped rather than proceeding unguarded, matching every other
#      condition here in leaving the repo exactly as it was.
#
# The value written is RELATIVE (.githooks), never absolute, and that is a
# correctness requirement rather than a style choice. git config --local from a
# linked worktree resolves to the pooled clone's shared common config, so the
# write is pool-wide: every checkout in that pool sees it. A relative path is
# re-resolved against each worktree's own working-tree root (verified: it also
# resolves correctly when git runs from a subdirectory), so each checkout runs
# its own committed hooks, and a checkout whose branch lacks the directory
# simply runs no hook - silently, with no error. An absolute path would instead
# pin the whole pool to one crew worktree's copy and break the moment that
# worktree is torn down.
#
# Like fm-git-author-lib.sh this is advisory: it always returns 0, because a
# hook is a safety net and failing to install one must never fail a spawn.

# fm_hooks_path_apply <target-dir> [report-conflict]: set repo-local
# core.hooksPath in the git repo at <target-dir> when that repo carries a
# committed hooks directory and nothing would be silently overridden. With a
# truthy second argument a preserved conflict is reported to stderr, otherwise
# it is left silently. Never writes global or system config. Always returns 0.
fm_hooks_path_apply() {
  local dir=$1 report=${2:-} rel=${FM_HOOKS_DIR:-.githooks} cur common legacy

  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Condition 1: committed (tracked in this worktree's index) and actually
  # checked out here with at least one file in it.
  git -C "$dir" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 0
  [ -d "$dir/$rel" ] || return 0
  [ -n "$(ls -A "$dir/$rel" 2>/dev/null)" ] || return 0

  # Condition 2: no conflicting value already set, in any scope.
  cur=$(git -C "$dir" config core.hooksPath 2>/dev/null || true)
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
  # rather than proceeding blind past the one condition protecting .git/hooks.
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -n "$common" ] || return 0
  if [ -d "$common/hooks" ]; then
    legacy=$(find "$common/hooks" -maxdepth 1 \( -type f -o -type l \) ! -name '*.sample' 2>/dev/null | head -n 1)
    if [ -n "$legacy" ]; then
      if [ -n "$report" ]; then
        printf 'warning: %s has an active hook in %s (e.g. %s); not setting core.hooksPath, which would silently disable it\n' \
          "$dir" "$common/hooks" "$(basename "$legacy")" >&2
      fi
      return 0
    fi
  fi

  git -C "$dir" config --local core.hooksPath "$rel" 2>/dev/null || true
  return 0
}
