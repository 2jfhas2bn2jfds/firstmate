#!/usr/bin/env bash
# Behavior tests for fm-brief.sh's engineering-conventions injection.
#
# Every generated brief - ship, scout, and the secondmate charter - must carry the
# captain's "## Engineering conventions" section from data/captain.md, injected near
# the top under a clearly-labeled "# Engineering conventions (follow these)" heading,
# so the conventions reach every crewmate/secondmate the moment it spawns. When
# captain.md is missing, has no such section, or the section is empty, injection is a
# clean no-op that leaves the existing brief shapes untouched. These cases pin: the
# section extraction (heading boundaries, exclusion of neighbouring sections), the
# near-the-top placement ahead of the first brief section, idempotence, and the
# graceful-skip paths - all hermetic over temp homes.
#
# The injection logic is computed once, before fm-brief.sh splits into its per-kind
# arms, so the scout and secondmate arms exercise the identical shared logic on every
# bash. The ship arm builds its definition-of-done with an apostrophe inside a
# $(cat <<EOF) command substitution that bash 3.2 cannot parse (a pre-existing
# limitation tracked separately); the ship sub-cases therefore run on bash 4+/CI and
# are skipped cleanly on bash 3.2, where the scout/secondmate cases already prove the
# behaviour.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-conventions)

INJECT_HEADING='# Engineering conventions (follow these)'
INJECT_FRAMING='The captain'\''s standing engineering conventions apply to all your work on this task'

# A captain.md whose Engineering conventions section sits between a preceding and a
# following section, so extraction must pull only the middle one. Markers:
#   BEFORE-MARKER  - in the section above; must never leak.
#   INTRO-MARKER + CONV-EM + CONV-COAUTHOR - inside the section; must be injected.
#   AFTER-MARKER   - in the section below (the next ## heading); must never leak.
write_captain_with_section() {
  local home=$1
  cat > "$home/data/captain.md" <<'EOF'
# Captain preferences

## Personal style
Personal BEFORE-MARKER preference that is captain-private and must not leak.

## Engineering conventions (adopted from somewhere, per captain)
INTRO-MARKER framing paragraph for the conventions.

1. **No em dashes.** Convention CONV-EM applies everywhere.
2. **No agent co-author lines.** Convention CONV-COAUTHOR in commits.

## After conventions
Trailing AFTER-MARKER detail that is captain-private and must not leak.
EOF
}

# fm-brief.sh's ship arm cannot be parsed by bash 3.2 (see header). Probe the running
# bash so ship sub-cases run only where the script parses.
ship_path_parseable() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>/dev/null
}

# run_brief <home> <args...>: scaffold a brief under <home> with overrides cleared so
# only FM_HOME selects the home. fm-project-mode warns to stderr when a home has no
# registry; that is expected, so stderr is dropped.
run_brief() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$@" >/dev/null 2>&1
}

# make_home <name>: a temp home (with the data/ and state/ dirs the script expects)
# at $TMP_ROOT/<name>. mkdir -p also re-materialises $TMP_ROOT, which the lib's
# command-substitution cleanup trap removes on assignment under bash 3.2.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# assert_injection_precedes <brief> <section-heading> <label>: the injected conventions
# heading must appear, and must precede the brief's first content section.
assert_injection_precedes() {
  local brief=$1 section_heading=$2 label=$3 inj sec
  inj=$(grep -n -F -- "$INJECT_HEADING" "$brief" | head -1 | cut -d: -f1)
  sec=$(grep -n -F -- "$section_heading" "$brief" | head -1 | cut -d: -f1)
  [ -n "$inj" ] || fail "$label: injected conventions heading missing"
  [ -n "$sec" ] || fail "$label: brief is missing its first section ($section_heading)"
  [ "$inj" -lt "$sec" ] || fail "$label: conventions (line $inj) must precede $section_heading (line $sec)"
}

# assert_injected <brief> <label>: the brief carries the full injected block and none
# of the neighbouring-section markers.
assert_injected() {
  local brief=$1 label=$2
  assert_grep "$INJECT_HEADING" "$brief" "$label: missing injected conventions heading"
  assert_grep "$INJECT_FRAMING" "$brief" "$label: missing injected framing line"
  assert_grep "INTRO-MARKER" "$brief" "$label: missing conventions intro"
  assert_grep "CONV-EM" "$brief" "$label: missing the no-em-dash convention"
  assert_grep "CONV-COAUTHOR" "$brief" "$label: missing the no-co-author convention"
  assert_no_grep "BEFORE-MARKER" "$brief" "$label: leaked the preceding (private) section"
  assert_no_grep "AFTER-MARKER" "$brief" "$label: leaked the following (private) section"
  assert_no_grep "adopted from somewhere" "$brief" "$label: kept the captain's own section heading instead of relabeling"
}

# assert_not_injected <brief> <label>: no injected block, and the brief is otherwise a
# well-formed brief (still carries its own first section).
assert_not_injected() {
  local brief=$1 section_heading=$2 label=$3
  assert_no_grep "$INJECT_HEADING" "$brief" "$label: injected conventions where there should be none"
  assert_grep "$section_heading" "$brief" "$label: brief lost its first section"
}

# extract_inject_block <brief>: the injected region (heading through the line before
# the next top-level heading), used for the idempotence comparison.
extract_inject_block() {
  awk '
    /^# Engineering conventions \(follow these\)/ { grab = 1 }
    grab && /^# / && !/^# Engineering conventions \(follow these\)/ { exit }
    grab { print }
  ' "$1"
}

# --- injection present: the section exists ----------------------------------

test_injects_into_every_brief_shape() {
  local home brief
  home=$(make_home inj)
  write_captain_with_section "$home"

  run_brief "$home" scout-inj-a1 alpha --scout
  brief="$home/data/scout-inj-a1/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_injected "$brief" "scout"
  assert_injection_precedes "$brief" "# Task" "scout"

  FM_SECONDMATE_CHARTER='Persistent test charter' \
    run_brief "$home" sm-inj-b2 --secondmate alpha
  brief="$home/data/sm-inj-b2/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_injected "$brief" "secondmate"
  assert_injection_precedes "$brief" "# Charter" "secondmate"

  if ship_path_parseable; then
    run_brief "$home" ship-inj-c3 alpha
    brief="$home/data/ship-inj-c3/brief.md"
    assert_present "$brief" "ship brief was not scaffolded"
    assert_injected "$brief" "ship"
    assert_injection_precedes "$brief" "# Task" "ship"
    pass "fm-brief: conventions injected into ship, scout, and secondmate briefs"
  else
    pass "fm-brief: conventions injected into scout and secondmate briefs (ship arm unparseable on bash ${BASH_VERSINFO[0]:-?}, skipped)"
  fi
}

# --- graceful skip: captain.md has no conventions section -------------------

test_skips_when_section_absent() {
  local home brief
  home=$(make_home skip)
  cat > "$home/data/captain.md" <<'EOF'
# Captain preferences

## Personal style
Only a personal preference here; NOSECTION-MARKER and no conventions section.
EOF

  run_brief "$home" scout-skip-d4 alpha --scout
  brief="$home/data/scout-skip-d4/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_not_injected "$brief" "# Task" "scout/no-section"
  assert_no_grep "NOSECTION-MARKER" "$brief" "scout/no-section: leaked captain.md content"

  FM_SECONDMATE_CHARTER='Persistent test charter' \
    run_brief "$home" sm-skip-e5 --secondmate alpha
  brief="$home/data/sm-skip-e5/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_not_injected "$brief" "# Charter" "secondmate/no-section"

  if ship_path_parseable; then
    run_brief "$home" ship-skip-f6 alpha
    brief="$home/data/ship-skip-f6/brief.md"
    assert_present "$brief" "ship brief was not scaffolded"
    assert_not_injected "$brief" "# Task" "ship/no-section"
  fi
  pass "fm-brief: no injection when captain.md has no conventions section"
}

# --- graceful skip: captain.md missing entirely -----------------------------

test_skips_when_captain_missing() {
  local home brief
  home=$(make_home nocap)
  # No data/captain.md at all.

  run_brief "$home" scout-nocap-g7 alpha --scout
  brief="$home/data/scout-nocap-g7/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_not_injected "$brief" "# Task" "scout/no-captain"

  FM_SECONDMATE_CHARTER='Persistent test charter' \
    run_brief "$home" sm-nocap-h8 --secondmate alpha
  brief="$home/data/sm-nocap-h8/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_not_injected "$brief" "# Charter" "secondmate/no-captain"

  if ship_path_parseable; then
    run_brief "$home" ship-nocap-i9 alpha
    brief="$home/data/ship-nocap-i9/brief.md"
    assert_present "$brief" "ship brief was not scaffolded"
    assert_not_injected "$brief" "# Task" "ship/no-captain"
  fi
  pass "fm-brief: no injection when captain.md is absent"
}

# --- graceful skip: section present but empty -------------------------------

test_skips_when_section_empty() {
  local home brief
  home=$(make_home empty)
  cat > "$home/data/captain.md" <<'EOF'
## Engineering conventions

## Next section
Body that is not a convention.
EOF

  run_brief "$home" scout-empty-j1 alpha --scout
  brief="$home/data/scout-empty-j1/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_not_injected "$brief" "# Task" "scout/empty-section"
  pass "fm-brief: no injection when the conventions section is empty"
}

# --- idempotence ------------------------------------------------------------

test_injection_is_idempotent() {
  local home first second
  home=$(make_home idem)
  write_captain_with_section "$home"

  run_brief "$home" scout-idem-k1 alpha --scout
  run_brief "$home" scout-idem-k2 alpha --scout
  first=$(extract_inject_block "$home/data/scout-idem-k1/brief.md")
  second=$(extract_inject_block "$home/data/scout-idem-k2/brief.md")
  [ -n "$first" ] || fail "idempotence: extracted an empty injected block"
  [ "$first" = "$second" ] || fail "idempotence: regenerating produced a different injected block"
  pass "fm-brief: the injected conventions block is deterministic"
}

test_injects_into_every_brief_shape
test_skips_when_section_absent
test_skips_when_captain_missing
test_skips_when_section_empty
test_injection_is_idempotent
