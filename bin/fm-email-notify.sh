#!/usr/bin/env bash
# Outbound half of the email notifier: email the captain when a captain-relevant
# event turns up. Modeled on X mode (bin/fm-x-*.sh): purely additive, opt-in, and
# riding the EXISTING watcher check mechanism rather than editing the backbone.
#
# This is the silent side-effect body of the generated check shim
# state/email-watch.check.sh: the watcher runs it each check cycle, it sends any
# pending notifications, and it prints NOTHING (so it never adds a spurious wake -
# the underlying status already wakes firstmate through the normal signal path).
#
# It scans state/*.status with the SAME captain-relevant classifier the watcher
# uses (bin/fm-classify-lib.sh, scan_captain_relevant_statuses), and for each
# status whose last captain-relevant line it has not already emailed it sends one
# concise, plain-language email via AgentMail. Dedupe is per task: the last line
# emailed for a task is recorded in state/.email-seen-<task>, so the same event is
# never emailed twice and a settled line is not re-sent every cycle.
#
# Inert by default: a HARD no-op (exit 0, no output) unless FM_EMAIL_NOTIFY is
# truthy AND a recipient/inbox (and a key, unless dry-run) are configured. Email
# text is composed in plain outcome language (no task ids or internal vocabulary,
# mirroring AGENTS.md section 9). Status-line text is crewmate-authored and is
# treated as untrusted: it is only ever passed to jq via --arg, never inlined
# into a shell command.
#
# Config (home .env, FME_ENV_FILE, or env): FM_EMAIL_NOTIFY (opt-in),
# AGENTMAIL_API_KEY, FM_NOTIFY_EMAIL (recipient), AGENTMAIL_INBOX (send-from),
# FM_EMAIL_API_BASE (default https://api.agentmail.to/v0), FM_EMAIL_DRY_RUN.
# Dry-run records the would-be message to state/email-outbox/<task>.json instead
# of sending, and needs neither a key nor the network.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-email-lib.sh
. "$SCRIPT_DIR/fm-email-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

fme_load_config
# Hard no-op when email mode is off: this keeps the check shim inert.
fme_truthy "$FME_NOTIFY" || exit 0
# Opted in but not fully configured: the outbound side cannot surface an error
# (it must stay silent), so just no-op; the poll side reports config problems.
fme_mode_on || exit 0
command -v jq >/dev/null 2>&1 || exit 0

[ -d "$STATE" ] || exit 0

# Map a captain-relevant status line to a plain-language subject category and a
# human detail (the line with its leading "verb:" stripped). No task ids, no
# internal vocabulary - outcomes only (AGENTS.md section 9).
classify_subject() {  # <line>
  case "$1" in
    needs-decision:*) printf 'A decision is needed' ;;
    blocked:*)        printf 'Work is blocked' ;;
    failed:*)         printf 'Work did not pan out' ;;
    *)                printf 'Update on your projects' ;;
  esac
}

strip_verb() {  # <line> -> detail without a leading "<verb>: "
  local line=$1
  case "$line" in
    needs-decision:*|blocked:*|failed:*|done:*) printf '%s' "${line#*: }" ;;
    *) printf '%s' "$line" ;;
  esac
}

# Best-effort project label for a task, from state/<task>.meta project=. Returns
# empty when unknown; the basename keeps it a plain project name, never a path.
project_label() {  # <task>
  local meta=$1 line val
  meta="$STATE/$meta.meta"
  [ -f "$meta" ] || return 0
  line=$(grep -E '^project=' "$meta" 2>/dev/null | tail -n1) || return 0
  val=${line#project=}
  val=${val##*/}
  printf '%s' "$val"
}

seen_path() {  # <task>
  printf '%s/.email-seen-%s' "$STATE" "$1"
}

# Send (or, in dry-run, record) one notification email. Returns 0 only when the
# message was accepted, so the caller advances the dedupe marker exactly once the
# event has actually gone out.
send_email() {  # <to> <subject> <text> <task>
  local to=$1 subject=$2 text=$3 task=$4 payload enc code auth

  payload=$(jq -nc --arg to "$to" --arg subject "$subject" --arg text "$text" \
    '{to:$to, subject:$subject, text:$text}') || return 1

  if [ -n "$FME_DRY" ]; then
    local outbox_dir="$STATE/email-outbox" outbox_file
    outbox_file="$outbox_dir/$task.json"
    mkdir -p "$outbox_dir" 2>/dev/null || return 1
    printf '%s\n' "$payload" > "$outbox_file" 2>/dev/null || return 1
    printf 'fm-email-notify: DRY RUN - would email %s: %s\n' "$to" "$subject" >&2
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 1
  enc=$(fme_uri_encode "$FME_INBOX") || return 1
  [ -n "$enc" ] || return 1
  auth=$(fme_auth_header_file) || return 1

  code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "@$auth" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$FME_API_BASE/inboxes/$enc/messages/send" 2>/dev/null) || { rm -f "$auth"; return 1; }
  rm -f "$auth"

  case "$code" in
    2[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# One pass over the fleet's captain-relevant statuses.
while IFS=$(printf '\t') read -r _ task last; do
  [ -n "$task" ] || continue
  # Per-task dedupe: skip when this exact line has already been emailed.
  prev=$(cat "$(seen_path "$task")" 2>/dev/null || true)
  [ "$prev" = "$last" ] && continue

  subject=$(classify_subject "$last")
  detail=$(strip_verb "$last")
  project=$(project_label "$task")

  if [ -n "$project" ]; then
    subject="firstmate: $subject ($project)"
    body=$(printf '%s\n\nProject: %s\n\nReply to this email to steer firstmate.\n' "$detail" "$project")
  else
    subject="firstmate: $subject"
    body=$(printf '%s\n\nReply to this email to steer firstmate.\n' "$detail")
  fi

  if send_email "$FME_TO" "$subject" "$body" "$task"; then
    # Advance the dedupe marker only after the event has gone out, so a failed
    # send is retried on the next cycle instead of being silently dropped.
    printf '%s' "$last" > "$(seen_path "$task")" 2>/dev/null || true
  fi
done < <(scan_captain_relevant_statuses "$STATE")

exit 0
