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
#   1. Both the haystack (task id + task-specific brief text) and each keyword are normalized:
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

# fm_closed_task_section <brief-file>: print the TASK-SPECIFIC body of a brief -
# everything between its "# Task" heading and the next level-1 heading.
#
# The haystack must never include the boilerplate fm-brief.sh injects into every
# ship and scout brief: the engineering conventions, the freshness block and its
# list of live-state examples, the access-and-routing rules, and the whole of
# data/access.md with every connector name in it. A closure keyword landing in any
# of that would match EVERY brief and refuse EVERY dispatch, and a gate that
# refuses everything is worse than the problem it solves.
#
# A brief with no "# Task" heading is hand-written, so it carries no injected
# boilerplate and the whole file is the task: fall back to it rather than matching
# nothing, which would silently ungate hand-written briefs.
fm_closed_task_section() {
  local brief=$1
  [ -f "$brief" ] || return 0
  awk '
    /^# Task[[:space:]]*$/ && !seen { seen = 1; intask = 1; next }
    /^# / { intask = 0 }
    intask { print }
    END { if (!seen) exit 1 }
  ' "$brief" || cat "$brief"
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
