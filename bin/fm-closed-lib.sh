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
# The register is the fleet's ONE data/closed.md, and it lives in the MAIN firstmate
# home - gitignored with the rest of data/, because closures are captain-specific
# while the mechanism is shared. A secondmate home keeps no copy of its own (a copy
# drifts, and a stale copy is a closure that silently expires); it reads that one file
# through the main-home pointer it records, and callers resolve the path with
# bin/fm-fleet-home-lib.sh rather than assuming the active home holds it. One entry
# per line:
#
#   - <slug>: <comma-separated keywords>: <one-line why> (closed <date>)
#
# Blank lines and lines whose first non-space character is '#' are comments.
# A line that does not start with "- " is ignored, so a hand-written note in the
# file never becomes a silent gate. A line that DOES start with "- " but is not a
# well-formed entry gates nothing either, and that is exactly why
# fm_closed_malformed reports it: a typo'd closure would otherwise disarm the gate
# while the captain believes the topic is closed, which is a control going quiet at
# the moment it has failed.
#
# An entry is well-formed only when it can actually fire: two ':' separators, a
# non-empty slug, AND a keyword list holding at least one keyword that survives
# normalization. "- topic:: why" and "- topic: ---: why" are each one typo away from
# a real closure and match NOTHING, so they are malformed rather than closures -
# otherwise fm_closed_slugs would list them and bootstrap would positively report a
# topic as closed while the gate covered none of it, which is worse than silence.
# A bullet that is indented ("  - slug: kw: why", a nested markdown list item) is not
# an entry either: fm_closed_match only reads lines starting at column one, so an
# indented bullet closes nothing and is reported instead of skipped.
#
# MATCHING RULE (stated here because a gate whose rule is not written down is a
# gate nobody can predict):
#   1. Both the haystack (task id + the brief minus the regions fm-brief.sh both
#      marked AND opened with a generated heading, see fm_closed_haystack_body) and
#      each keyword are normalized:
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

# fm_closed_entry_valid <line>: 0 when the line is a closure that can actually fire.
# Every consumer asks this one question, so "listed as closed", "not warned about",
# and "able to match" can never disagree about the same line.
fm_closed_entry_valid() {
  local line=$1 slug keywords
  slug=$(fm_closed_entry_field "$line" slug) || return 1
  keywords=$(fm_closed_entry_field "$line" keywords) || return 1
  slug=$(printf '%s' "$slug" | tr -d '[:space:]')
  [ -n "$slug" ] || return 1
  # Normalization turns the separators into spaces too, so an empty result means no
  # individual keyword in the list could ever match either.
  keywords=$(printf '%s' "$keywords" | fm_closed_normalize | tr -d ' ')
  [ -n "$keywords" ] || return 1
  return 0
}

# fm_closed_slugs <register>: print each well-formed entry's slug, one per line.
# Silent (and exit 0) when the register is absent or holds no entries.
fm_closed_slugs() {
  local register=$1 line
  [ -f "$register" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    fm_closed_entry_valid "$line" || continue
    printf '%s\n' "$(fm_closed_entry_field "$line" slug | tr -d '[:space:]')"
  done < "$register"
}

# fm_closed_malformed <register>: print every attempted-bullet line that is NOT a
# well-formed entry, one per line, verbatim. An attempted bullet is any line whose
# first non-space characters are "- ", so an indented bullet is reported too: it
# looks like a closure and closes nothing. Comments, blank lines, and prose that
# does not start a bullet stay silent, because those are notes rather than attempted
# closures. Silent (and exit 0) when the register is absent.
fm_closed_malformed() {
  local register=$1 line trimmed
  [ -f "$register" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$trimmed" in
      '- '*) : ;;
      *) continue ;;
    esac
    fm_closed_entry_valid "$line" && continue
    printf '%s\n' "$line"
  done < "$register"
}

# Explicit machine markers that fm-brief.sh wraps around every block it injects
# into a generated brief. They are HTML comments, so they are invisible in rendered
# markdown, and nobody writes one by hand into a task description.
FM_CLOSED_BOILERPLATE_START='<!-- fm:boilerplate start -->'
FM_CLOSED_BOILERPLATE_END='<!-- fm:boilerplate end -->'

# The openers every block fm-brief.sh injects begins with: the crewmate preamble
# line, and the headings of the generated sections. A marked region is dropped from
# the haystack only when it starts with one of these, so the marker and the text
# have to AGREE before any task content can be lost. Keep in step with fm-brief.sh;
# a heading renamed there and not here keeps MORE text, which is the loud direction.
FM_CLOSED_INJECTED_OPENERS='You are a crewmate:|# Engineering conventions|# Setup|# Rules|# Freshness provenance|# Access and routing|## Fleet access map|# Project memory|# Definition of done'

# fm_closed_marker_status <brief-file>: print "<state> <stripped> <kept>" where state is
#   none        the file carries no boilerplate markers at all
#   ok          every marker is balanced and non-nested; <stripped> counts the regions
#               that also open with an injected heading and are therefore dropped,
#               <kept> counts the marked regions that do not and are therefore kept
#   unbalanced  a start with no end, an end with no start, or a nested start
fm_closed_marker_status() {
  local brief=$1
  if [ ! -f "$brief" ]; then
    printf 'none 0 0\n'
    return 0
  fi
  awk -v s="$FM_CLOSED_BOILERPLATE_START" -v e="$FM_CLOSED_BOILERPLATE_END" \
      -v openers="$FM_CLOSED_INJECTED_OPENERS" '
    function trim(t) { sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t); return t }
    function generated(t,   i, n, o) {
      if (t == "") return 0
      n = split(openers, o, "[|]")
      for (i = 1; i <= n; i++) if (index(t, o[i]) == 1) return 1
      return 0
    }
    {
      line = trim($0)
      if (line == s) { seen++; if (open) bad = 1; open = 1; first = ""; next }
      if (line == e) {
        seen++
        if (!open) bad = 1
        else if (generated(first)) stripped++
        else kept++
        open = 0
        next
      }
      if (open && first == "" && line != "") first = line
    }
    END {
      if (open) bad = 1
      if (!seen) { print "none 0 0"; exit }
      if (bad) { print "unbalanced 0 0"; exit }
      print "ok " stripped + 0 " " kept + 0
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
# A REGION IS DROPPED ONLY WHEN TWO INDEPENDENT SIGNALS AGREE: fm-brief.sh's explicit
# markers wrap it, AND its first non-blank line is one of the openers fm-brief.sh
# generates (FM_CLOSED_INJECTED_OPENERS). Neither signal alone is enough, and the
# history of this gate is why:
#   - heading text alone had an unbounded collision space. A task body is free text,
#     so a task about editing the brief scaffold quotes "# Setup" verbatim, and
#     everything after it stopped being matched: a closure silently covering less
#     than the captain believes, with no signal anywhere.
#   - markers alone left the mirror-image hole. A task that quotes the marker pair in
#     a fenced block - again, ordinary work in THIS repo - had the quoted region
#     silently dropped.
# Requiring agreement means any disagreement between the two keeps MORE text and says
# so out loud, which is the only direction that fails safe.
#
# Narrowing is therefore allowed only where it is CERTAIN, and every uncertain case
# keeps MORE text rather than less:
#   - no markers at all (a hand-written brief, or one generated before markers
#     landed): the WHOLE file is the haystack. There is no heading-text fallback.
#   - unbalanced or nested markers: the WHOLE file is the haystack AND a warning
#     names the brief, because confidence is the precondition for dropping anything.
#   - a marked region that does not open with a generated heading: that region is
#     KEPT and a warning names the brief.
#   - a marker or heading fm-brief.sh stops emitting: MORE text is matched, so the
#     worst case is a false refusal, which is loud, visible to whoever ran the spawn,
#     and undone with one flag.
# Do not "simplify" this back into a heading-text stripper, a marker-only stripper,
# or a task-section extractor.
#
# Set FM_CLOSED_EXPLAIN=1 on a spawn to see the exact haystack this produced and how
# many marked regions it removed.
fm_closed_haystack_body() {
  local brief=$1 status state stripped kept
  [ -f "$brief" ] || return 0
  status=$(fm_closed_marker_status "$brief")
  read -r state stripped kept <<EOF
$status
EOF
  case "$state" in
    ok)
      if [ "${kept:-0}" -gt 0 ]; then
        {
          echo "warning: $brief has $kept fm:boilerplate marked region(s) that do not begin with a"
          echo "  section bin/fm-brief.sh generates, so they cannot be confidently identified as"
          echo "  injected boilerplate. Keeping them in the closed-topic haystack, which may refuse"
          echo "  a spawn that a correctly generated brief would not."
        } >&2
      fi
      awk -v s="$FM_CLOSED_BOILERPLATE_START" -v e="$FM_CLOSED_BOILERPLATE_END" \
          -v openers="$FM_CLOSED_INJECTED_OPENERS" '
        function trim(t) { sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t); return t }
        function generated(t,   i, n, o) {
          if (t == "") return 0
          n = split(openers, o, "[|]")
          for (i = 1; i <= n; i++) if (index(t, o[i]) == 1) return 1
          return 0
        }
        {
          line = trim($0)
          if (line == s) { open = 1; nb = 0; first = ""; buf[nb++] = $0; next }
          if (line == e) {
            buf[nb++] = $0
            if (!generated(first)) for (i = 0; i < nb; i++) print buf[i]
            open = 0
            nb = 0
            next
          }
          if (open) { buf[nb++] = $0; if (first == "" && line != "") first = line; next }
          print
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
    fm_closed_entry_valid "$line" || continue
    slug=$(fm_closed_entry_field "$line" slug | tr -d '[:space:]')
    keywords=$(fm_closed_entry_field "$line" keywords)
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
