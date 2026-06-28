#!/usr/bin/env bash
# Shared config resolution for the email notifier (fm-email-notify.sh and
# fm-email-poll.sh). Email mode is the out-of-band notifier sibling of X mode:
# an opt-in, purely additive layer that emails the captain on captain-relevant
# events and surfaces the captain's email replies as check: wakes. It rides the
# EXISTING state/*.check.sh mechanism and the captain-relevant classifier; it
# never edits the watcher backbone.
#
# Opt-in is two signals together (mirroring the AgentMail reference in memory):
#   FM_EMAIL_NOTIFY  truthy      - the explicit opt-in switch
#   AGENTMAIL_API_KEY non-empty  - the AgentMail bearer key (gitignored .env)
#   FM_NOTIFY_EMAIL  non-empty   - the captain's recipient address
#   AGENTMAIL_INBOX  non-empty   - the AgentMail inbox the bot sends from / polls
# Until FM_EMAIL_NOTIFY is truthy every script here is a HARD no-op, so a user who
# never opts in sees zero behavior change. Dry-run (FM_EMAIL_DRY_RUN) lets the
# compose path run with no key and no network, for safe end-to-end testing.
#
# This file is sourced, never executed. It defines:
#   fme_env_get <key> <file>   - read one KEY=VALUE from a .env-style file
#   fme_truthy <value>         - 0 when the value is a truthy opt-in
#   fme_load_config            - resolve FME_KEY/FME_NOTIFY/FME_TO/FME_INBOX/
#                                FME_API_BASE/FME_DRY (env wins over .env)
#   fme_mode_on                - 0 when fully configured (key OR dry-run)
#   fme_auth_header_file       - write the bearer header to a 0600 temp file
#   fme_uri_encode <s>         - percent-encode a string for a URL path segment
# Callers must have FM_HOME set before calling fme_load_config.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fme_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# 0 (truthy) when the value is anything other than unset/empty/0/false/no/off.
# Used for the FM_EMAIL_NOTIFY opt-in switch and FM_EMAIL_DRY_RUN.
fme_truthy() {
  case "$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve the email-mode settings. An explicit environment variable always wins
# over the .env file. FME_API_BASE defaults to the AgentMail production base and
# has any trailing slash trimmed so callers can append "/inboxes/...". FME_NOTIFY
# and FME_DRY are normalized to "1"/"" via fme_truthy.
fme_load_config() {
  local env_file="${FME_ENV_FILE:-$FM_HOME/.env}" raw
  if [ -n "${AGENTMAIL_API_KEY+x}" ]; then FME_KEY=${AGENTMAIL_API_KEY-}; else FME_KEY=$(fme_env_get AGENTMAIL_API_KEY "$env_file"); fi
  if [ -n "${FM_NOTIFY_EMAIL+x}" ]; then FME_TO=${FM_NOTIFY_EMAIL-}; else FME_TO=$(fme_env_get FM_NOTIFY_EMAIL "$env_file"); fi
  if [ -n "${AGENTMAIL_INBOX+x}" ]; then FME_INBOX=${AGENTMAIL_INBOX-}; else FME_INBOX=$(fme_env_get AGENTMAIL_INBOX "$env_file"); fi
  if [ -n "${FM_EMAIL_API_BASE+x}" ]; then FME_API_BASE=${FM_EMAIL_API_BASE-}; else FME_API_BASE=$(fme_env_get FM_EMAIL_API_BASE "$env_file"); fi
  [ -n "$FME_API_BASE" ] || FME_API_BASE="https://api.agentmail.to/v0"
  FME_API_BASE=${FME_API_BASE%/}

  if [ -n "${FM_EMAIL_NOTIFY+x}" ]; then raw=${FM_EMAIL_NOTIFY-}; else raw=$(fme_env_get FM_EMAIL_NOTIFY "$env_file"); fi
  # shellcheck disable=SC2034 # FME_NOTIFY is read by callers after sourcing.
  if fme_truthy "$raw"; then FME_NOTIFY=1; else FME_NOTIFY=""; fi

  if [ -n "${FM_EMAIL_DRY_RUN+x}" ]; then raw=${FM_EMAIL_DRY_RUN-}; else raw=$(fme_env_get FM_EMAIL_DRY_RUN "$env_file"); fi
  # shellcheck disable=SC2034 # FME_DRY is read by callers after sourcing.
  if fme_truthy "$raw"; then FME_DRY=1; else FME_DRY=""; fi
}

# 0 when the live send/poll path is fully configured: a recipient and an inbox,
# plus a key (or dry-run, which needs neither key nor network). Callers that have
# already gated on FME_NOTIFY use this to decide live-vs-noop.
fme_mode_on() {
  [ -n "$FME_TO" ] && [ -n "$FME_INBOX" ] || return 1
  [ -n "$FME_KEY" ] || [ -n "$FME_DRY" ]
}

# Write the bearer header to a private (0600) temp file and echo its path, so the
# key is never passed on a command line where `ps` could read it. Returns
# non-zero if the key contains a newline (which would smuggle a second header).
fme_auth_header_file() {
  local file
  case "$FME_KEY" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-email-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$FME_KEY" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# Percent-encode a string for safe use as a single URL path segment (the inbox
# address has an "@" that must become "%40", and message ids carry "<>@"). Uses
# jq's @uri so encoding is correct and never shells out with the raw value.
fme_uri_encode() {
  jq -rn --arg s "$1" '$s|@uri' 2>/dev/null
}
