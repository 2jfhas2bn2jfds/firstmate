# shellcheck shell=bash
# Contained git for firstmate's own automation.
# Usage: . bin/fm-git-contain-lib.sh   (then call fm_git instead of git)
#
# WHY THIS EXISTS: FIRSTMATE'S OWN AUTOMATED GIT OPERATIONS MUST NEVER EXECUTE
# REPO-COMMITTED CODE. Firstmate runs unattended maintenance inside every project
# clone - bootstrap fleet-syncs on every session start, teardown fetches and
# deletes branches, the secondmate sync fast-forwards homes - all from the
# session that holds the fleet's credentials and .env, with nobody watching. A
# project's committed hooks are project code. Before committed hooks were wired
# up (bin/fm-hooks-path-lib.sh) that code only ever ran inside a crewmate's own
# worktree; setting core.hooksPath makes it reachable from firstmate's own
# maintenance too, because `git config --local` from a linked worktree lands in
# the pool's SHARED common config, so the projects/<name> primary checkout that
# firstmate drives automatically inherits the same value. Running project code
# on a schedule inside that session is not a hook feature, it is an unattended
# execution path, so every git call firstmate automation makes is contained here.
#
# FIX THE CLASS, NOT THE INSTANCES. This is one helper rather than N inline
# flags precisely so a git call added to firstmate automation later inherits
# containment instead of silently opting out. tests/fm-git-contain.test.sh lints
# bin/ for a bare `git -C`/`git clone` outside the two carve-outs below and fails
# on a new uncontained call site, so the class stays closed rather than
# re-opening one commit at a time.
#
# MECHANISM: `git -c core.hooksPath=/dev/null <cmd>` suppresses hooks for that
# invocation (git looks for /dev/null/<hook>, which cannot exist) without
# touching any config file, and git propagates it to the sub-gits it spawns. It
# is scoped by "does this touch refs or the worktree", NOT by hook name:
# reference-transaction fires on nearly every ref-touching operation, plain
# branch creation included, so the exposure is far wider than
# post-checkout/post-merge. Read-only commands (rev-parse, ls-files, show-ref,
# merge-base, worktree list, diff, log, status) run no hook at all; they go
# through the same helper anyway, because one uniform rule is what keeps the
# class closed - deciding per call site is how the gap reappears.
#
# CARVE-OUTS, both deliberate and both hook-free: bin/fm-git-author-lib.sh and
# bin/fm-hooks-path-lib.sh read and write repo-local config only, and the -c
# override would corrupt the very value they inspect - `git -c
# core.hooksPath=/dev/null config core.hooksPath` reports /dev/null, which would
# make the hooks-path guard believe every repo already had a conflicting value.
#
# KNOWN BOUNDARY, stated rather than papered over: treehouse runs its own
# `git worktree add` (and its own return/reset) inside the treehouse binary, so
# its post-checkout firing is outside anything a helper in bin/ can reach. The
# class is closed for firstmate's OWN git calls, not for treehouse's.

# fm_git <git args...>: run git with committed hooks disabled for this
# invocation. A drop-in replacement for `git` at every firstmate automation call
# site; exit status, stdout, and stderr pass through unchanged.
#
# PUSH IS REFUSED, not contained. The -c override propagates via
# GIT_CONFIG_PARAMETERS into every locally-spawned sub-git, and for a push to a
# file-path remote git-receive-pack is a direct child, so it inherits
# core.hooksPath=/dev/null and the remote's SERVER-SIDE
# pre-receive/update/post-receive hooks are silently suppressed - including the
# local no-mistakes bare gate's own post-receive, i.e. the very gate this fleet
# ships through. The P5 lint funnels every new git call site in bin/ into
# fm_git, so without this guard a silent server-side hook bypass would be the
# DEFAULT path for any push added later. Refusing loudly (rather than silently
# running push uncontained) forces that future author to decide explicitly:
# a push whose server-side hooks matter must not go through fm_git at all.
fm_git() {
  local arg subcmd='' skip=0
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$arg" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env) skip=1 ;;
      -*) ;;
      *) subcmd=$arg; break ;;
    esac
  done
  if [ "$subcmd" = push ]; then
    printf '%s\n' \
      "fm_git: refusing 'git push': fm_git sets core.hooksPath=/dev/null, which propagates via GIT_CONFIG_PARAMETERS into locally-spawned transport processes; for a file-path remote git-receive-pack is a direct child and inherits it, so SERVER-SIDE pre-receive/update/post-receive hooks would be silently suppressed, including the local no-mistakes bare gate's post-receive. Push through plain git from a call site that has decided its server-side hooks explicitly." >&2
    return 1
  fi
  git -c core.hooksPath=/dev/null "$@"
}
