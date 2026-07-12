#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)' and
# 'TASKS_AXI: available' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, and which
# no-mistakes version is on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label lease tasks mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^-^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is reported available^1^0.1.1^exact^TASKS_AXI: available^
incompatible tasks-axi is ignored^1^0.1.0^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi compatibility contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

# Bootstrap ensures the always-on liveness daemon: skipped outside tmux (the
# daemon's supervisor-pane target cannot resolve there), started detached and
# silently when inside tmux with no live pidfile, and left alone when the
# pidfile names a live process. FM_ROOT_OVERRIDE points bootstrap's FM_ROOT at
# the case home, so the fake daemon dropped in <home>/bin is what it launches.
test_bootstrap_ensures_liveness_daemon() {
  local case_dir home fakebin out pid i
  case_dir="$TMP_ROOT/daemon-ensure"
  home="$case_dir/home"
  fm_git_init_commit "$home"
  mkdir -p "$home/bin" "$home/state"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$home/bin/fm-supervise-daemon.sh" <<SH
#!/usr/bin/env bash
echo started >> "$case_dir/daemon-started"
echo \$\$ > "$home/state/.supervise-daemon.pid"
exec sleep 60
SH
  chmod +x "$home/bin/fm-supervise-daemon.sh"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 TMUX='' "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "daemon ensure: expected silence outside tmux, got: $out"
  [ -e "$case_dir/daemon-started" ] && fail "daemon ensure: started the daemon outside tmux"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 TMUX=/tmp/fake,0,0 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "daemon ensure: expected a silent start inside tmux, got: $out"
  i=0
  while [ "$i" -lt 50 ]; do
    pid=$(cat "$home/state/.supervise-daemon.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && break
    sleep 0.1; i=$((i + 1))
  done
  [ -s "$case_dir/daemon-started" ] || fail "daemon ensure: did not start the daemon inside tmux"
  kill -0 "$pid" 2>/dev/null || fail "daemon ensure: started daemon is not alive behind its pidfile"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 TMUX=/tmp/fake,0,0 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "daemon ensure: expected silence with a live daemon, got: $out"
  sleep 0.3
  i=$(grep -c started "$case_dir/daemon-started" 2>/dev/null || echo 0)
  kill "$pid" 2>/dev/null || true
  [ "$i" = 1 ] || fail "daemon ensure: launched $i daemons (expected 1; a live pidfile must be left alone)"
  pass "bootstrap ensures the liveness daemon: tmux-gated, silent, idempotent on a live pidfile"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_bootstrap_ensures_liveness_daemon
