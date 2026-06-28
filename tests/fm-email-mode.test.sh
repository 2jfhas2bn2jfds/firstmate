#!/usr/bin/env bash
# Behavior tests for email mode: the outbound notifier (fm-email-notify.sh), the
# inbound inbox poll (fm-email-poll.sh), and bootstrap's .env-presence activation.
#
# Email mode must be INERT by default (no opt-in -> both scripts are hard no-ops
# and bootstrap writes/prints nothing) and additive when on (a single check shim +
# a 60s cadence config, both idempotent). The AgentMail HTTP layer is stubbed with
# a fakebin `curl` so these stay hermetic: no ports, no server, no real key,
# deterministic in CI. jq stays the real tool. The classify->compose path is also
# exercised keylessly via the dry-run preview, and the inbound-parse path via the
# fake curl serving canned list/message JSON.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-email-mode-tests)

# A fakebin `curl` that mimics AgentMail: it reads its behavior from env
# (FAKE_LIST_CODE/FAKE_LIST_BODY for GET .../messages, FAKE_MSG_BODY for GET a
# single message, FAKE_SEND_CODE for POST .../messages/send), records each call to
# FAKE_CURL_LOG (with the auth header, url, method, and posted data), writes the
# response body to the script's -o file, and prints the HTTP code to stdout
# exactly as the real `-w '%{http_code}'` would.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */messages/send)
    printf '%s' "${FAKE_SEND_CODE:-200}"
    ;;
  */messages/*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_MSG_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_MSG_CODE:-200}"
    ;;
  */messages)
    [ -n "$ofile" ] && printf '%s' "${FAKE_LIST_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_LIST_CODE:-200}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Common live-mode env for the configured-on path.
email_on_env() {
  printf 'FM_EMAIL_NOTIFY=1\nAGENTMAIL_API_KEY=key-abc\nFM_NOTIFY_EMAIL=cap@example.com\nAGENTMAIL_INBOX=d-8274@agentmail.to\n'
}

# ---------------------------------------------------------------------------
# Outbound notifier
# ---------------------------------------------------------------------------

test_notify_no_optin_is_hard_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/notify-noop"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  printf 'needs-decision: pick a db\n' > "$home/state/t1.status"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-email-notify.sh"); rc=$?
  expect_code 0 "$rc" "notify no-optin exit"
  [ -z "$out" ] || fail "notify no-optin must be silent (got: $out)"
  assert_absent "$home/state/email-outbox" "notify no-optin must not write an outbox"
  pass "fm-email-notify is a hard no-op without opt-in (inert default)"
}

test_notify_dry_run_composes_keyless() {
  local home out body
  home="$TMP_ROOT/notify-dry"; mkdir -p "$home/state"
  # No key, no curl on PATH: dry-run must compose purely from jq.
  printf 'needs-decision: Clerk vs custom auth\n' > "$home/state/fix-login.status"
  printf 'project=projects/yourapp\nkind=ship\n' > "$home/state/fix-login.meta"
  out=$(PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" 2>&1)
  assert_contains "$out" "DRY RUN" "dry-run prints a preview"
  assert_present "$home/state/email-outbox/fix-login.json" "dry-run records the outbox"
  body=$(cat "$home/state/email-outbox/fix-login.json")
  assert_contains "$body" '"to":"cap@example.com"' "outbox carries the recipient"
  assert_contains "$body" "A decision is needed" "subject is plain-language for needs-decision"
  assert_contains "$body" "yourapp" "body carries the project label"
  assert_contains "$body" "Clerk vs custom auth" "body carries the detail"
  assert_not_contains "$body" "fix-login" "no task id leaks into the email"
  pass "fm-email-notify dry-run composes a plain-language email with no key or network"
}

test_notify_dedupe_same_event() {
  local home out
  home="$TMP_ROOT/notify-dedupe"; mkdir -p "$home/state"
  printf 'blocked: needs staging credentials\n' > "$home/state/job.status"
  PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" >/dev/null 2>&1
  assert_present "$home/state/.email-seen-job" "first send advances the dedupe marker"
  out=$(PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" 2>&1)
  [ -z "$out" ] || fail "second run on the same event must be silent (got: $out)"
  pass "fm-email-notify dedupes the same event"
}

test_notify_new_line_after_marker_resends() {
  local home out
  home="$TMP_ROOT/notify-resend"; mkdir -p "$home/state"
  printf 'blocked: waiting on creds\n' > "$home/state/job.status"
  PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" >/dev/null 2>&1
  # A new captain-relevant line appears -> a fresh notification.
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' >> "$home/state/job.status"
  out=$(PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" 2>&1)
  assert_contains "$out" "DRY RUN" "a new captain-relevant line re-notifies"
  assert_contains "$(cat "$home/state/email-outbox/job.json")" "Update on your projects" "done maps to an update subject"
  pass "fm-email-notify re-notifies on a new captain-relevant line"
}

test_notify_ignores_non_captain_relevant() {
  local home out
  home="$TMP_ROOT/notify-irrelevant"; mkdir -p "$home/state"
  printf 'working: still compiling\n' > "$home/state/t.status"
  out=$(PATH="$JQ_DIR:/usr/bin:/bin" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    FM_NOTIFY_EMAIL=cap@example.com AGENTMAIL_INBOX=d-8274@agentmail.to \
    FM_EMAIL_DRY_RUN=1 "$ROOT/bin/fm-email-notify.sh" 2>&1)
  [ -z "$out" ] || fail "a non-captain-relevant status must not email (got: $out)"
  assert_absent "$home/state/email-outbox" "no outbox for a non-captain-relevant status"
  pass "fm-email-notify ignores non-captain-relevant statuses"
}

test_notify_live_posts_to_send_endpoint() {
  local home fakebin log out
  home="$TMP_ROOT/notify-live"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  email_on_env > "$home/.env"
  printf 'failed: the migration could not complete\n' > "$home/state/mig.status"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_CURL_LOG="$log" FAKE_SEND_CODE=200 \
    "$ROOT/bin/fm-email-notify.sh");
  [ -z "$out" ] || fail "live notify must be silent on stdout (got: $out)"
  assert_grep "method=POST" "$log" "notify POSTs the email"
  assert_grep "/inboxes/d-8274%40agentmail.to/messages/send" "$log" "notify hits the send endpoint with an encoded inbox"
  assert_grep "auth=Authorization: Bearer key-abc" "$log" "notify sends the bearer key"
  assert_grep "Work did not pan out" "$log" "failed maps to a plain-language subject"
  if grep '^argv=' "$log" | grep -F 'key-abc' >/dev/null 2>&1; then
    fail "the key must never appear on curl's argv"
  fi
  assert_present "$home/state/.email-seen-mig" "a successful send advances the marker"
  pass "fm-email-notify live-posts to the AgentMail send endpoint with the bearer key off-argv"
}

test_notify_failed_send_does_not_advance_marker() {
  local home fakebin
  home="$TMP_ROOT/notify-fail"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  printf 'needs-decision: which region\n' > "$home/state/region.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_SEND_CODE=500 \
    "$ROOT/bin/fm-email-notify.sh" >/dev/null 2>&1
  assert_absent "$home/state/.email-seen-region" "a failed send must not advance the dedupe marker (so it retries)"
  pass "fm-email-notify retries after a failed send (marker not advanced)"
}

# ---------------------------------------------------------------------------
# Inbound poll
# ---------------------------------------------------------------------------

test_poll_no_optin_is_hard_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-email-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-optin exit"
  [ -z "$out" ] || fail "poll no-optin must be silent (got: $out)"
  assert_absent "$home/state/email-inbox" "poll no-optin must not create an inbox"
  pass "fm-email-poll is a hard no-op without opt-in (inert default)"
}

test_poll_incomplete_config_reports_once() {
  local home fakebin out
  home="$TMP_ROOT/poll-incomplete"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  # Opted in but no key/recipient/inbox.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    "$ROOT/bin/fm-email-poll.sh")
  assert_contains "$out" "email-mode-error" "incomplete config surfaces a config error"
  # Deduped on the next poll with the same error.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_EMAIL_NOTIFY=1 \
    "$ROOT/bin/fm-email-poll.sh")
  [ -z "$out" ] || fail "a repeated identical config error must be deduped (got: $out)"
  pass "fm-email-poll reports incomplete config once"
}

test_poll_baseline_then_new_reply() {
  local home fakebin out list list2 msg safe
  home="$TMP_ROOT/poll-baseline"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  list='{"messages":[{"message_id":"<m1@x>","from":"Captain <cap@example.com>","subject":"hi","preview":"old"},{"message_id":"n2","from":"noreply@other.com","subject":"x","preview":"y"}]}'
  # First poll: baseline every current id, surface nothing.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list" \
    "$ROOT/bin/fm-email-poll.sh")
  [ -z "$out" ] || fail "first poll must baseline silently (got: $out)"
  assert_grep "<m1@x>" "$home/state/.email-poll-seen" "baseline records existing ids"
  assert_absent "$home/state/email-inbox" "baseline surfaces nothing"

  # Second poll: a new reply from the captain arrives.
  list2='{"messages":[{"message_id":"<m1@x>","from":"Captain <cap@example.com>","subject":"hi","preview":"old"},{"message_id":"n2","from":"noreply@other.com","subject":"x","preview":"y"},{"message_id":"<m3@x>","from":"cap@example.com","subject":"Re: blocked","preview":"use staging"}]}'
  msg='{"message_id":"<m3@x>","from":"cap@example.com","subject":"Re: blocked","text":"Use the staging db for now.","preview":"use staging"}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list2" FAKE_MSG_BODY="$msg" \
    "$ROOT/bin/fm-email-poll.sh")
  assert_contains "$out" "email-reply " "a new captain reply produces a wake"
  safe=$(printf '%s' "$out" | sed -n 's/^email-reply //p' | head -1)
  assert_present "$home/state/email-inbox/$safe.json" "the new reply is stashed"
  assert_grep "Use the staging db for now." "$home/state/email-inbox/$safe.json" "full text is fetched and stashed as the payload"
  pass "fm-email-poll baselines on first run, then surfaces a new captain reply with full text"
}

test_poll_ignores_non_captain_sender() {
  local home fakebin out list
  home="$TMP_ROOT/poll-nonsender"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  # Baseline empty so any new message would surface if not filtered.
  printf '' > "$home/state/.email-poll-seen"
  list='{"messages":[{"message_id":"s1","from":"stranger@evil.com","subject":"spam","preview":"buy"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list" \
    "$ROOT/bin/fm-email-poll.sh")
  [ -z "$out" ] || fail "a message from a non-captain sender must not surface (got: $out)"
  assert_absent "$home/state/email-inbox" "no inbox stash for a non-captain sender"
  pass "fm-email-poll only surfaces replies from the captain's address"
}

test_poll_dedupes_seen_reply() {
  local home fakebin out list msg
  home="$TMP_ROOT/poll-dedupe"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  printf '' > "$home/state/.email-poll-seen"
  list='{"messages":[{"message_id":"r9","from":"cap@example.com","subject":"Re","preview":"ok"}]}'
  msg='{"message_id":"r9","from":"cap@example.com","subject":"Re","text":"ok do it","preview":"ok"}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list" FAKE_MSG_BODY="$msg" \
    "$ROOT/bin/fm-email-poll.sh")
  assert_contains "$out" "email-reply r9" "first sighting surfaces"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list" FAKE_MSG_BODY="$msg" \
    "$ROOT/bin/fm-email-poll.sh")
  [ -z "$out" ] || fail "an already-seen reply must not surface again (got: $out)"
  pass "fm-email-poll dedupes an already-surfaced reply"
}

test_poll_sanitizes_unsafe_message_id() {
  local home fakebin out list msg safe
  home="$TMP_ROOT/poll-unsafe"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  printf '' > "$home/state/.email-poll-seen"
  list='{"messages":[{"message_id":"../../etc/passwd","from":"cap@example.com","subject":"x","preview":"p"}]}'
  msg='{"message_id":"../../etc/passwd","from":"cap@example.com","subject":"x","text":"hi","preview":"p"}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_BODY="$list" FAKE_MSG_BODY="$msg" \
    "$ROOT/bin/fm-email-poll.sh")
  safe=$(printf '%s' "$out" | sed -n 's/^email-reply //p' | head -1)
  # A flat slug (no slash, and never exactly "." or "..") cannot traverse.
  case "$safe" in
    */*|.|..) fail "the stash slug must be a flat, non-traversing filename (got: $safe)" ;;
  esac
  assert_present "$home/state/email-inbox/$safe.json" "the sanitized stash lands inside the inbox dir"
  assert_absent "$home/state/email-inbox/../../etc/passwd" "no traversal write happened"
  pass "fm-email-poll sanitizes an unsafe message id into a safe slug"
}

test_poll_204_is_silent() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-204"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_CODE=204 \
    "$ROOT/bin/fm-email-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll 204 exit"
  [ -z "$out" ] || fail "poll 204 must be silent (got: $out)"
  pass "fm-email-poll is silent on HTTP 204"
}

test_poll_auth_error_reports_once() {
  local home fakebin out
  home="$TMP_ROOT/poll-auth"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  email_on_env > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_CODE=401 \
    "$ROOT/bin/fm-email-poll.sh")
  assert_contains "$out" "email-mode-error relay returned HTTP 401" "auth error surfaces"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_LIST_CODE=401 \
    "$ROOT/bin/fm-email-poll.sh")
  [ -z "$out" ] || fail "a repeated identical auth error must be deduped (got: $out)"
  pass "fm-email-poll reports an auth error once"
}

# ---------------------------------------------------------------------------
# Bootstrap activation
# ---------------------------------------------------------------------------

run_bootstrap() {  # <home> -> stdout; PATH has the tools bootstrap needs
  local home=$1; shift
  PATH="$JQ_DIR:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$@" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_inert_without_optin() {
  local home out
  home="$TMP_ROOT/bs-inert"; mkdir -p "$home"
  out=$(run_bootstrap "$home")
  assert_not_contains "$out" "FME:" "no FME line without opt-in"
  assert_absent "$home/state/email-watch.check.sh" "no shim without opt-in"
  assert_absent "$home/config/email-mode.env" "no cadence without opt-in"
  pass "bootstrap is inert for email mode without opt-in"
}

test_bootstrap_activates_on_full_config() {
  local home out
  home="$TMP_ROOT/bs-on"; mkdir -p "$home"
  email_on_env > "$home/.env"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "FME: email mode on" "bootstrap announces email mode on"
  assert_present "$home/state/email-watch.check.sh" "bootstrap writes the check shim"
  assert_present "$home/config/email-mode.env" "bootstrap writes the cadence config"
  assert_grep "FM_CHECK_INTERVAL=60" "$home/config/email-mode.env" "cadence is 60s"
  assert_grep "fm-email-notify.sh" "$home/state/email-watch.check.sh" "shim runs the outbound notifier"
  assert_grep "fm-email-poll.sh" "$home/state/email-watch.check.sh" "shim runs the inbound poll"
  # Idempotent re-run.
  run_bootstrap "$home" >/dev/null
  assert_present "$home/state/email-watch.check.sh" "shim survives a re-run"
  pass "bootstrap activates email mode on full .env config (idempotently)"
}

test_bootstrap_optin_missing_config_reports_off() {
  local home out
  home="$TMP_ROOT/bs-missing"; mkdir -p "$home"
  printf 'FM_EMAIL_NOTIFY=1\n' > "$home/.env"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "FME: email mode off" "opted in but missing config reports off"
  assert_absent "$home/state/email-watch.check.sh" "no shim when config is incomplete"
  pass "bootstrap reports off when opted in but missing required config"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/bs-optout"; mkdir -p "$home/state" "$home/config"
  # Pretend a prior activation left artifacts.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/email-watch.check.sh"
  printf 'export FM_CHECK_INTERVAL=60\n' > "$home/config/email-mode.env"
  # No .env / no opt-in now.
  out=$(run_bootstrap "$home")
  assert_contains "$out" "FME: email mode off - removed" "opt-out reports cleanup"
  assert_absent "$home/state/email-watch.check.sh" "opt-out removes the shim"
  assert_absent "$home/config/email-mode.env" "opt-out removes the cadence"
  pass "bootstrap cleans up email artifacts on opt-out"
}

# ---------------------------------------------------------------------------

test_notify_no_optin_is_hard_noop
test_notify_dry_run_composes_keyless
test_notify_dedupe_same_event
test_notify_new_line_after_marker_resends
test_notify_ignores_non_captain_relevant
test_notify_live_posts_to_send_endpoint
test_notify_failed_send_does_not_advance_marker
test_poll_no_optin_is_hard_noop
test_poll_incomplete_config_reports_once
test_poll_baseline_then_new_reply
test_poll_ignores_non_captain_sender
test_poll_dedupes_seen_reply
test_poll_sanitizes_unsafe_message_id
test_poll_204_is_silent
test_poll_auth_error_reports_once
test_bootstrap_inert_without_optin
test_bootstrap_activates_on_full_config
test_bootstrap_optin_missing_config_reports_off
test_bootstrap_opt_out_cleanup
