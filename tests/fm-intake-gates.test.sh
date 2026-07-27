#!/usr/bin/env bash
# Behavior tests for the two enforced intake gates in fm-spawn.sh (--why, closed
# topics), plus the two brief-carried conventions that ride with them (freshness
# provenance, access routing) and bootstrap's CLOSED_TOPICS report.
#
# All four exist because the rules they encode were written down, loaded, and
# broken anyway. So these tests are written to exercise the REFUSAL, never merely
# to observe that a gate did not fire: a gate that has only been seen staying
# quiet has proved nothing at all. Every gate here is asserted on its non-zero
# exit, its exact refusal text, and the absence of the side effects a spawn would
# otherwise have had (no meta file, no tmux window).
#
# The matching tests carry POSITIVE CONTROLS: every "this must NOT match" case is
# paired with a case using the same register that MUST match, so a matcher that
# structurally cannot match anything - which would return a clean, identical
# result for every negative - is caught rather than mistaken for correctness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_SH="$ROOT/bin/fm-brief.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-intake-gates)
fm_git_identity

# --- harness ----------------------------------------------------------------

# A fake tmux that answers fm-spawn's queries, records the literal launch payload,
# and records every new-window call so a test can assert no window was created.
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
  new-window) [ -n "${FM_NEWWINDOW_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_NEWWINDOW_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# One fake tmux/treehouse shadows the real ones for EVERY spawn this suite runs.
# It is suite-wide rather than per-test on purpose: a test that expects a refusal
# but hits a bug and falls through would otherwise create a real window in the
# developer's own session. The shim must be unreachable-by-accident, not
# remembered-per-call.
GLOBAL_FAKEBIN=$(make_fake_tmux "$TMP_ROOT/global-fake")

# run_spawn <home> <args...>: drive fm-spawn with every firstmate override scoped
# to <home>, so the test never reads or writes the developer's live fleet state.
run_spawn() {
  local home=$1
  shift
  PATH="$GLOBAL_FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" "$@" 2>&1
}

# new_home <name>: a bare firstmate home with data/ and a projects/alpha clone
# (fm-spawn resolves the project directory before it reaches either gate, so the
# directory must exist for a gate test to be testing the gate and not the path).
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/projects/alpha"
  printf '%s\n' "$home"
}

# spawnable_home <name>: a home whose projects/alpha is a real git repo with a
# real isolated linked worktree, so a spawn that clears both gates satisfies
# fm-spawn's isolation guard and runs to completion. Echoes "<home> <worktree>".
spawnable_home() {
  local name=$1 home proj wt
  home=$(new_home "$name")
  proj="$home/projects/alpha"
  fm_git_init_commit "$proj"
  wt="$TMP_ROOT/$name-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  printf '%s %s\n' "$home" "$wt"
}

# run_spawnable <home> <wt> <args...>: run_spawn with the fake tmux told which
# worktree the pane landed in, so a spawn that clears the gates exits 0.
run_spawnable() {
  local home=$1 wt=$2
  shift 2
  TMUX="fake,1,0" FM_FAKE_SES=firstmate FM_FAKE_PANE_PATH="$wt" \
    run_spawn "$home" "$@"
}

# write_brief <home> <id> <text>
write_brief() {
  local home=$1 id=$2 text=$3
  mkdir -p "$home/data/$id"
  # %b so a row can embed \n and exercise a claim wrapped across a line break.
  printf '%b\n' "$text" > "$home/data/$id/brief.md"
}

# --- gate 1: --why ----------------------------------------------------------

# The refusal itself. Table-driven over the ways a caller can fail to declare why
# the work exists, and the ways it can succeed. Each row runs against a home with
# NO brief, so a spawn that clears the gate stops at the missing-brief error
# without creating a window: "error: no brief at" is the marker for "gate passed".
#   <label>|<verdict pass/refuse>|<args...>
test_why_gate() {
  local label verdict args out status home
  home=$(new_home why-gate)
  while IFS='|' read -r label verdict args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn "$home" $args)
    status=$?
    case "$verdict" in
      refuse)
        expect_code 2 "$status" "$label"
        assert_contains "$out" "refusing to spawn - work must declare why it exists" "$label: no refusal banner"
        assert_not_contains "$out" "error: no brief at" "$label: spawn continued past the why gate"
        ;;
      pass)
        [ "$status" -ne 0 ] || fail "$label: expected the missing-brief failure"
        assert_contains "$out" "error: no brief at" "$label: did not clear the why gate"
        assert_not_contains "$out" "must declare why it exists" "$label: valid --why was refused"
        ;;
    esac
  done <<'ROWS'
no --why at all|refuse|no-why-a1 projects/alpha
--why with no value|refuse|no-why-a2 projects/alpha --why
"interesting" is not a tag|refuse|no-why-a3 projects/alpha --why interesting
"tidy-up" is not a tag|refuse|no-why-a4 projects/alpha --why tidy-up
"found while looking at X" is not a tag|refuse|no-why-a5 projects/alpha --why found-while-looking
blocks without naming what it blocks|refuse|no-why-a6 projects/alpha --why blocks
empty --why value|refuse|no-why-a7 projects/alpha --why=
scout also requires --why|refuse|no-why-a8 projects/alpha --scout
captain tag alone|pass|ok-why-b1 projects/alpha --why captain
captain tag with a note|pass|ok-why-b2 projects/alpha --why captain:asked-in-chat
incident tag|pass|ok-why-b3 projects/alpha --why incident:signups-down
blocks tag naming what it blocks|pass|ok-why-b4 projects/alpha --why blocks:the-login-fix
--why= equals form|pass|ok-why-b5 projects/alpha --why=captain
scout with --why|pass|ok-why-b6 projects/alpha --scout --why captain
ROWS
  pass "gate 1: ship and scout spawns refuse without a valid --why, and proceed with one"
}

# The refusal must TEACH, not just fail: firstmate reads this text and must come
# away knowing the three tags and knowing that "interesting" is not among them.
test_why_refusal_text() {
  local home out
  home=$(new_home why-text)
  out=$(run_spawn "$home" why-text-c1 projects/alpha)
  assert_contains "$out" "--why captain" "refusal omits the captain tag"
  assert_contains "$out" "--why blocks:<what>" "refusal omits the blocks tag"
  assert_contains "$out" "--why incident" "refusal omits the incident tag"
  assert_contains "$out" "the captain asked for this" "refusal omits the captain tag explanation"
  assert_contains "$out" "blocks something the captain asked for" "refusal omits the blocks explanation"
  assert_contains "$out" "live production incident" "refusal omits the incident explanation"
  assert_contains "$out" '"Interesting", "worth doing",' "refusal does not rule out the non-reasons"
  assert_contains "$out" "found while looking at X" "refusal does not rule out incidental discovery"
  assert_contains "$out" "tidy-up" "refusal does not rule out tidy-up"
  # The refusal is a diagnostic: it belongs on stderr, so a caller capturing
  # stdout never mistakes it for output.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" why-text-c2 projects/alpha 2>/dev/null)
  [ -z "$out" ] || fail "why refusal leaked to stdout: $out"
  pass "gate 1: the refusal names all three tags and rules out the non-reasons, on stderr"
}

# --secondmate is exempt: launching a persistent supervisor is lifecycle, not
# work, so it must never hit the why gate. Asserted by the ABSENCE of the why
# refusal alongside the presence of the later, unrelated failure it should reach.
test_why_gate_exempts_secondmate() {
  local home out status
  home=$(new_home why-secondmate)
  out=$(run_spawn "$home" some-secondmate-d1 --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate spawn with no home should still fail"
  assert_not_contains "$out" "must declare why it exists" "--secondmate was wrongly gated on --why"
  assert_contains "$out" "no firstmate home supplied or registered" "secondmate spawn failed for the wrong reason"
  pass "gate 1: --secondmate is exempt from --why"
}

# The batch form takes ONE shared --why, validated once before the split so a bad
# batch fails whole rather than per pair, and forwarded to every pair.
test_why_gate_batch() {
  local home out status
  home=$(new_home why-batch)
  out=$(run_spawn "$home" batch-e1=projects/alpha batch-e2=projects/beta)
  status=$?
  expect_code 2 "$status" "batch without --why"
  assert_contains "$out" "must declare why it exists" "batch without --why was not refused"
  assert_not_contains "$out" "batch:" "batch without --why still entered batch dispatch"

  out=$(run_spawn "$home" batch-e1=projects/alpha batch-e2=projects/beta --why captain:asked)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  assert_contains "$out" "batch: FAILED to spawn batch-e1" "batch with --why did not dispatch the first pair"
  assert_contains "$out" "batch: FAILED to spawn batch-e2" "batch with --why did not dispatch the second pair"
  assert_not_contains "$out" "must declare why it exists" "forwarded --why was not accepted by the re-exec"
  pass "gate 1: batch takes one shared --why, validated once and forwarded to every pair"
}

# --- gate 2: closed topics --------------------------------------------------

# fixture_home <name> <register-content>: a home carrying a closed-topic register.
fixture_home() {
  local home
  home=$(new_home "$1")
  printf '%s\n' "$2" > "$home/data/closed.md"
  printf '%s\n' "$home"
}

REGISTER='# closed topics (comment lines like this one are ignored)

- subscription-cancellation: subscription cancellation, post-deletion billing: handled by the captain out of band (closed 2026-07-27)
- deleted-user-backlog: deleted user backlog: the captain closed this; the backlog is not work (closed 2026-07-25)
this prose line is not an entry and must never gate anything
- malformed-entry-with-no-second-colon'

# The gate fires, and it fires at the SPAWN CALL - before any window exists and
# before any meta is written - because by the time a report exists the captain's
# attention has already been spent. Table-driven over what carries the match.
#   <label>|<id>|<brief text>
test_closed_gate_refuses() {
  local label id brief home out status log
  home=$(fixture_home closed-refuse "$REGISTER")
  log="$TMP_ROOT/closed-refuse-newwindow.log"
  : > "$log"
  while IFS='|' read -r label id brief; do
    [ -n "$label" ] || continue
    write_brief "$home" "$id" "$brief"
    out=$(FM_NEWWINDOW_LOG="$log" run_spawn "$home" "$id" projects/alpha --why captain)
    status=$?
    expect_code 3 "$status" "$label"
    assert_contains "$out" "this topic is CLOSED" "$label: no closure refusal"
    assert_absent "$home/state/$id.meta" "$label: a refused spawn still wrote meta"
  done <<'ROWS'
brief text carries the closed phrase|closed-f1|Investigate the subscription cancellation flow end to end.
task id carries the closed phrase|deleted-user-backlog-f2|Work through the queue.
case and hyphenation do not matter|closed-f3|Look at POST_DELETION Billing again.
phrase split across a line break still matches|closed-f4|Check the deleted user\nbacklog once more.
ROWS
  [ ! -s "$log" ] || fail "a refused spawn created a tmux window: $(cat "$log")"
  pass "gate 2: a closed topic refuses at the spawn call, writing no meta and creating no window"
}

# The refusal must print the closure line VERBATIM, so the operator sees why the
# topic is closed rather than only that it is.
test_closed_refusal_shows_the_line() {
  local home out
  home=$(fixture_home closed-verbatim "$REGISTER")
  write_brief "$home" closed-g1 'Please re-check the subscription cancellation billing path.'
  out=$(run_spawn "$home" closed-g1 projects/alpha --why captain)
  assert_contains "$out" \
    "- subscription-cancellation: subscription cancellation, post-deletion billing: handled by the captain out of band (closed 2026-07-27)" \
    "closure line was not printed verbatim"
  assert_contains "$out" "--reopen-closed" "refusal does not name the authorised override"
  pass "gate 2: the refusal prints the matching closure line verbatim"
}

# True negatives, each paired with a POSITIVE CONTROL on the SAME register: a
# matcher that structurally cannot match would pass every negative below while
# proving nothing, so each negative is only meaningful next to a match that fires.
#   <label>|<verdict match/nomatch>|<brief text>
test_closed_matching_precision() {
  local label verdict brief home wt out status id n=0
  read -r home wt fakebin <<EOF
$(spawnable_home closed-precision)
EOF
  printf '%s\n' \
'- billing-topic: billing: closed by the captain (closed 2026-07-27)
- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"
  while IFS='|' read -r label verdict brief; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="precision-h$n"
    write_brief "$home" "$id" "$brief"
    out=$(run_spawnable "$home" "$wt" "$id" projects/alpha codex --why captain)
    status=$?
    case "$verdict" in
      match)
        expect_code 3 "$status" "$label"
        assert_contains "$out" "this topic is CLOSED" "$label: expected a closure refusal"
        assert_absent "$home/state/$id.meta" "$label: a refused spawn still wrote meta"
        ;;
      nomatch)
        # Unrelated work must not merely avoid the refusal: it must SPAWN.
        expect_code 0 "$status" "$label: unrelated work was blocked (got: $out)"
        assert_present "$home/state/$id.meta" "$label: unrelated work did not spawn"
        ;;
    esac
  done <<'ROWS'
positive control: the register can and does match|match|The billing screen needs a look.
whole-token only: "billings" is not "billing"|nomatch|The billings export needs a look.
whole-token only: "rebilling" is not "billing"|nomatch|The rebilling job needs a look.
partial phrase does not match a multi-word keyword|nomatch|The deleted user record needs a look.
positive control: the full phrase does match|match|The deleted user backlog needs a look.
unrelated work is untouched|nomatch|Add a settings screen for notification preferences.
ROWS
  pass "gate 2: matching is punctuation/case blind and token-exact (with positive controls)"
}

# Comment lines, blank lines, prose, and malformed entries in the register must
# never gate anything - a hand-written note in the file is not a closure.
test_closed_ignores_non_entries() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home closed-noise)
EOF
  printf '%s\n' "$REGISTER" > "$home/data/closed.md"
  write_brief "$home" closed-i1 'this prose line is not an entry and must never gate anything, malformed-entry-with-no-second-colon, closed topics comment lines like this one are ignored'
  out=$(run_spawnable "$home" "$wt" closed-i1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a comment/prose/malformed register line was treated as a closure (got: $out)"
  pass "gate 2: comments, prose, and malformed lines in the register never gate work"
}

# An absent register is inert: no closure, no error, no behavior change.
test_closed_absent_register() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home closed-absent)
EOF
  write_brief "$home" closed-j1 'Investigate the subscription cancellation flow.'
  out=$(run_spawnable "$home" "$wt" closed-j1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "spawn refused with no register present (got: $out)"
  pass "gate 2: an absent data/closed.md is inert"
}

# --- full spawn: meta provenance and the authorised reopen ------------------

# End to end over a fake tmux and a real isolated worktree: a clean spawn records
# why=, and --reopen-closed proceeds on a CLOSED topic while recording the
# override and shouting about it. The reopen path is the one bypass this design
# admits, so it must be loud and it must leave a trace.
test_meta_records_provenance() {
  local home proj wt fakebin out status
  home=$(new_home meta-provenance)
  proj="$TMP_ROOT/meta-proj"
  fm_git_init_commit "$proj"
  wt="$TMP_ROOT/meta-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_fake_tmux "$TMP_ROOT/meta-fake")
  printf '%s\n' "$REGISTER" > "$home/data/closed.md"

  # A clean, unrelated task: spawns, and its meta carries the declared reason.
  write_brief "$home" clean-k1 'Add a settings screen for notification preferences.'
  out=$(PATH="$fakebin:$PATH" TMUX="fake,1,0" FM_FAKE_SES=firstmate FM_FAKE_PANE_PATH="$wt" \
    run_spawn "$home" clean-k1 "$proj" codex --why 'blocks:the login fix')
  status=$?
  expect_code 0 "$status" "clean spawn should succeed (got: $out)"
  assert_grep "why=blocks: the login fix" "$home/state/clean-k1.meta" "meta did not record the why tag and note"
  assert_no_grep "reopened_closed=" "$home/state/clean-k1.meta" "meta recorded a reopen that never happened"

  # An explicitly authorised reopen of a closed topic: proceeds, warns loudly,
  # and records which closure was overridden.
  write_brief "$home" reopen-k2 'Re-open the subscription cancellation question at the captain request.'
  out=$(PATH="$fakebin:$PATH" TMUX="fake,1,0" FM_FAKE_SES=firstmate FM_FAKE_PANE_PATH="$wt" \
    run_spawn "$home" reopen-k2 "$proj" codex --why captain --reopen-closed)
  status=$?
  expect_code 0 "$status" "authorised reopen should spawn (got: $out)"
  assert_contains "$out" "WARNING: --reopen-closed is REOPENING a topic the captain closed" \
    "reopen was silent instead of loud"
  assert_contains "$out" "subscription-cancellation" "reopen warning did not name the closure"
  assert_grep "reopened_closed=subscription-cancellation" "$home/state/reopen-k2.meta" \
    "meta did not record the overridden closure"

  # A secondmate spawn records neither key: it is lifecycle, not work.
  local subhome="$TMP_ROOT/meta-subhome"
  mkdir -p "$subhome/bin" "$subhome/data"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'domain-k3\n' > "$subhome/.fm-secondmate-home"
  write_brief "$home" domain-k3 'charter'
  out=$(PATH="$fakebin:$PATH" TMUX="fake,1,0" FM_FAKE_SES=firstmate \
    run_spawn "$home" domain-k3 "$subhome" codex --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should still succeed (got: $out)"
  assert_no_grep "why=" "$home/state/domain-k3.meta" "secondmate meta recorded a why tag"
  assert_grep "kind=secondmate" "$home/state/domain-k3.meta" "secondmate meta is not a secondmate"
  pass "spawn records why= (and reopened_closed= only on an authorised reopen); secondmate unaffected"
}

# --- gate 3: freshness provenance in briefs ---------------------------------

# The weakest of the three gates by construction - no script can tell a fresh
# claim about live state from a stale one - so what is asserted here is only that
# the instruction reaches every ship and scout crewmate at spawn, verbatim.
test_brief_freshness_section() {
  local home out brief
  home=$(new_home brief-freshness)
  mkdir -p "$home/projects/alpha"
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "fresh-$kind" alpha --scout 2>&1)
    else
      out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "fresh-$kind" alpha 2>&1)
    fi
    [ -n "$out" ] || fail "$kind brief scaffold produced no output"
    brief="$home/data/fresh-$kind/brief.md"
    assert_grep "# Freshness provenance (required)" "$brief" "$kind brief has no freshness section"
    assert_grep '[fetched <source> <ISO-8601 timestamp>]' "$brief" "$kind brief does not state the tag format"
    assert_grep "Specificity is not freshness" "$brief" "$kind brief omits the specificity trap"
    assert_grep "UNVERIFIED" "$brief" "$kind brief does not require the unverified treatment"
  done
  pass "gate 3: ship and scout briefs carry the freshness-provenance contract"
}

# --- gate 4: access routing -------------------------------------------------

# Like gate 3 this is a convention carried in the brief, so what is asserted is
# that it reaches every ship and scout crewmate: the probe-then-escalate order,
# the access-wall rule that makes a wall a BLOCKER rather than a caveat, and the
# local fleet map when one exists.
#
# The structural section must NOT claim crews cannot reach MCP. Measured from a
# claude crewmate pane on 2026-07-27, Sentry and RevenueCat MCP both answered, so
# a blanket "route everything through firstmate" would be a confident, specific,
# wrong instruction - the very failure the freshness section warns about - and it
# would push crews to escalate work they can simply do. That absence is asserted
# alongside a positive control proving the assertion can fire at all.
test_brief_access_section() {
  local home brief kind
  home=$(new_home brief-access)
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "access-$kind" alpha --scout >/dev/null 2>&1
    else
      FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "access-$kind" alpha >/dev/null 2>&1
    fi
    brief="$home/data/access-$kind/brief.md"
    assert_grep "# Access and routing" "$brief" "$kind brief has no access section"
    assert_grep "PROBE once" "$brief" "$kind brief omits the probe-first step"
    assert_grep "Access walls are BLOCKERS, not caveats" "$brief" "$kind brief omits the access-wall rule"
    assert_grep 'blocked: no access to' "$brief" "$kind brief does not give the blocker status line"
    assert_grep "could not establish" "$brief" "$kind brief does not rule out the silent downgrade"
    # Positive control for the absence assertion below: prove this grep style CAN
    # find a phrase that is genuinely present in this very file.
    assert_grep "firstmate-only" "$brief" "positive control failed: the access section is not being read at all"
    assert_no_grep "crews have no MCP" "$brief" "$kind brief asserts a blanket MCP claim that is not true"
  done
  pass "gate 4: ship and scout briefs carry probe-then-escalate routing and the access-wall rule"
}

# The fleet inventory is local and captain-specific, so it is injected from
# data/access.md at generation time rather than baked into this tracked script -
# and its absence must not remove the structural section, which is the half that
# always applies.
test_brief_access_map_injection() {
  local home brief
  home=$(new_home brief-access-map)
  printf -- '- Sentry: MCP-backed. reach: probe first.\n- App Store Connect: reach: firstmate-only.\n' \
    > "$home/data/access.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" access-map-m1 alpha >/dev/null 2>&1
  brief="$home/data/access-map-m1/brief.md"
  assert_grep "## Fleet access map" "$brief" "brief did not carry the fleet access map heading"
  assert_grep "App Store Connect: reach: firstmate-only." "$brief" "brief did not inject the local access map"

  # Absent map: structural section survives, map heading does not.
  local bare
  bare=$(new_home brief-access-bare)
  FM_ROOT_OVERRIDE='' FM_HOME="$bare" FM_DATA_OVERRIDE="$bare/data" \
    FM_STATE_OVERRIDE="$bare/state" "$BRIEF_SH" access-bare-m2 alpha >/dev/null 2>&1
  brief="$bare/data/access-bare-m2/brief.md"
  assert_grep "# Access and routing" "$brief" "structural access section vanished with no access.md"
  assert_no_grep "## Fleet access map" "$brief" "empty fleet map heading was emitted with no access.md"
  pass "gate 4: data/access.md is injected as the fleet map, and its absence keeps the routing rule"
}

# --- bootstrap reporting ----------------------------------------------------

# Bootstrap's contract is that silence means all good, so the closed-topic report
# must appear only when there is something to report.
#   <label>|<mode present/absent/empty/noise>|<expect substring or ->
test_bootstrap_closed_report() {
  local label mode expect home fakebin out n=0
  while IFS='|' read -r label mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    home="$TMP_ROOT/bootstrap-closed-$n"
    mkdir -p "$home/data"
    fakebin=$(fm_fakebin "$TMP_ROOT/bootstrap-closed-$n")
    fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi curl jq
    cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && printf '%s\n' 'Usage: treehouse get [--lease]'
exit 0
SH
    chmod +x "$fakebin/treehouse"
    cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
exit 0
SH
    chmod +x "$fakebin/no-mistakes"
    case "$mode" in
      present) printf '%s\n' "$REGISTER" > "$home/data/closed.md" ;;
      empty) : > "$home/data/closed.md" ;;
      noise) printf '# just a note\n\nnot an entry\n' > "$home/data/closed.md" ;;
      absent) : ;;
    esac
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" TMUX='' "$BOOTSTRAP")
    if [ "$expect" = "-" ]; then
      assert_not_contains "$out" "CLOSED_TOPICS" "$label: bootstrap was not silent"
    else
      assert_contains "$out" "$expect" "$label: wrong or missing CLOSED_TOPICS line"
    fi
  done <<'ROWS'
register with entries is reported|present|CLOSED_TOPICS: 2 closed at intake: subscription-cancellation, deleted-user-backlog
absent register stays silent|absent|-
empty register stays silent|empty|-
comment-only register stays silent|noise|-
ROWS
  pass "bootstrap reports closed topics only when the register holds entries"
}

test_why_gate
test_why_refusal_text
test_why_gate_exempts_secondmate
test_why_gate_batch
test_closed_gate_refuses
test_closed_refusal_shows_the_line
test_closed_matching_precision
test_closed_ignores_non_entries
test_closed_absent_register
test_meta_records_provenance
test_brief_freshness_section
test_brief_access_section
test_brief_access_map_injection
test_bootstrap_closed_report
