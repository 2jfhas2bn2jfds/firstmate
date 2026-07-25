# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Backlog backend (.tasks.toml / tasks-axi)

The tracked `.tasks.toml` pins the optional `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation; without it, backlog bookkeeping remains manual.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and defines `commands.test` so no-mistakes runs firstmate's bash behavior suite directly.
That command requires `tmux` on `PATH`, prints `tmux -V`, runs every `tests/*.test.sh` with `bash`, and fails if any script exits non-zero.
It intentionally mirrors the behavior-test baseline in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) instead of delegating the test step to an agent.

## Captain preferences (data/captain.md)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` and optional `data/secondmates.md` during bootstrap.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - <project>...` to lease a fresh firstmate worktree for the secondmate home.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses in-flight items or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## Agent commit identity (config/git-author)

Treehouse worktrees are created with no repo-local git identity, so agent commits fall back to git's auto-derived `<user>@<host>.local` author.
On a squash merge GitHub reads that author off the branch commits and appends a `Co-authored-by: <user> <...local>` trailer, because the branch author differs from the merging account; the harness "include co-authored-by" setting cannot suppress it, since the suggestion reads commit author metadata rather than harness config.

To fix this at the source, put the captain's own GitHub identity in the gitignored local file `config/git-author`:

```sh
name=<github username>
email=<id>+<username>@users.noreply.github.com
```

The noreply email attributes commits to the captain's GitHub account without exposing a real address (git requires some email; the noreply form satisfies both).
`bin/fm-spawn.sh` sets this repo-local `user.name`/`user.email` in each crew worktree and secondmate home it launches into, and `bin/fm-bootstrap.sh` keeps the firstmate primary checkout aligned with it, so every agent commit is a single-author commit and GitHub suggests no co-author.
Because a treehouse worktree's repo-local config resolves to the pooled clone's shared common config, the first spawn into a project sets the identity for that whole pool and every checkout of that project inherits it; that shared write is the intended mechanism, even though fm-spawn never runs the command inside a `projects/` primary directory.
The write is repo-local only - never global or system git config - and is applied per field: `user.name` and `user.email` are each set when unset or already matching, so a partial identity self-heals, while a field holding a genuinely-different value is left untouched (spawn and bootstrap both report the skip to stderr).
Known limitation: once a pool's shared config carries an agent identity, a later edit to `config/git-author` is not automatically pushed into already-touched pools; the mismatch is reported on each spawn rather than silently ignored, and is reconciled manually with `git config --local` in that pool when the edit was intentional.
Blind auto-propagation would be unsafe because secondmate homes and firstmate-on-itself worktrees share the firstmate repo's config, whose explicitly-set identity the bootstrap conflict-preserve exists to protect.
The whole feature is a silent no-op when the file is absent (the shared-template default) and emits one stderr warning when the file is present but unparseable.
The file is entirely optional and lives only in this captain's fleet, so it is never committed to the shared template.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).

## Toolchain

On first launch the first mate detects what its required toolchain is missing or too old (tmux, node, gh, treehouse with durable lease support, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi), lists it with the exact install commands, and installs only after you say go.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
If compatible `tasks-axi` is already on `PATH`, bootstrap records it as an optional capability fact and firstmate uses its verbs for routine backlog mutations; when it is absent or incompatible, firstmate keeps hand-editing `data/backlog.md` exactly as before.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
Bootstrap also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms; local-only and no-origin skips stay silent.
Bootstrap also runs the guarded local secondmate sync for recorded live secondmate homes.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable reason, and `NUDGE_SECONDMATES:` only when a running home advanced and its instruction surface changed.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

Bootstrap turns the token into local generated state.
It writes `state/x-watch.check.sh`, a check shim that runs `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher arms in that home.
When the token is removed or empty, the next bootstrap removes those artifacts.
Steady-state off is silent and writes nothing.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate with `x-mention <request_id>`.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts one completion follow-up when the task reaches a terminal state.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-tweet replies.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`.
The follow-up helper clears the link after a successful post or after the 24h window has elapsed; a failed post leaves the link in place so it can be retried.
If the reply exceeds `FMX_X_REPLY_MAX_CHARS`, the client splits it into a numbered, text-only thread on word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_X_THREAD_MAX` defaults to 25 and caps oversized replies, marking the last retained tweet with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 86400 and controls the local completion follow-up window.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the full would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer, follow-up, and dismiss bodies intentionally stay the same shape; the relay distinguishes them by endpoint.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home; unset means this repo root
FM_ROOT_OVERRIDE=        # override firstmate repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merge polls or the X-mode poll shim)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by provably-working watcher triage
FM_KEEP_MODEL_ENV=      # truthy keeps the model-selection env family at agent launch instead of stripping it, for Bedrock/Vertex setups that select the model that way; read from the environment only, never from this home's .env, so set it where every firstmate home inherits it (a shell profile or the tmux environment, the same place those model variables are set), because a launched pane inherits the tmux session environment rather than the environment of the process that ran fm-spawn, so setting it only in one agent's own process environment never reaches a secondmate or the crewmates that secondmate spawns
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-tweet split budget; values below 50 clamp to 50
FMX_X_THREAD_MAX=25     # maximum tweets in one auto-split X reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=86400   # local window for posting one X completion follow-up
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the daemon's present-mode backstop treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that makes watcher and daemon signal/stale/scan output captain-relevant
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working non-terminal stale pane escalates; not-provably-working stale wakes surface immediately
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.'   # busy-pane signatures, shared by watcher and tmux helper
FM_BG_SHELL_REGEX='[0-9]+[[:space:]]+shells?[[:space:]]+still[[:space:]]+running|·[[:space:]]*[0-9]+[[:space:]]+shells?([[:space:]]|$)'   # claude background-shell footer signature; fm-crew-state.sh counts it as working for harness=claude panes
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
# always-on liveness daemon (bin/fm-supervise-daemon.sh); away-mode escalations gated via /afk
FM_SUPERVISOR_TARGET=firstmate:0   # supervisor tmux target (override; auto-discovers from $TMUX_PANE)
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
FM_POKE_AFTER_SECS=120             # present mode: seconds a queued wake may sit stranded before one liveness poke
FM_POKE_MIN_INTERVAL=600           # present mode: hard cap between liveness pokes regardless of new wakes
FM_PRESENT_TICK=5                  # present mode: liveness loop cadence while afk is off
FM_BACKSTOP_ARM_THROTTLE=30        # present mode: min seconds between backstop watcher-arm launches
FM_SECONDMATE_DEADTURN_RE='API Error|ConnectionRefused'   # OR-ed harness dead-turn signatures probed in idle secondmate panes
FM_SECONDMATE_PROBE_TICK=          # seconds between secondmate dead-turn probes; defaults to FM_HOUSEKEEPING_TICK
FM_WATCH_ARM_BIN=bin/fm-watch-arm.sh   # watcher-arm script the present-mode backstop launches, mainly for tests
```
