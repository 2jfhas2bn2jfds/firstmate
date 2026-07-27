# shellcheck shell=bash
# Shared closed-topic matcher for the intake gate.
# Usage: . bin/fm-closed-lib.sh
#
# The captain closes topics ("I handled this out of band", "that backlog is not
# work"). A closure that only lives in prose is re-opened by the next session,
# because the next session starts from a clean context and the topic still looks
# interesting. This library moves the closure to the one place that cannot be
# talked past: fm-spawn refusing with a non-zero exit.
#
# The register is data/closed.md under the active firstmate home - gitignored
# with the rest of data/, because closures are captain-specific while the
# mechanism is shared. One entry per line:
#
#   - <slug>: <comma-separated keywords>: <one-line why> (closed <date>)
#
# Blank lines and lines whose first non-space character is '#' are comments.
# A line that does not start with "- " is ignored, so a hand-written note in the
# file never becomes a silent gate. A line that DOES start with "- " but is not a
# well-formed entry (no second ':', or an empty slug) gates nothing either, and
# that is exactly why fm_closed_malformed reports it: a typo'd closure would
# otherwise disarm the gate while the captain believes the topic is closed, which
# is a control going quiet at the moment it has failed.
#
# MATCHING RULE (stated here because a gate whose rule is not written down is a
# gate nobody can predict):
#   1. Both the haystack (task id + the brief with fm-brief.sh's marked boilerplate
#      regions stripped, see fm_closed_haystack_body) and each keyword are normalized:
#      lowercased, then every character outside [a-z0-9] - punctuation, hyphens,
#      underscores, newlines - becomes a space, and runs of spaces collapse to
#      one. So "post-deletion", "Post Deletion", "post_deletion" and a phrase
#      wrapped across two lines all normalize to the same token sequence.
#   2. A keyword matches only as a WHOLE token sequence: the normalized keyword
#      is searched space-delimited, so "billing" does not match "billings" and
#      "delete" does not match "deleted".
#   3. A closure matches when ANY of its keywords matches.
# The rule is deliberately tight on token boundaries and deliberately blind to
# punctuation and case. Breadth is the operator's lever, not the matcher's:
# a one-word generic keyword ("billing") WILL block unrelated work that merely
# mentions it, so entries should carry specific multi-word phrases.

# Normalize stdin to a single space-delimited token line (see rule 1 above).
# Deliberately collapses newlines, so a keyword split across a line break in a
# brief still matches.
fm_closed_normalize() {
  LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' ' ' | LC_ALL=C tr -s ' '
}

# fm_closed_entry_field <line> <slug|keywords|why>: parse one register line.
# Returns 1 for any line that is not a well-formed entry (comment, blank, prose).
fm_closed_entry_field() {
  local line=$1 field=$2 body rest
  case "$line" in
    '- '*) body=${line#- } ;;
    *) return 1 ;;
  esac
  case "$body" in
    *:*:*) : ;;
    *) return 1 ;;
  esac
  rest=${body#*:}
  case "$field" in
    slug) printf '%s\n' "${body%%:*}" ;;
    keywords) printf '%s\n' "${rest%%:*}" ;;
    why) printf '%s\n' "${rest#*:}" ;;
    *) return 1 ;;
  esac
}

# fm_closed_slugs <register>: print each well-formed entry's slug, one per line.
# Silent (and exit 0) when the register is absent or holds no entries.
fm_closed_slugs() {
  local register=$1 line slug
  [ -f "$register" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    slug=$(fm_closed_entry_field "$line" slug) || continue
    slug=$(printf '%s' "$slug" | tr -d '[:space:]')
    [ -n "$slug" ] && printf '%s\n' "$slug"
  done < "$register"
}

# fm_closed_malformed <register>: print every "- " line that is NOT a well-formed
# entry, one per line, verbatim. Comments, blank lines, and prose that does not
# start with "- " stay silent, because those are notes rather than attempted
# closures. Silent (and exit 0) when the register is absent.
fm_closed_malformed() {
  local register=$1 line slug
  [ -f "$register" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*) : ;;
      *) continue ;;
    esac
    if slug=$(fm_closed_entry_field "$line" slug); then
      slug=$(printf '%s' "$slug" | tr -d '[:space:]')
      [ -n "$slug" ] && continue
    fi
    printf '%s\n' "$line"
  done < "$register"
}

# Explicit machine markers that fm-brief.sh wraps around every block it injects
# into a generated brief. They are HTML comments, so they are invisible in rendered
# markdown, and nobody writes one by hand into a task description.
FM_CLOSED_BOILERPLATE_START='<!-- fm:boilerplate start -->'
FM_CLOSED_BOILERPLATE_END='<!-- fm:boilerplate end -->'

# fm_closed_marker_status <brief-file>: print "<state> <count>" where state is
#   none        the file carries no boilerplate markers at all
#   ok          every marker is balanced and non-nested; count is the region count
#   unbalanced  a start with no end, an end with no start, or a nested start
fm_closed_marker_status() {
  local brief=$1
  if [ ! -f "$brief" ]; then
    printf 'none 0\n'
    return 0
  fi
  awk -v s="$FM_CLOSED_BOILERPLATE_START" -v e="$FM_CLOSED_BOILERPLATE_END" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t\r]+$/, "", line)
      if (line == s) { seen++; if (open) bad = 1; open = 1; starts++ }
      else if (line == e) { seen++; if (!open) bad = 1; open = 0 }
    }
    END {
      if (open) bad = 1
      if (!seen) { print "none 0"; exit }
      if (bad) { print "unbalanced " starts; exit }
      print "ok " starts
    }
  ' "$brief"
}

# fm_closed_haystack_body <brief-file>: print the whole brief MINUS the regions
# fm-brief.sh marked as injected boilerplate.
#
# The boilerplate must never be matched: the engineering conventions, the freshness
# block and its list of live-state examples, the access-and-routing rules, and the
# whole of data/access.md with every connector name in it. A closure keyword landing
# in any of that would match EVERY brief and refuse EVERY dispatch, and a gate that
# refuses everything is worse than the problem it solves.
#
# BOUNDARIES COME FROM EXPLICIT MARKERS, NEVER FROM HEADING TEXT, and that is the
# whole design. A task body is free text firstmate writes, so it can contain any
# heading a brief uses - a task about editing the brief scaffold quotes "# Setup" -
# and a stripper keyed on heading text would then drop the rest of the task from the
# haystack, silently covering less than the captain believes. That failure is
# invisible, and it is exactly what this gate exists to prevent.
#
# Narrowing is therefore allowed only where it is CERTAIN, and every uncertain case
# keeps MORE text rather than less:
#   - no markers at all (a hand-written brief, or one generated before markers
#     landed): the WHOLE file is the haystack. There is no heading-text fallback.
#   - unbalanced or nested markers: the WHOLE file is the haystack AND a warning
#     names the brief, because confidence is the precondition for dropping anything.
#   - a marker fm-brief.sh stops emitting: MORE text is matched, so the worst case is
#     a false refusal, which is loud, visible to whoever ran the spawn, and undone
#     with one flag.
# Do not "simplify" this back into a heading-text stripper or a task-section extractor.
#
# Set FM_CLOSED_EXPLAIN=1 on a spawn to see the exact haystack this produced and how
# many marked regions it removed.
fm_closed_haystack_body() {
  local brief=$1 status state
  [ -f "$brief" ] || return 0
  status=$(fm_closed_marker_status "$brief")
  state=${status%% *}
  case "$state" in
    ok)
      awk -v s="$FM_CLOSED_BOILERPLATE_START" -v e="$FM_CLOSED_BOILERPLATE_END" '
        {
          line = $0
          sub(/^[ \t]+/, "", line)
          sub(/[ \t\r]+$/, "", line)
          if (line == s) { dropping = 1; next }
          if (line == e) { dropping = 0; next }
          if (!dropping) print
        }
      ' "$brief"
      ;;
    unbalanced)
      {
        echo "warning: $brief has unbalanced fm:boilerplate markers, so no region can be"
        echo "  confidently identified as injected boilerplate. Matching the WHOLE brief"
        echo "  against the closed-topic register instead, which may refuse a spawn that a"
        echo "  correctly marked brief would not. Regenerate the brief with bin/fm-brief.sh."
      } >&2
      cat "$brief"
      ;;
    *)
      cat "$brief"
      ;;
  esac
}

# fm_closed_match <register> <haystack-file>: print every matching entry as
# "<slug>\t<original line>". Returns 0 when at least one entry matched, 1 when
# none did (including an absent or entry-free register).
#
# The haystack is passed as a FILE, never as an argument: brief text is
# arbitrary, may be large, and must never be interpolated into a command line.
fm_closed_match() {
  local register=$1 haystack_file=$2 hay line slug keywords rest kw kw_norm found=1
  [ -f "$register" ] || return 1
  [ -f "$haystack_file" ] || return 1
  hay=" $(fm_closed_normalize < "$haystack_file") "
  while IFS= read -r line || [ -n "$line" ]; do
    slug=$(fm_closed_entry_field "$line" slug) || continue
    keywords=$(fm_closed_entry_field "$line" keywords) || continue
    slug=$(printf '%s' "$slug" | tr -d '[:space:]')
    [ -n "$slug" ] || continue
    # Split the comma-separated keyword list with parameter expansion only: no IFS
    # juggling and no arrays, so the walk behaves the same on bash 3.2 (macOS).
    rest=$keywords
    while [ -n "$rest" ]; do
      case "$rest" in
        *,*) kw=${rest%%,*}; rest=${rest#*,} ;;
        *) kw=$rest; rest= ;;
      esac
      kw_norm=$(printf '%s' "$kw" | fm_closed_normalize)
      kw_norm=${kw_norm# }
      kw_norm=${kw_norm% }
      [ -n "$kw_norm" ] || continue
      case "$hay" in
        *" $kw_norm "*)
          printf '%s\t%s\n' "$slug" "$line"
          found=0
          break
          ;;
      esac
    done
  done < "$register"
  return "$found"
}
