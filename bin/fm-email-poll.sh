#!/usr/bin/env bash
# Inbound half of the email notifier: poll the AgentMail inbox for the captain's
# replies and surface each new one as a check: wake so it can steer firstmate.
# The two-way sibling of X mode's fm-x-poll.sh, riding the EXISTING watcher check
# mechanism (state/*.check.sh) with no backbone edits.
#
# Inert by default: a HARD no-op (exit 0, no output) unless FM_EMAIL_NOTIFY is
# truthy. This script is the wake-producing tail of the generated check shim
# state/email-watch.check.sh, where the contract is "output => wake firstmate,
# silence => keep sleeping".
#
# Behavior when email mode is on:
#   missing curl/jq, bad config, or relay auth error -> one rate-limited
#       "email-mode-error <msg>" line (a captain-visible check: wake)
#   HTTP 204 / empty / no new captain replies               -> print nothing, exit 0
#   first ever poll (no seen file)                          -> baseline every
#       current message id as seen and print nothing, so enabling email mode never
#       floods the captain's existing inbox; only mail arriving AFTER opt-in surfaces
#   a new message FROM the captain (FM_NOTIFY_EMAIL)        -> stash the message
#       object (with full text fetched best-effort) to state/email-inbox/<safe>.json
#       and print "email-reply <safe>"
# The captain's reply text is kept as the stashed payload; firstmate drains
# state/email-inbox/ as the source of truth (mirroring fmx-respond and x-inbox).
#
# Email content (subject/body/from) is untrusted public-ish input: it is only ever
# parsed by jq from a file, never inlined into a shell command, and the message id
# is sanitized before it becomes a filename.
#
# Config (home .env, FME_ENV_FILE, or env): FM_EMAIL_NOTIFY (opt-in),
# AGENTMAIL_API_KEY, FM_NOTIFY_EMAIL (the captain's address, used as the
# from-captain filter), AGENTMAIL_INBOX (the inbox to poll), FM_EMAIL_API_BASE
# (default https://api.agentmail.to/v0).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-email-lib.sh
. "$SCRIPT_DIR/fm-email-lib.sh"

fme_load_config
# Hard no-op when email mode is off.
fme_truthy "$FME_NOTIFY" || exit 0

ERROR_FILE="$STATE/email-poll.error"
SEEN_FILE="$STATE/.email-poll-seen"
INBOX="$STATE/email-inbox"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'email-mode-error %s\n' "$msg"
}

clear_error() { rm -f "$ERROR_FILE" 2>/dev/null || true; }

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

# Opted in but not fully configured.
if [ -z "$FME_KEY" ] || [ -z "$FME_TO" ] || [ -z "$FME_INBOX" ]; then
  emit_error_once "email mode not fully configured (need AGENTMAIL_API_KEY, FM_NOTIFY_EMAIL, AGENTMAIL_INBOX)"
  exit 0
fi

INBOX_ENC=$(fme_uri_encode "$FME_INBOX")
[ -n "$INBOX_ENC" ] || { emit_error_once "invalid AGENTMAIL_INBOX"; exit 0; }

AUTH_HEADER_FILE=$(fme_auth_header_file) || { emit_error_once "invalid AGENTMAIL_API_KEY"; exit 0; }
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-email-poll.XXXXXX") || { rm -f "$AUTH_HEADER_FILE"; exit 0; }
trap 'rm -f "$BODY_FILE" "$AUTH_HEADER_FILE"' EXIT

# Short, bounded poll: a failure or timeout just means "no wake this cycle".
code=$(curl -m 5 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Accept: application/json' \
  "$FME_API_BASE/inboxes/$INBOX_ENC/messages" 2>/dev/null) || exit 0

case "$code" in
  200) ;;
  204) clear_error; exit 0 ;;
  400|401|403|404) emit_error_once "relay returned HTTP $code"; exit 0 ;;
  *) exit 0 ;;
esac
[ -s "$BODY_FILE" ] || { clear_error; exit 0; }

# All current message ids (any sender) - used both for the first-run baseline and,
# below, to dedupe. A malformed body yields nothing and we treat it as "no mail".
ALL_IDS=$(jq -r '(.messages // [])[]? | (.message_id // empty)' "$BODY_FILE" 2>/dev/null) || { clear_error; exit 0; }

mkdir -p "$STATE" 2>/dev/null || { emit_error_once "cannot create state dir"; exit 0; }

# First ever poll: baseline every current id as already-seen and surface nothing,
# so enabling email mode never replays the inbox's pre-existing mail.
if [ ! -f "$SEEN_FILE" ]; then
  printf '%s\n' "$ALL_IDS" | grep -v '^[[:space:]]*$' > "$SEEN_FILE" 2>/dev/null || true
  clear_error
  exit 0
fi

# Candidate ids: messages FROM the captain (case-insensitive substring of the
# from header, which may be "Name <addr>"). jq does the filtering so the untrusted
# from/subject text never reaches the shell.
CAP_LC=$(printf '%s' "$FME_TO" | tr '[:upper:]' '[:lower:]')
CANDIDATES=$(jq -r --arg cap "$CAP_LC" '
  (.messages // [])[]?
  | select(((.from // "") | ascii_downcase) | contains($cap))
  | (.message_id // empty)
' "$BODY_FILE" 2>/dev/null) || { clear_error; exit 0; }

emitted=0
while IFS= read -r mid; do
  [ -n "$mid" ] || continue
  case "$mid" in *[[:space:]]*) continue ;; esac          # ignore malformed ids
  grep -Fxq -- "$mid" "$SEEN_FILE" 2>/dev/null && continue  # already surfaced

  # Sanitize the relay-issued id into a safe filename slug; keep a cksum suffix
  # when sanitizing changed it so distinct ids never collide.
  safe=$(printf '%s' "$mid" | tr -c 'A-Za-z0-9._-' '_')
  if [ -z "$safe" ] || [ "$safe" != "$mid" ]; then
    safe="${safe:0:80}-$(printf '%s' "$mid" | cksum | cut -d' ' -f1)"
  fi

  # The list endpoint carries only a preview; fetch the full message text
  # best-effort so the captain's whole reply is the payload, falling back to the
  # preview if the per-message fetch fails.
  mid_enc=$(fme_uri_encode "$mid")
  full_text=
  if [ -n "$mid_enc" ]; then
    msg_file=$(mktemp "${TMPDIR:-/tmp}/fm-email-msg.XXXXXX") || msg_file=
    if [ -n "$msg_file" ]; then
      mcode=$(curl -m 5 -s -o "$msg_file" -w '%{http_code}' \
        -H "@$AUTH_HEADER_FILE" -H 'Accept: application/json' \
        "$FME_API_BASE/inboxes/$INBOX_ENC/messages/$mid_enc" 2>/dev/null) || mcode=
      case "$mcode" in
        200) full_text=$(jq -r '(.text // empty)' "$msg_file" 2>/dev/null) || full_text= ;;
      esac
      rm -f "$msg_file"
    fi
  fi

  # Stash the message object, folding in the fetched full text when we got one
  # (otherwise the list object keeps its preview). Written atomically so a
  # concurrent reader never sees a half-written file.
  mkdir -p "$INBOX" 2>/dev/null || { emit_error_once "cannot create inbox"; break; }
  if jq --arg id "$mid" --arg ft "$full_text" '
        (.messages // [])[] | select((.message_id // "") == $id)
        | . + (if ($ft | length) > 0 then {text:$ft} else {} end)
      ' "$BODY_FILE" > "$INBOX/$safe.json.tmp" 2>/dev/null \
     && [ -s "$INBOX/$safe.json.tmp" ] \
     && mv -f "$INBOX/$safe.json.tmp" "$INBOX/$safe.json" 2>/dev/null; then
    printf '%s\n' "$mid" >> "$SEEN_FILE" 2>/dev/null || true
    printf 'email-reply %s\n' "$safe"
    emitted=$((emitted + 1))
  else
    rm -f "$INBOX/$safe.json.tmp" 2>/dev/null || true
    emit_error_once "cannot write inbox"
    break
  fi
done <<EOF
$CANDIDATES
EOF

# Bound the seen file's growth without losing recent ids.
if [ -f "$SEEN_FILE" ]; then
  tail -n 2000 "$SEEN_FILE" > "$SEEN_FILE.tmp" 2>/dev/null && mv -f "$SEEN_FILE.tmp" "$SEEN_FILE" 2>/dev/null || rm -f "$SEEN_FILE.tmp" 2>/dev/null || true
fi

[ "$emitted" -gt 0 ] && exit 0
clear_error
exit 0
