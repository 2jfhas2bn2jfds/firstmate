#!/usr/bin/env bash
# Behavior tests for the agent-commit git identity (bin/fm-git-author-lib.sh and
# its two wiring points, fm-spawn.sh and fm-bootstrap.sh).
#
# Treehouse worktrees start with no repo-local git identity, so agent commits fall
# back to git's auto-derived "<user>@<host>.local" author, which makes GitHub
# suggest a Co-authored-by trailer on squash merge. The fix reads the captain's
# GitHub identity from the gitignored config/git-author file and sets it repo-local
# in every worktree/home fm-spawn launches into, plus the firstmate primary in
# bootstrap. The guarantees under test:
#   - the config parser trims whitespace/CRLF (including an indented key), ignores
#     blanks and comments, and rejects a missing or '@'-less value as malformed
#     (one stderr warning);
#   - apply sets a fresh repo's repo-local identity, is idempotent when it already
#     matches, is a silent no-op when the file is absent, works per field (a
#     partial identity completes its unset field), and never clobbers an
#     explicitly-different field (reporting only when asked);
#   - fm-spawn sets the identity in the isolated worktree it launches into, and
#     reports a conflicting pool identity instead of skipping silently;
#   - fm-bootstrap sets the primary's identity, and skips-with-a-report on a
#     conflicting primary identity.
# All hermetic over temp git repos and fakebins; never touches global git config.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-git-author-lib.sh
. "$ROOT/bin/fm-git-author-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

TMP_ROOT=$(fm_test_tmproot fm-git-author)
# Deterministic identity for fixture commits (never the identity under test).
fm_git_identity fmtest fmtest@example.invalid

# The captain-identity fixture the config file carries in these tests.
CAP_NAME='captainhook'
CAP_EMAIL='424242+captainhook@users.noreply.github.com'

# write_author_config <path> [name] [email]: write a well-formed config/git-author.
write_author_config() {
  local path=$1 name=${2:-$CAP_NAME} email=${3:-$CAP_EMAIL}
  mkdir -p "$(dirname "$path")"
  printf 'name=%s\nemail=%s\n' "$name" "$email" > "$path"
}

# A fresh git repo on `main` with one commit and NO repo-local identity. Echoes it.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

local_name() { git -C "$1" config --local user.name 2>/dev/null || true; }
local_email() { git -C "$1" config --local user.email 2>/dev/null || true; }

# --- T1: the parser trims, skips blanks/comments, and validates --------------
test_values_parse() {
  local cfg out name email
  cfg="$TMP_ROOT/parse.cfg"
  mkdir -p "$TMP_ROOT"
  # Surrounding whitespace, a trailing CR, a comment, a blank line, an indented
  # key, out of order.
  printf '# captain identity\r\n\n  email=  %s \r\nname=\t%s  \n' "$CAP_EMAIL" "$CAP_NAME" > "$cfg"

  out=$(fm_git_author_values "$cfg") || fail "values returned non-zero on a valid config"
  name=${out%%$'\t'*}
  email=${out#*$'\t'}
  [ "$name" = "$CAP_NAME" ] || fail "parsed name '$name' != '$CAP_NAME' (trim/comment/order handling)"
  [ "$email" = "$CAP_EMAIL" ] || fail "parsed email '$email' != '$CAP_EMAIL'"
  pass "T1 parser trims whitespace/CR (indented keys too), ignores blanks and comments, tolerates key order"
}

# --- T2: apply sets a fresh repo's repo-local identity from the config --------
test_apply_sets_fresh() {
  local repo cfg
  repo=$(make_repo "$TMP_ROOT/set-fresh")
  cfg="$TMP_ROOT/set-fresh.cfg"
  write_author_config "$cfg"
  [ -z "$(local_name "$repo")" ] || fail "precondition: fresh repo should have no local user.name"

  fm_git_author_apply "$repo" "$cfg" || fail "apply returned non-zero"

  [ "$(local_name "$repo")" = "$CAP_NAME" ] || fail "user.name not set from config"
  [ "$(local_email "$repo")" = "$CAP_EMAIL" ] || fail "user.email not set from config"
  pass "T2 apply sets a fresh repo's repo-local identity from config/git-author"
}

# --- T3: apply is a silent no-op when the config file is absent ---------------
test_apply_absent_noop() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/absent")

  out=$(fm_git_author_apply "$repo" "$TMP_ROOT/does-not-exist.cfg" report 2>&1) \
    || fail "apply must return 0 when the config is absent"
  [ -z "$out" ] || fail "absent config must be silent, got: $out"
  [ -z "$(local_name "$repo")" ] || fail "absent config must not set an identity"
  pass "T3 apply is a silent no-op when config/git-author is absent"
}

# --- T4: apply is idempotent when the identity already matches ---------------
test_apply_idempotent() {
  local repo cfg before
  repo=$(make_repo "$TMP_ROOT/idem")
  cfg="$TMP_ROOT/idem.cfg"
  write_author_config "$cfg"
  fm_git_author_apply "$repo" "$cfg"
  before=$(git -C "$repo" config --local --get-all user.name | wc -l | tr -d ' ')

  fm_git_author_apply "$repo" "$cfg" report 2>/dev/null || fail "second apply returned non-zero"

  [ "$(local_name "$repo")" = "$CAP_NAME" ] || fail "identity changed on the idempotent re-apply"
  # No duplicate user.name entries appended: the value count is unchanged.
  [ "$(git -C "$repo" config --local --get-all user.name | wc -l | tr -d ' ')" = "$before" ] \
    || fail "re-apply appended a duplicate user.name entry"
  pass "T4 apply is idempotent when the repo already matches the config"
}

# --- T5: apply never clobbers an explicitly-different local identity ----------
test_apply_preserves_conflict() {
  local repo cfg out
  repo=$(make_repo "$TMP_ROOT/conflict")
  cfg="$TMP_ROOT/conflict.cfg"
  write_author_config "$cfg"
  git -C "$repo" config --local user.name 'Someone Else'
  git -C "$repo" config --local user.email 'someone@example.invalid'

  # With the report flag, the conflict is surfaced to stderr and left untouched.
  out=$(fm_git_author_apply "$repo" "$cfg" report 2>&1) || fail "apply returned non-zero on conflict"
  assert_contains "$out" "different repo-local git identity" "conflict was not reported"
  [ "$(local_name "$repo")" = 'Someone Else' ] || fail "conflicting user.name was clobbered"
  [ "$(local_email "$repo")" = 'someone@example.invalid' ] || fail "conflicting user.email was clobbered"

  # Without the report flag, the same conflict is left untouched but silent.
  out=$(fm_git_author_apply "$repo" "$cfg" 2>&1) || fail "silent apply returned non-zero"
  [ -z "$out" ] || fail "conflict must be silent without the report flag, got: $out"
  [ "$(local_name "$repo")" = 'Someone Else' ] || fail "silent path clobbered the identity"
  pass "T5 apply leaves an explicitly-different identity untouched (reports only when asked)"
}

# --- T5b: a partial identity self-heals per field ------------------------------
test_apply_per_field_self_heal() {
  local repo cfg out
  cfg="$TMP_ROOT/partial.cfg"
  write_author_config "$cfg"

  # Matching partial state (one field already ours, the other unset, e.g. an
  # earlier apply interrupted between its two writes): completes silently.
  repo=$(make_repo "$TMP_ROOT/partial-match")
  git -C "$repo" config --local user.name "$CAP_NAME"
  out=$(fm_git_author_apply "$repo" "$cfg" report 2>&1) \
    || fail "apply returned non-zero on a matching partial state"
  [ -z "$out" ] || fail "matching partial state must complete silently, got: $out"
  [ "$(local_email "$repo")" = "$CAP_EMAIL" ] || fail "unset user.email was not completed"
  [ "$(local_name "$repo")" = "$CAP_NAME" ] || fail "matching user.name changed"

  # Differing partial state: the unset field is completed, the different field
  # is preserved and reported.
  repo=$(make_repo "$TMP_ROOT/partial-diff")
  git -C "$repo" config --local user.name 'Someone Else'
  out=$(fm_git_author_apply "$repo" "$cfg" report 2>&1) \
    || fail "apply returned non-zero on a differing partial state"
  assert_contains "$out" "different repo-local git identity" "the differing field was not reported"
  [ "$(local_name "$repo")" = 'Someone Else' ] || fail "differing user.name was clobbered"
  [ "$(local_email "$repo")" = "$CAP_EMAIL" ] || fail "unset user.email was not completed alongside the preserved name"
  pass "T5b apply self-heals a partial identity per field, preserving a differing field"
}

# --- T6: a malformed config warns once and sets nothing ----------------------
test_malformed_warns_once() {
  local repo cfg errfile warns
  repo=$(make_repo "$TMP_ROOT/malformed")
  cfg="$TMP_ROOT/malformed.cfg"
  # Present but unparseable: a name with no usable email.
  printf 'name=%s\nemail=not-an-email\n' "$CAP_NAME" > "$cfg"

  # Two calls in one subshell (so the warn-once guard is shared): exactly one line.
  errfile="$TMP_ROOT/malformed.err"
  ( fm_git_author_values "$cfg"; fm_git_author_values "$cfg" ) >/dev/null 2>"$errfile"
  warns=$(grep -c 'unparseable' "$errfile" || true)
  [ "$warns" = 1 ] || fail "expected exactly one malformed warning, got $warns"

  fm_git_author_apply "$repo" "$cfg" 2>/dev/null
  [ -z "$(local_name "$repo")" ] || fail "malformed config must not set an identity"
  pass "T6 a malformed config warns once and sets no identity"
}

# --- T7: fm-spawn sets the isolated worktree's identity ----------------------
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

test_spawn_sets_worktree_identity() {
  local home proj wt cfg fakebin out
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/spawn-wt"
  [ -z "$(local_name "$wt")" ] || fail "precondition: fresh worktree should have no local identity"
  cfg="$home/config/git-author"
  write_author_config "$cfg"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")

  mkdir -p "$home/data/set-id-a1"
  printf 'brief\n' > "$home/data/set-id-a1/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" set-id-a1 "$proj" codex --why captain 2>&1) \
    || fail "spawn failed: $out"

  assert_contains "$out" "spawned set-id-a1" "spawn did not report success"
  [ "$(local_name "$wt")" = "$CAP_NAME" ] || fail "spawn did not set the worktree user.name"
  [ "$(local_email "$wt")" = "$CAP_EMAIL" ] || fail "spawn did not set the worktree user.email"
  pass "T7 fm-spawn sets the isolated worktree's repo-local identity from config/git-author"
}

# --- T7b: fm-spawn reports a conflicting pool identity, never silently ---------
test_spawn_reports_conflict() {
  local home proj wt cfg fakebin out
  home="$TMP_ROOT/spawn-conf-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-conf-proj")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-conf-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/spawn-conf-wt"
  # The pool's shared config already carries a different identity (e.g. set from
  # an earlier config/git-author before the captain edited it).
  git -C "$wt" config --local user.name 'Pool Author'
  git -C "$wt" config --local user.email 'pool@example.invalid'
  cfg="$home/config/git-author"
  write_author_config "$cfg"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-conf-fake")

  mkdir -p "$home/data/set-id-b2"
  printf 'brief\n' > "$home/data/set-id-b2/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" set-id-b2 "$proj" codex --why captain 2>&1) \
    || fail "spawn failed: $out"

  assert_contains "$out" "spawned set-id-b2" "spawn did not report success"
  assert_contains "$out" "different repo-local git identity" \
    "spawn did not report the conflicting pool identity"
  [ "$(local_name "$wt")" = 'Pool Author' ] || fail "spawn clobbered the pool's user.name"
  [ "$(local_email "$wt")" = 'pool@example.invalid' ] || fail "spawn clobbered the pool's user.email"
  pass "T7b fm-spawn reports a conflicting pool identity instead of skipping silently"
}

# --- bootstrap integration: a fake toolchain so bootstrap runs clean ----------
make_boot_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local home=$1 primary=$2 fakebin=$3
  # TMUX unset so the liveness daemon start is skipped; no projects/ so fleet sync
  # is a no-op. stdout on fd 1, stderr on fd 2 - caller redirects as needed.
  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$primary" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-bootstrap.sh"
}

# --- T8: bootstrap sets the primary's identity when it is unset --------------
test_bootstrap_sets_primary() {
  local home primary fakebin
  home="$TMP_ROOT/boot-set-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  write_author_config "$home/config/git-author"
  primary=$(make_repo "$TMP_ROOT/boot-set-primary")
  [ -z "$(local_name "$primary")" ] || fail "precondition: primary should have no local identity"
  fakebin=$(make_boot_fakebin "$TMP_ROOT/boot-set-fake")

  run_bootstrap "$home" "$primary" "$fakebin" >/dev/null 2>&1 || fail "bootstrap exited non-zero"

  [ "$(local_name "$primary")" = "$CAP_NAME" ] || fail "bootstrap did not set the primary user.name"
  [ "$(local_email "$primary")" = "$CAP_EMAIL" ] || fail "bootstrap did not set the primary user.email"
  pass "T8 bootstrap sets the firstmate primary's repo-local identity when unset"
}

# --- T9: bootstrap skips-with-a-report on a conflicting primary identity ------
test_bootstrap_skips_on_conflict() {
  local home primary fakebin err
  home="$TMP_ROOT/boot-skip-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  write_author_config "$home/config/git-author"
  primary=$(make_repo "$TMP_ROOT/boot-skip-primary")
  git -C "$primary" config --local user.name 'Existing Author'
  git -C "$primary" config --local user.email 'existing@example.invalid'
  fakebin=$(make_boot_fakebin "$TMP_ROOT/boot-skip-fake")
  err="$TMP_ROOT/boot-skip.err"

  run_bootstrap "$home" "$primary" "$fakebin" >/dev/null 2>"$err" || fail "bootstrap exited non-zero"

  assert_contains "$(cat "$err")" "different repo-local git identity" \
    "bootstrap did not report the skipped conflict"
  [ "$(local_name "$primary")" = 'Existing Author' ] || fail "bootstrap clobbered the conflicting user.name"
  [ "$(local_email "$primary")" = 'existing@example.invalid' ] || fail "bootstrap clobbered the conflicting user.email"
  pass "T9 bootstrap skips-with-a-report on a conflicting primary identity"
}

test_values_parse
test_apply_sets_fresh
test_apply_absent_noop
test_apply_idempotent
test_apply_preserves_conflict
test_apply_per_field_self_heal
test_malformed_warns_once
test_spawn_sets_worktree_identity
test_spawn_reports_conflict
test_bootstrap_sets_primary
test_bootstrap_skips_on_conflict

echo "# all fm-git-author tests passed"
