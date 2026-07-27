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

# --reopen-closed is the ONE designed bypass of gate 2, and it is authorisation for
# ONE topic. Forwarding it to every pair would silently widen a single captain
# authorisation into a blanket bypass, so batch dispatch refuses it outright and the
# whole batch stops before any pair spawns.
test_reopen_closed_refused_in_batch() {
  local home out status
  home=$(new_home reopen-batch)
  out=$(run_spawn "$home" rb-n1=projects/alpha rb-n2=projects/alpha --why captain --reopen-closed)
  status=$?
  expect_code 2 "$status" "batch --reopen-closed"
  assert_contains "$out" "--reopen-closed is not accepted in batch dispatch" \
    "batch --reopen-closed was not refused"
  assert_contains "$out" "per-task authorisation" "refusal does not explain why the bypass stays narrow"
  assert_not_contains "$out" "batch:" "batch --reopen-closed still dispatched pairs"
  assert_absent "$home/state/rb-n1.meta" "a refused batch still wrote meta"

  # Positive control: the same batch without the flag DOES dispatch both pairs, so
  # the refusal above is the flag being rejected rather than batch mode being broken.
  out=$(run_spawn "$home" rb-n1=projects/alpha rb-n2=projects/alpha --why captain)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  assert_contains "$out" "batch: FAILED to spawn rb-n1" "control batch did not dispatch the first pair"
  assert_contains "$out" "batch: FAILED to spawn rb-n2" "control batch did not dispatch the second pair"
  pass "gate 2: batch dispatch refuses --reopen-closed instead of widening it to every pair"
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

# The haystack is the task id plus the brief MINUS the boilerplate fm-brief.sh
# injects into every ship and scout brief. A closure keyword landing in
# the conventions, freshness, access-routing or fleet-map blocks would otherwise
# match EVERY generated brief and refuse EVERY dispatch in the fleet - a control
# that fails closed on everything is worse than the problem it solves.
#
# Asserted end to end on a REAL generated brief, because the bug lives in the
# interaction between the scaffold's injection and the matcher, and cannot be seen
# with the hand-written briefs the other cases use. Paired with a positive control
# on the SAME register and the SAME injected map: a matcher that had simply stopped
# working would pass the negative while proving nothing.
test_closed_ignores_injected_boilerplate() {
  local home wt out status brief
  read -r home wt <<EOF
$(spawnable_home closed-boilerplate)
EOF
  # The keyword appears ONLY in the injected fleet access map, never in any task.
  printf -- '- Sentry: MCP-backed. reach: probe first.\n' > "$home/data/access.md"
  printf -- '- sentry-topic: Sentry: handled by the captain out of band (closed 2026-07-27)\n' \
    > "$home/data/closed.md"

  for id in boilerplate-n1 boilerplate-n2; do
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "$id" alpha >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "Sentry" "$brief" "$id: the injected access map did not carry the keyword"
  done

  # Negative: an unrelated task whose own text never mentions the closure.
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/boilerplate-n1/brief.md"
  out=$(run_spawnable "$home" "$wt" boilerplate-n1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a keyword present only in injected brief boilerplate refused unrelated work (got: $out)"
  assert_present "$home/state/boilerplate-n1.meta" "unrelated work did not spawn"

  # Positive control: same register, same injected map, keyword in the TASK body.
  perl -0pi -e 's/\{TASK\}/Check the Sentry issue rate for the login flow./' \
    "$home/data/boilerplate-n2/brief.md"
  out=$(run_spawnable "$home" "$wt" boilerplate-n2 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "positive control: a keyword in the task body did not refuse"
  assert_contains "$out" "this topic is CLOSED" "positive control: no closure refusal"
  assert_absent "$home/state/boilerplate-n2.meta" "a refused spawn still wrote meta"
  pass "gate 2: injected brief boilerplate is stripped, so it cannot gate the fleet"
}

# fill_task <brief-file> <body-file>: replace the scaffold's {TASK} placeholder with
# a multi-line task body, so a test can put a "# " line INSIDE the task.
fill_task() {
  local brief=$1 bodyfile=$2
  awk -v bf="$bodyfile" '
    $0 == "{TASK}" { while ((getline l < bf) > 0) print l; close(bf); next }
    { print }
  ' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
}

# The task body is free text firstmate writes, and it routinely contains its own
# "# " lines: a fenced shell snippet whose first line is a comment, a task that
# structures itself with a heading, or - in this repo especially - a task about the
# brief scaffold that quotes a generated heading like "# Setup" verbatim. Any
# stripper that infers boilerplate boundaries from heading TEXT stops matching from
# that line on: a closure silently covering less than the captain believes, with no
# signal anywhere. So boundaries come from explicit fm:boilerplate markers instead,
# and these cases prove a keyword after any "# " line in the task still refuses.
#
# Run end to end on REAL generated briefs (the injected boilerplate has to be
# present for the stripping to mean anything), and paired with a negative control
# on the SAME register and SAME injected map: a matcher that had degenerated into
# matching everything would pass both positives while proving nothing.
test_closed_matches_task_body_after_hash_line() {
  local home wt out status brief body hashline id label verdict n=0
  read -r home wt <<EOF
$(spawnable_home closed-taskbody)
EOF
  printf -- '- Sentry: MCP-backed. reach: probe first.\n' > "$home/data/access.md"
  printf '%s\n' \
'- sentry-topic: Sentry: handled by the captain out of band (closed 2026-07-27)
- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"

  body="$TMP_ROOT/closed-taskbody-body"
  while IFS='|' read -r label verdict; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="taskbody-j$n"
    case "$n" in
      1) # fenced snippet whose first line is a shell comment
        hashline='# install deps'
        printf '%s\n' 'Reproduce the export failure.' '' '```' \
          "$hashline" 'npm ci' '```' '' \
          'Then work the deleted user backlog until it drains.' > "$body" ;;
      2) # the task body carries its own level-1 heading
        hashline='# Acceptance criteria'
        printf '%s\n' 'Reproduce the export failure.' '' "$hashline" \
          '- the deleted user backlog drains cleanly' > "$body" ;;
      3) # the task body quotes a heading the scaffold itself injects
        hashline='# Setup'
        printf '%s\n' 'Rewrite the brief scaffold section shown below.' '' \
          "$hashline" 'the new text' '' \
          'Then fix the deleted user backlog drain.' > "$body" ;;
      4) # the task body quotes the LAST injected heading of the brief
        hashline='# Definition of done'
        printf '%s\n' 'Restate the scaffold section below.' '' "$hashline" \
          'ship it, and drain the deleted user backlog first' > "$body" ;;
      5) # same shape, no closed keyword anywhere but the injected access map
        hashline='# Acceptance criteria'
        printf '%s\n' 'Reproduce the export failure.' '' "$hashline" \
          '- notification preferences round-trip' > "$body" ;;
      6) # a task quoting an injected heading, with no closed keyword at all
        hashline='# Setup'
        printf '%s\n' 'Rewrite the brief scaffold section shown below.' '' \
          "$hashline" 'the new text' '' \
          'Then check the notification preferences screen.' > "$body" ;;
    esac
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "$id" alpha >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "Sentry" "$brief" "$id: the injected access map did not carry the keyword"
    fill_task "$brief" "$body"
    assert_grep "$hashline" "$brief" "$id: the task body lost its own \"# \" line"
    out=$(run_spawnable "$home" "$wt" "$id" projects/alpha codex --why captain)
    status=$?
    case "$verdict" in
      match)
        expect_code 3 "$status" "$label"
        assert_contains "$out" "this topic is CLOSED" "$label: expected a closure refusal"
        assert_contains "$out" "- deleted-user-backlog: deleted user backlog:" \
          "$label: the closure line was not printed verbatim"
        assert_absent "$home/state/$id.meta" "$label: a refused spawn still wrote meta"
        ;;
      nomatch)
        expect_code 0 "$status" "$label: unrelated work was blocked (got: $out)"
        assert_present "$home/state/$id.meta" "$label: unrelated work did not spawn"
        ;;
    esac
  done <<'ROWS'
a keyword after a fenced "# install deps" line still refuses|match
a keyword after the task's own "# Acceptance criteria" heading still refuses|match
a keyword after a task body quoting the injected "# Setup" heading still refuses|match
a keyword after a task body quoting "# Definition of done" still refuses|match
control: the same shape with no closed keyword still spawns|nomatch
control: a task quoting "# Setup" with no closed keyword still spawns|nomatch
ROWS
  pass "gate 2: a \"# \" line inside the task body cannot silently narrow the haystack"
}

# Narrowing the haystack is the only place this gate can quietly cover less than the
# captain believes, so it is allowed only where the marked regions are unambiguous.
# Both uncertain cases must keep MORE text, never less: a brief with no markers at
# all (hand-written, or generated before markers existed) and a brief whose markers
# do not balance. The unbalanced case must additionally be LOUD, because that is the
# case where the stripper cannot be confident and confidence is the precondition for
# dropping anything.
#
# Each case is asserted by its OBSERVABLE consequence - the keyword that lives only
# in injected boilerplate now refuses, because that boilerplate was kept - so the
# test cannot pass by the stripper having merely stopped running.
test_closed_marker_fallbacks_keep_whole_brief() {
  local home wt out status brief
  read -r home wt <<EOF
$(spawnable_home closed-markers)
EOF
  printf -- '- Sentry: MCP-backed. reach: probe first.\n' > "$home/data/access.md"
  printf '%s\n' \
'- sentry-topic: Sentry: handled by the captain out of band (closed 2026-07-27)
- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"

  # Unbalanced markers: the whole brief is matched, so the keyword sitting only in
  # the injected access map now refuses, and the stripper says why out loud.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" markers-k1 alpha >/dev/null 2>&1
  brief="$home/data/markers-k1/brief.md"
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' "$brief"
  grep -q 'fm:boilerplate end' "$brief" || fail "markers-k1: the scaffold emitted no end marker"
  perl -ni -e 'print unless /fm:boilerplate end/' "$brief"
  out=$(run_spawnable "$home" "$wt" markers-k1 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "unbalanced markers silently narrowed the haystack (got: $out)"
  assert_contains "$out" "unbalanced fm:boilerplate markers" "unbalanced markers were not reported"
  assert_contains "$out" "Matching the WHOLE brief" "the warning does not say what it fell back to"
  assert_absent "$home/state/markers-k1.meta" "a refused spawn still wrote meta"

  # No markers at all: a hand-written brief is matched whole, and there is no
  # heading-text fallback, so a keyword after its own "# Setup" line still refuses.
  write_brief "$home" markers-k2 \
    'Rewrite the scaffold.\n\n# Setup\nthe new text\n\nThen fix the deleted user backlog drain.'
  assert_no_grep "fm:boilerplate" "$home/data/markers-k2/brief.md" "hand-written brief carried markers"
  out=$(run_spawnable "$home" "$wt" markers-k2 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "an unmarked brief was narrowed by heading text (got: $out)"
  assert_contains "$out" "- deleted-user-backlog: deleted user backlog:" \
    "the closure line was not printed verbatim"
  assert_not_contains "$out" "unbalanced fm:boilerplate markers" \
    "a brief with no markers was reported as unbalanced"
  assert_absent "$home/state/markers-k2.meta" "a refused spawn still wrote meta"

  # Positive control that the marked path still narrows: same register, same map, a
  # correctly marked brief whose task never mentions a closure spawns cleanly.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" markers-k3 alpha >/dev/null 2>&1
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/markers-k3/brief.md"
  out=$(run_spawnable "$home" "$wt" markers-k3 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: a correctly marked brief was refused (got: $out)"
  assert_present "$home/state/markers-k3.meta" "control: unrelated work did not spawn"
  pass "gate 2: absent or unbalanced boilerplate markers keep the whole brief, and say so"
}

# "Capable of being loud" has to be real rather than asserted, so the narrowing is
# inspectable on demand: FM_CLOSED_EXPLAIN prints the exact haystack the gate matched
# and how many marked regions it removed, on stderr, without changing the verdict.
test_closed_explain_shows_the_haystack() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home closed-explain)
EOF
  printf -- '- Sentry: MCP-backed. reach: probe first.\n' > "$home/data/access.md"
  printf -- '- sentry-topic: Sentry: handled by the captain out of band (closed 2026-07-27)\n' \
    > "$home/data/closed.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" explain-m1 alpha >/dev/null 2>&1
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/explain-m1/brief.md"
  out=$(FM_CLOSED_EXPLAIN=1 run_spawnable "$home" "$wt" explain-m1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "FM_CLOSED_EXPLAIN changed the gate verdict (got: $out)"
  assert_contains "$out" "boilerplate markers: ok, regions stripped:" "explain did not report the marker state"
  assert_contains "$out" "| Add a settings screen" "explain did not print the matched haystack"
  assert_not_contains "$out" "| - Sentry: MCP-backed" "the printed haystack still carried stripped boilerplate"
  # Off by default: the haystack must not appear in ordinary spawn output.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" explain-m2 alpha >/dev/null 2>&1
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/explain-m2/brief.md"
  out=$(run_spawnable "$home" "$wt" explain-m2 projects/alpha codex --why captain)
  assert_not_contains "$out" "haystack matched against" "the explain diagnostic is on by default"
  pass "gate 2: FM_CLOSED_EXPLAIN makes the narrowing inspectable without changing it"
}

# A "- " line that is not a well-formed entry closes NOTHING, so it must get LOUDER,
# not quieter: a typo'd closure that fails silently disarms the gate while the
# captain believes the topic is closed. Warned at the spawn call and at bootstrap,
# naming the offending line, without blocking an unrelated task. Comments, blank
# lines, and prose stay silent, because those are notes rather than attempted
# closures.
test_closed_malformed_line_is_loud() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home closed-malformed)
EOF
  printf '%s\n' \
'# a comment must stay silent
- good-topic: deleted user backlog: closed by the captain (closed 2026-07-25)
- oops-this-entry-has-no-second-colon
this prose line must stay silent' > "$home/data/closed.md"
  write_brief "$home" malformed-o1 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$home" "$wt" malformed-o1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a malformed register line blocked an unrelated spawn (got: $out)"
  assert_contains "$out" "NOT well-formed closures" "malformed register line warned about nothing"
  assert_contains "$out" "- oops-this-entry-has-no-second-colon" "warning did not name the offending line"
  assert_contains "$out" "- <slug>: <comma-separated keywords>:" "warning did not state the expected format"
  assert_not_contains "$out" "a comment must stay silent" "a comment line was reported as malformed"
  assert_not_contains "$out" "this prose line must stay silent" "a prose line was reported as malformed"
  assert_not_contains "$out" "- good-topic:" "a well-formed entry was reported as malformed"

  # Positive control for the silence assertions: a register whose only entries are
  # well-formed must produce NO warning at all, so the assertions above are reading
  # a warning that genuinely fires rather than one that never fires.
  printf -- '- good-topic: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$home/data/closed.md"
  write_brief "$home" malformed-o2 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$home" "$wt" malformed-o2 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a clean register blocked an unrelated spawn (got: $out)"
  assert_not_contains "$out" "NOT well-formed closures" "a clean register still warned"
  pass "gate 2: a malformed register line is warned about by name, while comments and prose stay silent"
}

# An entry whose keyword list is empty or normalizes to nothing is the worst shape a
# register can take: it passes for well-formed, so it would be listed as a closed slug
# and reported by bootstrap as closed, while matching NOTHING. The captain reads the
# slug and believes the topic is dead while the gate is disarmed. So it is malformed:
# warned by name, and never counted as a live closure. An indented bullet closes
# nothing either, because matching only reads bullets at column one.
test_closed_empty_keyword_entry_is_malformed() {
  local home wt out status line
  read -r home wt <<EOF
$(spawnable_home closed-emptykw)
EOF
  printf '%s\n' \
'- billing-topic:: the captain closed this (closed 2026-07-27)
- spacing-topic: : also closed (closed 2026-07-27)
- punctuation-topic: ---: also closed (closed 2026-07-27)
  - indented-topic: deleted user backlog: closed by the captain (closed 2026-07-25)
- good-topic: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"

  # Work naming every disarmed entry's own subject must not be refused by them, and
  # the register must say so out loud instead of presenting them as closures.
  write_brief "$home" emptykw-p1 'Review the billing spacing and punctuation of the indented invoice screen.'
  out=$(run_spawnable "$home" "$wt" emptykw-p1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "an entry that closes nothing still blocked a spawn (got: $out)"
  assert_contains "$out" "NOT well-formed closures" "an entry with no usable keyword warned about nothing"
  for line in '- billing-topic::' '- spacing-topic: :' '- punctuation-topic: ---:' '- indented-topic:'; do
    assert_contains "$out" "$line" "the warning did not name the offending line '$line'"
  done
  assert_not_contains "$out" "- good-topic:" "a usable entry was reported as malformed"

  # Positive control on the SAME register: the one entry that CAN fire still refuses,
  # so the assertions above are not passing because the gate stopped working.
  write_brief "$home" emptykw-p2 'Work the deleted user backlog until it drains.'
  out=$(run_spawnable "$home" "$wt" emptykw-p2 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "positive control: the one usable entry did not refuse"
  assert_contains "$out" "- good-topic: deleted user backlog:" "the closure line was not printed verbatim"
  assert_absent "$home/state/emptykw-p2.meta" "a refused spawn still wrote meta"
  pass "gate 2: an entry with no usable keyword is malformed and loud, never a silent closure"
}

# Markers alone are not enough to drop text, because a task in THIS repo legitimately
# quotes the marker pair when it is about the brief scaffold. So a region is dropped
# only when the marker and the text AGREE: marked AND opening with a section
# fm-brief.sh generates. A marked region that opens with anything else is kept and
# reported, because keeping more is recoverable and dropping task content is not.
test_closed_quoted_markers_in_task_body_still_match() {
  local home wt out status brief body id label verdict n=0
  read -r home wt <<EOF
$(spawnable_home closed-quoted-markers)
EOF
  printf -- '- Sentry: MCP-backed. reach: probe first.\n' > "$home/data/access.md"
  printf '%s\n' \
'- sentry-topic: Sentry: handled by the captain out of band (closed 2026-07-27)
- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"

  body="$TMP_ROOT/closed-quoted-markers-body"
  while IFS='|' read -r label verdict; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    id="quoted-r$n"
    case "$n" in
      1) # a task about the scaffold, quoting a balanced marker pair in a fenced block
        printf '%s\n' 'Document what the scaffold emits, e.g.:' '' '```' \
          '<!-- fm:boilerplate start -->' \
          'quoted sample text about the deleted user backlog' \
          '<!-- fm:boilerplate end -->' '```' > "$body" ;;
      2) # same shape, no closed keyword anywhere but the injected access map
        printf '%s\n' 'Document what the scaffold emits, e.g.:' '' '```' \
          '<!-- fm:boilerplate start -->' \
          'quoted sample text about notification preferences' \
          '<!-- fm:boilerplate end -->' '```' > "$body" ;;
    esac
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "$id" alpha >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    fill_task "$brief" "$body"
    assert_grep "quoted sample text" "$brief" "$id: the task body lost its quoted region"
    out=$(run_spawnable "$home" "$wt" "$id" projects/alpha codex --why captain)
    status=$?
    assert_contains "$out" "marked region(s) that do not begin with a" \
      "$label: an unrecognised marked region was dropped without a word"
    case "$verdict" in
      match)
        expect_code 3 "$status" "$label"
        assert_contains "$out" "- deleted-user-backlog: deleted user backlog:" \
          "$label: the closure line was not printed verbatim"
        assert_absent "$home/state/$id.meta" "$label: a refused spawn still wrote meta"
        ;;
      nomatch)
        expect_code 0 "$status" "$label: unrelated work was blocked (got: $out)"
        assert_present "$home/state/$id.meta" "$label: unrelated work did not spawn"
        ;;
    esac
  done <<'ROWS'
a closure phrase inside a task-quoted marker pair still refuses|match
control: the same quoted shape with no closed keyword still spawns|nomatch
ROWS

  # Control that the recognised regions are still dropped and the warning is not
  # simply always on: an ordinary generated brief spawns silently, even though the
  # closure keyword sits in its injected fleet access map.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" quoted-r3 alpha >/dev/null 2>&1
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/quoted-r3/brief.md"
  out=$(run_spawnable "$home" "$wt" quoted-r3 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: an ordinary generated brief was refused (got: $out)"
  assert_not_contains "$out" "marked region(s) that do not begin with a" \
    "control: a correctly generated brief was reported as unrecognisable"
  pass "gate 2: a marked region is dropped only when its opening agrees, and says so otherwise"
}

# The one gate that is supposed to be un-talk-past-able must not go vacuous on a brief
# nobody filled in: an unreplaced {TASK} placeholder leaves gate 2 with an essentially
# empty haystack, so the closure check would pass without having checked anything.
# Refused with its own exit code, distinct from the why (2) and closed (3) refusals.
test_unfilled_brief_refuses() {
  local home wt out status kind id
  read -r home wt <<EOF
$(spawnable_home unfilled-brief)
EOF
  printf -- '- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$home/data/closed.md"
  for kind in ship scout; do
    id="unfilled-$kind"
    if [ "$kind" = scout ]; then
      FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "$id" alpha --scout >/dev/null 2>&1
      out=$(run_spawnable "$home" "$wt" "$id" projects/alpha codex --why captain --scout)
    else
      FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
        FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" "$id" alpha >/dev/null 2>&1
      out=$(run_spawnable "$home" "$wt" "$id" projects/alpha codex --why captain)
    fi
    status=$?
    expect_code 4 "$status" "$kind: an unfilled brief spawned anyway (got: $out)"
    assert_contains "$out" "the brief was never filled in" "$kind: the refusal does not say what is wrong"
    assert_contains "$out" "$home/data/$id/brief.md" "$kind: the refusal does not name the brief"
    assert_absent "$home/state/$id.meta" "$kind: a refused spawn still wrote meta"
  done

  # Positive control: the same scaffolded brief, filled in, spawns as before.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$BRIEF_SH" unfilled-ok alpha >/dev/null 2>&1
  perl -0pi -e 's/\{TASK\}/Add a settings screen for notification preferences./' \
    "$home/data/unfilled-ok/brief.md"
  out=$(run_spawnable "$home" "$wt" unfilled-ok projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: a filled brief was refused (got: $out)"
  assert_present "$home/state/unfilled-ok.meta" "control: a filled brief did not spawn"
  pass "spawn: a brief still carrying the {TASK} placeholder refuses with its own exit code"
}

# The placeholder refusal has NO override - no --reopen-closed equivalent, nothing -
# so an over-broad match is unrecoverable except by rewording the task. A task body is
# free text, and in this repo a brief about the brief scaffold legitimately writes the
# placeholder in prose or quotes it in a fenced block; only the scaffold's own
# standalone placeholder line means "never filled in".
test_placeholder_mention_in_task_body_spawns() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home placeholder-mention)
EOF
  write_brief "$home" mention-p1 '# Task\nRewrite the brief scaffold so firstmate must replace the {TASK} placeholder before spawning.\n\n```sh\n# regenerate, then fill it in\nsed -i "" "s/{TASK}/the real task/" data/x/brief.md\n```\n'
  out=$(run_spawnable "$home" "$wt" mention-p1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a brief that merely mentions the placeholder was refused (got: $out)"
  assert_not_contains "$out" "never filled in" "an inline placeholder mention was read as an unfilled brief"
  assert_present "$home/state/mention-p1.meta" "a legitimate placeholder-mentioning brief did not spawn"

  # Positive control on the same fixture: the scaffold's own standalone placeholder
  # line, with the same surrounding prose, still refuses. Without this the negative
  # above would also pass if the check had simply stopped working.
  write_brief "$home" mention-p2 'Rewrite the brief scaffold so firstmate must replace the placeholder.\n\n# Task\n{TASK}\n'
  out=$(run_spawnable "$home" "$wt" mention-p2 projects/alpha codex --why captain)
  status=$?
  expect_code 4 "$status" "control: a standalone {TASK} line spawned anyway (got: $out)"
  assert_contains "$out" "the brief was never filled in" "control: the refusal text changed"
  assert_contains "$out" "filling in the brief's task section" "the refusal does not say how to fix it"
  assert_absent "$home/state/mention-p2.meta" "control: a refused spawn still wrote meta"
  pass "spawn: only the scaffold's own standalone {TASK} line counts as an unfilled brief"
}

# A fenced block is exactly where a brief about the brief scaffold demonstrates the
# shape it is asking someone to change, so the placeholder standing alone on its own
# line INSIDE a fence is ordinary task text, not an unfilled brief. Both fence forms
# are covered, because a markdown fence is either backticks or tildes.
test_placeholder_inside_fence_spawns() {
  local home wt out status label body n=0
  read -r home wt <<EOF
$(spawnable_home placeholder-fence)
EOF
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "fence-q$n" "$body"
    out=$(run_spawnable "$home" "$wt" "fence-q$n" projects/alpha codex --why captain)
    status=$?
    expect_code 0 "$status" "$label: a fenced placeholder was read as an unfilled brief (got: $out)"
    assert_not_contains "$out" "never filled in" "$label: the unfilled-brief refusal fired inside a fence"
    assert_present "$home/state/fence-q$n.meta" "$label: a legitimate brief did not spawn"
  done <<'ROWS'
backtick fence|# Task\nRewrite the scaffold so the task section:\n\n```markdown\n# Task\n{TASK}\n```\n\nis replaced before spawning.\n
tilde fence|# Task\nRewrite the scaffold so the task section:\n\n~~~markdown\n# Task\n{TASK}\n~~~\n\nis replaced before spawning.\n
fence reopened after a closed one|# Task\nFirst show the scaffold:\n\n```markdown\n{TASK}\n```\n\nThen show it again:\n\n```markdown\n{TASK}\n```\n
ROWS

  # Positive control on the same fixture: the identical prose with the placeholder
  # standing alone OUTSIDE any fence still refuses, so the passes above cannot be the
  # check having simply stopped firing.
  write_brief "$home" fence-q9 '# Task\nRewrite the scaffold so the task section:\n\n```markdown\n# Task\n```\n\nis replaced before spawning.\n\n{TASK}\n'
  out=$(run_spawnable "$home" "$wt" fence-q9 projects/alpha codex --why captain)
  status=$?
  expect_code 4 "$status" "control: a placeholder outside every fence spawned anyway (got: $out)"
  assert_contains "$out" "the brief was never filled in" "control: the refusal text changed"
  assert_absent "$home/state/fence-q9.meta" "control: a refused spawn still wrote meta"
  pass "spawn: a {TASK} line inside a fenced block is task text, not an unfilled brief"
}

# A check with no escape hatch eventually blocks legitimate work with no recourse, and
# gate 2 itself has --reopen-closed, so the unfilled-brief check must not be stricter
# than the closure gate. The waiver is loud and leaves a trace in meta, and - like the
# reopen it mirrors - it is a per-task judgement, so batch dispatch refuses it.
test_allow_unfilled_task_override() {
  local home wt out status
  read -r home wt <<EOF
$(spawnable_home allow-unfilled)
EOF
  # Control first: without the flag the same brief refuses.
  write_brief "$home" allow-r1 'Rewrite the brief scaffold.\n\n# Task\n{TASK}\n'
  out=$(run_spawnable "$home" "$wt" allow-r1 projects/alpha codex --why captain)
  status=$?
  expect_code 4 "$status" "control: an unfilled brief spawned without the waiver (got: $out)"
  assert_contains "$out" "pass --allow-unfilled-task" "the refusal does not name its own escape hatch"

  write_brief "$home" allow-r2 'Rewrite the brief scaffold.\n\n# Task\n{TASK}\n'
  out=$(run_spawnable "$home" "$wt" allow-r2 projects/alpha codex --why captain --allow-unfilled-task)
  status=$?
  expect_code 0 "$status" "the waiver did not let the spawn through (got: $out)"
  assert_contains "$out" "WARNING: --allow-unfilled-task is waiving the unfilled-brief check" \
    "the waiver was silent instead of loud"
  assert_grep "allowed_unfilled_task=1" "$home/state/allow-r2.meta" "the waiver left no trace in meta"

  # A spawn that never needed the waiver must not record one, or the trace means nothing.
  write_brief "$home" allow-r3 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$home" "$wt" allow-r3 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: a filled brief was refused (got: $out)"
  assert_no_grep "allowed_unfilled_task=" "$home/state/allow-r3.meta" "meta recorded a waiver that never happened"

  out=$(run_spawn "$home" au-t1=projects/alpha au-t2=projects/alpha --why captain --allow-unfilled-task)
  status=$?
  expect_code 2 "$status" "batch --allow-unfilled-task"
  assert_contains "$out" "--allow-unfilled-task is not accepted in batch dispatch" \
    "batch --allow-unfilled-task was not refused"
  assert_not_contains "$out" "batch:" "batch --allow-unfilled-task still dispatched pairs"
  pass "spawn: --allow-unfilled-task waives the unfilled-brief check loudly, per task, and is recorded"
}

# --- gate 2 across homes: the register is fleet-wide ------------------------

# secondmate_fixture <name>: a MAIN firstmate home plus a REAL secondmate home
# seeded from it by bin/fm-home-seed.sh, with an isolated worktree of the
# secondmate's own clone so a spawn dispatched from inside that home can complete.
# Echoes "<main-home> <secondmate-home> <worktree>".
secondmate_fixture() {
  local name=$1 main sub wt
  main="$TMP_ROOT/$name-main"
  sub="$TMP_ROOT/$name-sub"
  wt="$TMP_ROOT/$name-wt"
  mkdir -p "$main/data" "$main/state" "$main/projects" "$main/bin"
  printf '# Firstmate\n' > "$main/AGENTS.md"
  fm_git_init_commit "$main/projects/alpha"
  fm_git_add_origin "$main/projects/alpha" "$TMP_ROOT/remotes/$name-alpha.git"
  printf -- '- alpha [direct-PR] - alpha project (added 2026-07-01)\n' > "$main/data/projects.md"
  FM_HOME="$main" FM_SECONDMATE_CHARTER="triage for alpha" FM_SECONDMATE_SCOPE="triage for alpha" \
    "$ROOT/bin/fm-home-seed.sh" "$name" "$sub" alpha >/dev/null 2>&1 \
    || fail "$name: seeding a secondmate home failed"
  git -C "$sub/projects/alpha" worktree add -q --detach "$wt" >/dev/null 2>&1 \
    || fail "$name: could not create an isolated worktree in the secondmate clone"
  printf '%s %s %s\n' "$main" "$sub" "$wt"
}

# Most crews in this fleet are dispatched BY SECONDMATES, so a register that only
# existed in the main home would be enforced exactly where work is NOT started and
# inert everywhere it is. Asserted from INSIDE a real seeded secondmate home, on a
# closure the captain set only in the main home.
test_closed_register_reaches_secondmate_homes() {
  local main sub wt out status recorded
  read -r main sub wt <<EOF
$(secondmate_fixture reach)
EOF
  assert_present "$sub/config/primary-home" "seeding did not record the main firstmate home"
  recorded=$(cat "$sub/config/primary-home")
  [ "$(cd "$recorded" 2>/dev/null && pwd)" = "$(cd "$main" && pwd)" ] \
    || fail "the recorded main firstmate home is wrong: $recorded"

  printf -- '- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$main/data/closed.md"
  assert_absent "$sub/data/closed.md" "the secondmate home kept a competing register of its own"

  write_brief "$sub" reach-s1 'Drain the deleted user backlog and report what is left.'
  out=$(run_spawnable "$sub" "$wt" reach-s1 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "a closed topic spawned from a secondmate home (got: $out)"
  assert_contains "$out" "this topic is CLOSED." "the secondmate-home refusal lost its text"
  assert_contains "$out" "- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)" \
    "the secondmate-home refusal did not print the closure line verbatim"
  assert_absent "$sub/state/reach-s1.meta" "a refused secondmate-home spawn still wrote meta"

  # Negative control on the SAME register: unrelated work from the same home still
  # spawns, so the refusal above cannot be a matcher that refuses everything.
  write_brief "$sub" reach-s2 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$sub" "$wt" reach-s2 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: unrelated work from a secondmate home was refused (got: $out)"
  assert_present "$sub/state/reach-s2.meta" "control: unrelated work from a secondmate home did not spawn"
  pass "gate 2: a closure set in the main home refuses work dispatched from a secondmate home"
}

# If the register cannot be found, does this get louder or quieter? A secondmate home
# that cannot reach the main home has a BROKEN control, not an empty one, and the two
# must never look the same. It warns and proceeds: failing closed on every dispatch
# from that home would be its own outage.
test_secondmate_unresolvable_register_is_loud() {
  local main sub wt out status fakebin boot
  read -r main sub wt <<EOF
$(secondmate_fixture broken)
EOF
  printf -- '- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$main/data/closed.md"
  write_brief "$sub" broken-s1 'Add a settings screen for notification preferences.'

  # Control first: with the pointer intact the spawn is silent about resolution.
  out=$(run_spawnable "$sub" "$wt" broken-s1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: an intact pointer refused the spawn (got: $out)"
  assert_not_contains "$out" "cannot reach the fleet's data/closed.md" \
    "control: an intact pointer was reported as unreachable"

  # Positive control on the same pointer: a valid main home target still RESOLVES and
  # the register it reaches still fires, so the rejections below cannot pass by
  # resolution having broken outright.
  write_brief "$sub" broken-s2 'Drain the deleted user backlog and report what is left.'
  out=$(run_spawnable "$sub" "$wt" broken-s2 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "control: a valid pointer stopped enforcing the register (got: $out)"
  assert_contains "$out" "this topic is CLOSED." "control: the resolved register lost its refusal"

  # A target that is merely an enterable directory is the pointer failure an operator
  # is most likely to produce, and the one that used to pass silently: it resolves to a
  # <target>/data/closed.md that does not exist, which reads as "no closures set".
  mkdir -p "$TMP_ROOT/broken-unrelated"
  mkdir -p "$TMP_ROOT/broken-partial/bin"
  printf '# Firstmate\n' > "$TMP_ROOT/broken-partial/AGENTS.md"
  mkdir -p "$TMP_ROOT/broken-othersub/bin" "$TMP_ROOT/broken-othersub/data"
  printf '# Firstmate\n' > "$TMP_ROOT/broken-othersub/AGENTS.md"
  printf 'othersub\n' > "$TMP_ROOT/broken-othersub/.fm-secondmate-home"

  local case_label pointer expect n=0
  while IFS='|' read -r case_label pointer expect; do
    [ -n "$case_label" ] || continue
    n=$((n + 1))
    case "$pointer" in
      missing) rm -f "$sub/config/primary-home" ;;
      dangling) printf '%s\n' "$TMP_ROOT/broken-no-such-home" > "$sub/config/primary-home" ;;
      empty) : > "$sub/config/primary-home" ;;
      relative) printf 'not/an/absolute/path\n' > "$sub/config/primary-home" ;;
      parent) printf '%s\n' "$TMP_ROOT" > "$sub/config/primary-home" ;;
      unrelated) printf '%s\n' "$TMP_ROOT/broken-unrelated" > "$sub/config/primary-home" ;;
      partial) printf '%s\n' "$TMP_ROOT/broken-partial" > "$sub/config/primary-home" ;;
      othersub) printf '%s\n' "$TMP_ROOT/broken-othersub" > "$sub/config/primary-home" ;;
    esac
    write_brief "$sub" "broken-u$n" 'Add a settings screen for notification preferences.'
    out=$(run_spawnable "$sub" "$wt" "broken-u$n" projects/alpha codex --why captain)
    status=$?
    expect_code 0 "$status" "$case_label: an unresolvable register refused the spawn instead of warning (got: $out)"
    assert_contains "$out" "cannot reach the fleet's data/closed.md" "$case_label: the broken control was silent"
    assert_contains "$out" "$expect" "$case_label: the warning did not name what could not be resolved"
    assert_present "$sub/state/broken-u$n.meta" "$case_label: a warned spawn did not proceed"
  done <<'ROWS'
a missing pointer warns|missing|no main firstmate home recorded at
a dangling pointer warns|dangling|which does not exist
an empty pointer warns|empty|is empty
a relative pointer warns|relative|must hold an absolute path
a pointer at the main home parent warns|parent|is not a firstmate home (missing AGENTS.md)
a pointer at an unrelated directory warns|unrelated|is not a firstmate home (missing AGENTS.md)
a pointer at a half-shaped home warns|partial|is not a firstmate home (missing data/)
a pointer at another secondmate home warns|othersub|which is itself a secondmate home
ROWS

  # The same broken control must be visible at session start in that home, not only
  # at the moment of a spawn.
  fakebin=$(fm_fakebin "$TMP_ROOT/broken-bootstrap")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi curl jq treehouse no-mistakes
  rm -f "$sub/config/primary-home"
  boot=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" TMUX='' "$BOOTSTRAP")
  assert_contains "$boot" "CLOSED_TOPICS_UNRESOLVED:" "bootstrap in a secondmate home hid the broken register"

  # Positive control for that absence: with the pointer restored, bootstrap reports
  # the main home's closures instead of the unresolved line.
  printf '%s\n' "$main" > "$sub/config/primary-home"
  boot=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" TMUX='' "$BOOTSTRAP")
  assert_contains "$boot" "CLOSED_TOPICS: 1 closed at intake: deleted-user-backlog" \
    "bootstrap in a secondmate home did not report the main home's closures"
  assert_not_contains "$boot" "CLOSED_TOPICS_UNRESOLVED" "a resolvable register still reported as unresolved"
  pass "gate 2: a secondmate home that cannot reach the register is loud, and still dispatches"
}

# A secondmate is a firstmate running this same AGENTS.md, and "add a closure line when
# the captain closes a topic" does not name a home at the point of action, so a captain
# closing a topic while steering a lead will naturally write it into that lead's own
# data/closed.md. Nothing reads that file. It is neither deleted nor honoured - one
# register is the design - but it must never look like it took effect.
test_secondmate_local_register_is_reported() {
  local main sub wt out status fakebin boot
  read -r main sub wt <<EOF
$(secondmate_fixture shadow)
EOF
  printf -- '- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$main/data/closed.md"
  write_brief "$sub" shadow-s1 'Add a settings screen for notification preferences.'

  # Control first: with no local register the spawn says nothing about one.
  out=$(run_spawnable "$sub" "$wt" shadow-s1 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: a clean secondmate home refused the spawn (got: $out)"
  assert_not_contains "$out" "is IGNORED." "control: a home with no local register was warned about one"

  printf -- '- local-closure: some local topic: written in the wrong home (closed 2026-07-26)\n' \
    > "$sub/data/closed.md"
  write_brief "$sub" shadow-s2 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$sub" "$wt" shadow-s2 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "an ignored local register refused the spawn instead of warning (got: $out)"
  assert_contains "$out" "$sub/data/closed.md is IGNORED." "the ignored local register was silent"
  assert_contains "$out" "$(cd "$main" && pwd)/data/closed.md" \
    "the warning did not name the register that does apply"
  assert_present "$sub/state/shadow-s2.meta" "a warned spawn did not proceed"

  # It is reported, not honoured: the local line still closes nothing.
  write_brief "$sub" shadow-s3 'Investigate some local topic before the next release.'
  out=$(run_spawnable "$sub" "$wt" shadow-s3 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "a local register was honoured instead of ignored (got: $out)"

  # And visible at session start in that home, not only at the moment of a spawn.
  fakebin=$(fm_fakebin "$TMP_ROOT/shadow-bootstrap")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi curl jq treehouse no-mistakes
  boot=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" TMUX='' "$BOOTSTRAP")
  assert_contains "$boot" "CLOSED_TOPICS_LOCAL_IGNORED: $sub/data/closed.md is IGNORED" \
    "bootstrap in a secondmate home hid the ignored local register"
  assert_contains "$boot" "CLOSED_TOPICS: 1 closed at intake: deleted-user-backlog" \
    "bootstrap reported the local register's slugs instead of the fleet's"

  # Positive control for that report: removing the local file removes the line.
  rm -f "$sub/data/closed.md"
  boot=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" TMUX='' "$BOOTSTRAP")
  assert_not_contains "$boot" "CLOSED_TOPICS_LOCAL_IGNORED" "a home with no local register still reported one"
  pass "gate 2: a secondmate home's own closed.md is reported as ignored, and never honoured"
}

# The pointer used to be written only at seed time and at launch, so every home seeded
# before it existed stayed unmigrated: loud on every routine dispatch until someone
# relaunched it. An unmigrated control is not a broken one, and routine output full of
# warnings teaches people to skim the warning that matters, so the fleet converges at
# session start instead.
test_bootstrap_migrates_secondmate_pointer() {
  local main sub wt out status fakebin boot
  read -r main sub wt <<EOF
$(secondmate_fixture ptrmigrate)
EOF
  printf -- '- deleted-user-backlog: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$main/data/closed.md"
  # A home seeded before the pointer existed: it has none, so the register is
  # unreachable and the gate is loud rather than enforcing.
  rm -f "$sub/config/primary-home"
  write_brief "$sub" ptr-s0 'Drain the deleted user backlog and report what is left.'
  out=$(run_spawnable "$sub" "$wt" ptr-s0 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "an unmigrated home refused the spawn instead of warning (got: $out)"
  assert_contains "$out" "cannot reach the fleet's data/closed.md" "an unmigrated home was silent"

  printf 'window=firstmate:fm-ptrmigrate\nkind=secondmate\nhome=%s\n' "$sub" \
    > "$main/state/ptrmigrate.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/ptrmigrate-bootstrap")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi curl jq treehouse no-mistakes
  boot=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$main" FM_ROOT_OVERRIDE="$main" TMUX='' "$BOOTSTRAP" 2>/dev/null)
  assert_present "$sub/config/primary-home" "bootstrap did not converge an unmigrated secondmate home"
  [ "$(cd "$(cat "$sub/config/primary-home")" && pwd)" = "$(cd "$main" && pwd)" ] \
    || fail "bootstrap recorded the wrong main firstmate home"
  assert_not_contains "$boot" "primary-home" "a routine pointer refresh was reported to the operator"

  # The migration is only real if the gate it feeds now fires from that home.
  write_brief "$sub" ptr-s1 'Drain the deleted user backlog and report what is left.'
  out=$(run_spawnable "$sub" "$wt" ptr-s1 projects/alpha codex --why captain)
  status=$?
  expect_code 3 "$status" "a converged home did not enforce the main register (got: $out)"
  assert_not_contains "$out" "cannot reach the fleet's data/closed.md" "a converged home still warned"

  # Negative control on the same converged home: unrelated work still spawns, so the
  # refusal above is the register matching rather than the home refusing everything.
  write_brief "$sub" ptr-s2 'Add a settings screen for notification preferences.'
  out=$(run_spawnable "$sub" "$wt" ptr-s2 projects/alpha codex --why captain)
  status=$?
  expect_code 0 "$status" "control: unrelated work from a converged home was refused (got: $out)"

  # A home whose main home MOVED converges too: that refresh is the property that made
  # a pointer preferable to copying the register into every home.
  printf '%s\n' "$TMP_ROOT/ptrmigrate-elsewhere" > "$sub/config/primary-home"
  mkdir -p "$TMP_ROOT/ptrmigrate-elsewhere/bin" "$TMP_ROOT/ptrmigrate-elsewhere/data"
  printf '# Firstmate\n' > "$TMP_ROOT/ptrmigrate-elsewhere/AGENTS.md"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$main" FM_ROOT_OVERRIDE="$main" TMUX='' "$BOOTSTRAP" >/dev/null 2>&1
  [ "$(cd "$(cat "$sub/config/primary-home")" && pwd)" = "$(cd "$main" && pwd)" ] \
    || fail "bootstrap did not refresh a pointer aimed at a stale main firstmate home"
  pass "bootstrap converges every live secondmate home on this session's main firstmate home"
}

# The fleet access map is the same pointer and the same drift argument: the crews a
# secondmate spawns are most of the fleet's crews, so they must get the captain's map
# rather than an empty inventory.
test_access_map_reaches_secondmate_homes() {
  local main sub wt brief out
  read -r main sub wt <<EOF
$(secondmate_fixture accessmap)
EOF
  printf -- '- Sentry: MCP-backed. reach: probe first.\n- App Store Connect: reach: firstmate-only.\n' \
    > "$main/data/access.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$sub" FM_DATA_OVERRIDE="$sub/data" \
    FM_STATE_OVERRIDE="$sub/state" "$ROOT/bin/fm-brief.sh" access-sub-1 alpha >/dev/null 2>&1
  brief="$sub/data/access-sub-1/brief.md"
  assert_grep "## Fleet access map" "$brief" "a secondmate's crew brief lost the fleet access map"
  assert_grep "App Store Connect: reach: firstmate-only." "$brief" \
    "a secondmate's crew brief did not inject the main home's access map"

  # Broken pointer: loud, and the routing rule still ships without a fabricated map.
  rm -f "$sub/config/primary-home"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$sub" FM_DATA_OVERRIDE="$sub/data" \
    FM_STATE_OVERRIDE="$sub/state" "$ROOT/bin/fm-brief.sh" access-sub-2 alpha 2>&1 >/dev/null)
  assert_contains "$out" "cannot reach the fleet's data/access.md" "an unreachable access map was silent"
  brief="$sub/data/access-sub-2/brief.md"
  assert_grep "# Access and routing" "$brief" "the structural access section vanished with an unreachable map"
  assert_no_grep "## Fleet access map" "$brief" "an empty fleet map heading was emitted with an unreachable map"
  pass "gate 4: the fleet access map reaches a secondmate's crews, and is loud when it cannot"
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
      malformed) printf -- '- oops-no-second-colon\n' > "$home/data/closed.md" ;;
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
a malformed line is named, not counted away|malformed|CLOSED_TOPICS_MALFORMED: closes nothing, fix or remove: - oops-no-second-colon
ROWS
  pass "bootstrap reports closed topics only when the register holds entries, and names malformed lines"
}

# The malformed report must not be inferable only from a slug count nobody reads:
# the register that carries a malformed line alongside real entries must print BOTH
# the offending line and the normal count line, and a clean register must print
# neither warning.
test_bootstrap_malformed_report_is_specific() {
  local home fakebin out
  home="$TMP_ROOT/bootstrap-malformed"
  mkdir -p "$home/data"
  fakebin=$(fm_fakebin "$TMP_ROOT/bootstrap-malformed")
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

  printf '%s\n' "$REGISTER" > "$home/data/closed.md"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" TMUX='' "$BOOTSTRAP")
  assert_contains "$out" "CLOSED_TOPICS_MALFORMED: closes nothing, fix or remove: - malformed-entry-with-no-second-colon" \
    "bootstrap did not name the malformed line alongside real entries"
  assert_contains "$out" "CLOSED_TOPICS: 2 closed at intake:" \
    "bootstrap dropped the normal count line when a malformed line was present"
  assert_not_contains "$out" "CLOSED_TOPICS_MALFORMED: closes nothing, fix or remove: this prose line" \
    "bootstrap reported a prose line as malformed"

  # An entry with no usable keyword must not be COUNTED as closed: reporting a slug
  # the gate can never fire on tells the captain a topic is dead while it is live.
  printf '%s\n' \
'- billing-topic:: the captain closed this (closed 2026-07-27)
- good-topic: deleted user backlog: closed by the captain (closed 2026-07-25)' \
    > "$home/data/closed.md"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" TMUX='' "$BOOTSTRAP")
  assert_contains "$out" "CLOSED_TOPICS_MALFORMED: closes nothing, fix or remove: - billing-topic::" \
    "bootstrap did not name an entry whose keyword list closes nothing"
  assert_contains "$out" "CLOSED_TOPICS: 1 closed at intake: good-topic" \
    "bootstrap counted an entry that closes nothing as a live closure"

  # Positive control for that absence: a clean register reports the count and no
  # malformed line at all.
  printf -- '- good-topic: deleted user backlog: closed by the captain (closed 2026-07-25)\n' \
    > "$home/data/closed.md"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" TMUX='' "$BOOTSTRAP")
  assert_contains "$out" "CLOSED_TOPICS: 1 closed at intake: good-topic" "clean register lost its count line"
  assert_not_contains "$out" "CLOSED_TOPICS_MALFORMED" "a clean register still reported a malformed line"
  pass "bootstrap names a malformed closure line without dropping the normal report"
}

test_why_gate
test_why_refusal_text
test_why_gate_exempts_secondmate
test_why_gate_batch
test_reopen_closed_refused_in_batch
test_closed_gate_refuses
test_closed_refusal_shows_the_line
test_closed_matching_precision
test_closed_ignores_non_entries
test_closed_ignores_injected_boilerplate
test_closed_matches_task_body_after_hash_line
test_closed_marker_fallbacks_keep_whole_brief
test_closed_explain_shows_the_haystack
test_closed_malformed_line_is_loud
test_closed_empty_keyword_entry_is_malformed
test_closed_quoted_markers_in_task_body_still_match
test_unfilled_brief_refuses
test_placeholder_mention_in_task_body_spawns
test_placeholder_inside_fence_spawns
test_allow_unfilled_task_override
test_closed_absent_register
test_closed_register_reaches_secondmate_homes
test_secondmate_unresolvable_register_is_loud
test_secondmate_local_register_is_reported
test_bootstrap_migrates_secondmate_pointer
test_access_map_reaches_secondmate_homes
test_meta_records_provenance
test_brief_freshness_section
test_brief_access_section
test_brief_access_map_injection
test_bootstrap_closed_report
test_bootstrap_malformed_report_is_specific
