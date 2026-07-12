# shellcheck shell=bash
# Shared agent-commit git identity, read from the local config/git-author file.
# Usage: . bin/fm-git-author-lib.sh
#
# Crew worktrees are created fresh by treehouse with no repo-local git identity,
# so their commits fall back to git's auto-derived "<user>@<host>.local" author.
# On a squash merge GitHub then reads that author off the branch commits and
# appends a "Co-authored-by: <user> <...local>" trailer, because the branch
# author differs from the merging account. The harness "include co-authored-by"
# setting cannot help - the suggestion reads commit author metadata, not harness
# config. Giving every agent commit the captain's own GitHub identity makes each
# a single-author commit and removes the suggestion at the source.
#
# The identity values are captain-private and must never live in this shared
# template, so they are read from a gitignored local file, config/git-author:
#
#     name=<github username>
#     email=<id>+<username>@users.noreply.github.com
#
# The noreply email attributes commits to the captain's GitHub account without
# exposing a real address (git requires some email; the noreply form satisfies
# both constraints). The file is optional: absent means a silent no-op (the
# expected shared-template default), while a present-but-unparseable file emits a
# single stderr warning and is otherwise a no-op. Blank and '#'-comment lines are
# ignored; a surrounding-whitespace and trailing-CR trim keeps a hand-edited or
# CRLF file working.

# fm_git_author_warn <config-file>: emit at most one malformed-config warning per
# process, so a script that calls apply in a loop never spams stderr.
fm_git_author_warn() {
  [ -n "${FM_GIT_AUTHOR_WARNED:-}" ] && return 0
  FM_GIT_AUTHOR_WARNED=1
  printf 'warning: %s present but unparseable (need name= and email=<...@...>); agent commit identity not set\n' "$1" >&2
}

# fm_git_author_values <config-file>: parse the name= and email= lines. On
# success echo "<name><TAB><email>" and return 0. Return 1 when the file is
# absent (a silent, expected no-op: the file is optional). Return 2 when the file
# exists but a usable name/email cannot be read, after one stderr warning.
fm_git_author_values() {
  local cfg=$1 line name='' email=''
  [ -f "$cfg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      '#'*|'') continue ;;
      name=*) name=${line#name=} ;;
      email=*) email=${line#email=} ;;
    esac
  done < "$cfg"
  # Trim surrounding whitespace (leading, then trailing) from each value.
  name=${name#"${name%%[![:space:]]*}"}; name=${name%"${name##*[![:space:]]}"}
  email=${email#"${email%%[![:space:]]*}"}; email=${email%"${email##*[![:space:]]}"}
  if [ -z "$name" ] || [ -z "$email" ] || case "$email" in *@*) false ;; *) true ;; esac; then
    fm_git_author_warn "$cfg"
    return 2
  fi
  printf '%s\t%s\n' "$name" "$email"
}

# fm_git_author_apply <target-dir> <config-file> [report-conflict]: set repo-local
# user.name/user.email in the git repo at <target-dir> from <config-file>, but
# only when the repo has no repo-local identity yet or already matches. An
# explicitly-different repo-local identity is left untouched; with a truthy third
# argument the conflict is reported to stderr, otherwise it is left silently.
# Never writes global or system config. Always returns 0 - identity is advisory,
# so a missing file or a conflict must never fail the caller.
#
# In a linked git worktree, repo-local config resolves to the shared common
# config, so a fresh crew worktree starts unset and this sets the captain identity
# for its commits; a firstmate-on-itself worktree already inheriting the primary's
# identity matches and is a no-op.
fm_git_author_apply() {
  local dir=$1 cfg=$2 report=${3:-} vals name email cur_name cur_email
  vals=$(fm_git_author_values "$cfg") || return 0
  name=${vals%%$'\t'*}
  email=${vals#*$'\t'}
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  cur_name=$(git -C "$dir" config --local user.name 2>/dev/null || true)
  cur_email=$(git -C "$dir" config --local user.email 2>/dev/null || true)
  if [ -z "$cur_name" ] && [ -z "$cur_email" ]; then
    git -C "$dir" config --local user.name "$name" || return 0
    git -C "$dir" config --local user.email "$email" || return 0
    return 0
  fi
  if [ "$cur_name" = "$name" ] && [ "$cur_email" = "$email" ]; then
    return 0
  fi
  if [ -n "$report" ]; then
    printf 'warning: %s keeps a different repo-local git identity (%s <%s>); leaving it unchanged\n' \
      "$dir" "${cur_name:-unset}" "${cur_email:-unset}" >&2
  fi
  return 0
}
