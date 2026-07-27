#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree, or a secondmate in
# its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --why <tag>[:<note>] [harness|launch-command] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [harness|launch-command] --secondmate
#   INTAKE GATE 1 - self-initiated work defaults to OFF. Every ship and scout spawn
#   REFUSES unless --why declares why the work exists, with one of exactly three tags:
#   captain (the captain asked), blocks (it blocks something the captain asked for),
#   incident (a live production incident affecting users now). Recorded as why= in the
#   task's meta. "Interesting", "worth doing", "found while looking at X" and "tidy-up"
#   are not reasons to start work, and there is no tag for them. --secondmate is exempt:
#   launching a persistent supervisor is lifecycle, not work.
#   A ship or scout spawn also REFUSES (exit 4) when its brief still carries the
#   scaffold's unreplaced {TASK} placeholder on a line of its own: the brief was never
#   filled in, and an empty task body would leave gate 2 below with nothing to match. A
#   brief that merely mentions the placeholder in prose or a fenced block is unaffected.
#   INTAKE GATE 2 - closed topics refuse at intake. The task id and the brief minus the
#   regions fm-brief.sh both marked as boilerplate and opened with a generated heading are
#   matched against the fleet's data/closed.md (see bin/fm-closed-lib.sh for the register
#   format and the exact matching rule); a match REFUSES and prints the closure line
#   verbatim. The register is fleet-wide and lives in the MAIN firstmate home: a secondmate
#   home reads that one register through the main-home pointer it records at seed time and
#   on every --secondmate launch (bin/fm-fleet-home-lib.sh), never a copy of its own. A
#   secondmate home that cannot resolve it - including a pointer naming something that is
#   not a main firstmate home - has a broken control, not an empty one, so every ship and
#   scout spawn from it WARNS loudly on stderr and proceeds; so does a secondmate home
#   holding its own data/closed.md, which is never read. A register
#   bullet that is not a well-formed entry (no second ':', empty slug, or no usable keyword)
#   closes nothing, and is warned about on stderr rather than skipped silently.
#   FM_CLOSED_EXPLAIN=1 prints the exact haystack the gate matched, how many marked regions
#   were stripped from it, and how many were kept because they were not recognisable.
#   --reopen-closed proceeds anyway, records reopened_closed=<slug> in meta, and prints a
#   loud warning; it exists so the captain can authorise a reopen deliberately. It is a
#   per-task authorisation, so batch dispatch REFUSES it (exit 2) rather than widening one
#   reopen into a blanket bypass for every pair.
#   With no harness arg, the harness comes from fm-harness.sh crew (config/crew-harness,
#   falling back to firstmate's own harness). A bare adapter name (claude|codex|
#   opencode|pi) overrides it for this spawn. A non-flag string containing whitespace
#   is treated as a RAW launch command - the escape hatch for verifying new adapters.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged. The launch
#   also rewrites that home's config/primary-home pointer, so the fleet's one closed-topic
#   register and access map stay reachable from it.
#   Ship/scout spawns refuse to launch after treehouse get unless the resolved pane
#   path is a real git worktree root distinct from the primary project checkout.
#   When config/git-author is present, the launch target (worktree or secondmate home)
#   gets the captain's repo-local user.name/user.email so agent commits attribute to
#   one GitHub account; a conflicting explicitly-set identity field is preserved and
#   reported to stderr (see bin/fm-git-author-lib.sh).
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar --why captain:asked [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout and a shared --why apply to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# Every launch is prefixed with an `env -u` that strips the whole model-selection family
# (ANTHROPIC_MODEL, ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL, ANTHROPIC_SMALL_FAST_MODEL,
# CLAUDE_CODE_SUBAGENT_MODEL) so a stale model pin in the tmux session or pane environment
# cannot leak into the launched agent; the agent resolves its model from its own harness
# config, unless FM_KEEP_MODEL_ENV is set truthy, which skips the strip (see the comment on
# the FM_KEEP_MODEL_ENV case below, which builds that prefix).
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-git-author-lib.sh
. "$SCRIPT_DIR/fm-git-author-lib.sh"
# shellcheck source=bin/fm-closed-lib.sh
. "$SCRIPT_DIR/fm-closed-lib.sh"
# shellcheck source=bin/fm-fleet-home-lib.sh
. "$SCRIPT_DIR/fm-fleet-home-lib.sh"
# The closed-topic register is fleet-wide and lives in the MAIN firstmate home.
# Most crews here are dispatched by secondmates, so a per-home register would have
# left gate 2 enforced where work is not started and inert everywhere it is; a
# secondmate home reads the one register through its recorded pointer instead of
# keeping a copy that would silently drift out of date. A pointer that cannot be
# resolved is a BROKEN control rather than an empty one, so gate 2 below warns
# loudly about it on every ship and scout spawn instead of passing quietly.
CLOSED_UNRESOLVED=
if ! CLOSED=$(fm_fleet_register "$FM_HOME" "$DATA" closed.md); then
  CLOSED_UNRESOLVED=$CLOSED
  CLOSED=
fi
# A closure written into a secondmate home's own data/closed.md is never read. It is
# the easiest mistake to make here (AGENTS.md says to add a closure line without
# naming a home) and the quietest to live with, so it is named rather than skipped.
CLOSED_SHADOW=$(fm_fleet_shadow_register "$FM_HOME" "$DATA" closed.md)
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
WHY=
REOPEN_CLOSED=
POS=()

# INTAKE GATE 1: self-initiated work defaults to OFF.
#
# The rule "do not start work the captain did not ask for" was written down, loaded,
# and broken anyway - on 2026-07-27 roughly two of six crews were on requested work,
# and the rest came from alerts, anomalies and crew observations that read as
# interesting. Prose did not hold. A non-zero exit does, so the declaration of WHY the
# work exists is now an argument the caller cannot omit, and the tag vocabulary has no
# slot for "interesting". Three tags, and only three: if the work fits none of them, it
# does not start.
why_refusal() {
  local reason=$1
  cat >&2 <<'EOF'
error: refusing to spawn - work must declare why it exists.

  --why captain[:<note>]    the captain asked for this
  --why blocks:<what>       it blocks something the captain asked for (name what)
  --why incident[:<note>]   a live production incident affecting users right now

Those are the only three reasons to start work. "Interesting", "worth doing",
"found while looking at X", "we may as well" and "tidy-up" are NOT reasons, and
there is deliberately no tag for them: work with no captain behind it costs the
captain attention they did not agree to spend. If the work fits none of the three
tags, it does not start - queue it in the backlog and let the captain choose.
EOF
  printf 'reason: %s\n' "$reason" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --reopen-closed) REOPEN_CLOSED=1 ;;
    --why)
      if [ $# -lt 2 ]; then
        why_refusal "--why was given with no value"
        exit 2
      fi
      WHY=$2
      shift
      ;;
    --why=*) WHY=${1#--why=} ;;
    *) POS+=("$1") ;;
  esac
  shift
done

# Validate --why here, before the batch split, so a bad batch fails whole rather than
# per pair; the re-exec below forwards the validated value so each pair records it.
WHY_TAG=
WHY_NOTE=
if [ "$KIND" != secondmate ]; then
  case "$WHY" in
    *:*) WHY_TAG=${WHY%%:*}; WHY_NOTE=${WHY#*:} ;;
    *) WHY_TAG=$WHY; WHY_NOTE= ;;
  esac
  WHY_TAG=$(printf '%s' "$WHY_TAG" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  # Collapse the note to a single line: meta is a key=value file, so an embedded
  # newline would forge a meta key.
  WHY_NOTE=$(printf '%s' "$WHY_NOTE" | tr '\n\r' '  ' | sed 's/^ *//; s/ *$//')
  case "$WHY_TAG" in
    captain|blocks|incident) : ;;
    '') why_refusal "no --why was given"; exit 2 ;;
    *) why_refusal "'$WHY_TAG' is not a valid --why tag"; exit 2 ;;
  esac
  if [ "$WHY_TAG" = blocks ] && [ -z "$WHY_NOTE" ]; then
    why_refusal "--why blocks must name what it blocks (--why blocks:<what>)"
    exit 2
  fi
  WHY_RECORD=$WHY_TAG
  [ -n "$WHY_NOTE" ] && WHY_RECORD="$WHY_TAG: $WHY_NOTE"
fi

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  # --reopen-closed is the ONE designed bypass of the closed-topic gate, and it is a
  # per-task authorisation the captain gave for one topic. A shared batch flag would
  # widen that single authorisation into a blanket bypass for every pair, each
  # recording reopened_closed= for whatever it happened to match. The escape hatch
  # stays exactly as narrow as the single-task path: spawn the authorised task alone.
  if [ -n "$REOPEN_CLOSED" ]; then
    {
      echo "error: --reopen-closed is not accepted in batch dispatch."
      echo "Reopening a closed topic is a per-task authorisation from the captain; a shared flag"
      echo "would bypass the closed-topic gate for every pair in the batch. Spawn the authorised"
      echo "task on its own with --reopen-closed, and batch the rest."
    } >&2
    exit 2
  fi
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    fi
    # The shared --why (already validated above) is forwarded to every pair, so each
    # task's meta records its own why=. --reopen-closed is refused above rather than
    # forwarded, so every pair meets the closed-topic gate on its own terms.
    batch_flags=(--why "$WHY_RECORD")
    if [ "$KIND" = scout ]; then batch_flags+=(--scout); fi
    if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${batch_flags[@]}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi -e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Point this home at the ONE main firstmate home whose data/closed.md and
  # data/access.md it must read. Seeding records it; every launch rewrites it, so a
  # home that was moved, re-registered, or seeded before this existed converges here
  # rather than running on with a control it cannot reach. Resolved transitively, so
  # a secondmate that launches another one hands down the same main home rather than
  # starting a chain.
  if sm_fleet_home=$(fm_primary_home "$FM_HOME"); then
    if ! sm_ptr_err=$(fm_write_primary_home_pointer "$PROJ_ABS" "$sm_fleet_home"); then
      echo "warning: secondmate $ID: could not record the main firstmate home: $sm_ptr_err" >&2
    fi
  else
    echo "warning: secondmate $ID: cannot resolve the main firstmate home from $FM_HOME ($sm_fleet_home), so this home's closed-topic register and fleet access map stay unreachable" >&2
  fi
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# INTAKE GATE 2a: an unfilled brief refuses.
#
# The scaffold writes a {TASK} placeholder for firstmate to replace, and AGENTS.md
# says to replace it before spawning - another written rule, so it belongs in a
# refusal rather than in prose. It also matters to the gate below: gate 2's haystack
# is the task id plus the task-specific text, so an unreplaced placeholder presents
# an essentially empty haystack and the one un-talk-past-able gate quietly becomes a
# no-op exactly when the brief is broken. Secondmate charters keep their own handling
# (fm-brief.sh reports a charter that still carries the placeholder).
#
# Matched ONLY where the scaffold leaves it: a line whose entire content is the
# placeholder, never a substring inside prose or a fenced snippet. A task body is
# free text, and in this repo a brief about the brief scaffold legitimately writes
# "replace the {TASK} placeholder" or quotes it in a code block. This refusal has no
# --reopen-closed equivalent and no override at all, so precision IS its whole safety
# margin: an over-broad match here is unrecoverable except by rewording the task.
if [ "$KIND" != secondmate ] && grep -qE '^[[:space:]]*\{TASK\}[[:space:]]*$' "$BRIEF"; then
  {
    echo "error: refusing to spawn $ID - the brief was never filled in."
    echo "  $BRIEF still carries the scaffold's {TASK} placeholder on a line of its own."
    echo
    echo "Fix it by filling in the brief's task section: replace that {TASK} line with the"
    echo "task description, acceptance criteria, and any context the crewmate needs, then"
    echo "spawn again. An unfilled brief also empties the closed-topic gate's haystack, so"
    echo "the closure check would pass without having checked anything."
  } >&2
  exit 4
fi

# INTAKE GATE 2: closed topics refuse at intake.
#
# The captain has closed topics across multiple sessions, and each new session
# reopened them, because a closure recorded only in prose does not survive a context
# reset while the topic itself still looks live. Closure is therefore enforced where
# the work would START, not where it would be reported: by the time a report exists,
# the attention has already been spent. Matched against the task id AND the brief with
# fm-brief.sh's marked boilerplate regions stripped out (see bin/fm-closed-lib.sh
# for the register format and matching rule). Secondmate launches are exempt - they
# carry a charter, not a task.
#
# The register is the fleet's one register in the MAIN firstmate home, resolved above:
# most crews are dispatched by secondmates, so enforcing a per-home copy would enforce
# closures everywhere except where work actually starts.
#
# The stripped regions are the ones fm-brief.sh both wrapped in its fm:boilerplate
# markers AND opened with a generated heading: the conventions, setup, rules, freshness,
# access-routing, fleet-map, project-memory and definition-of-done blocks it injects into
# every brief. Matching those too would let one unlucky keyword refuse every dispatch in
# the fleet; a gate that fails closed on everything is worse than the failure it was built
# to stop. Everything else stays matched - all of a hand-written brief, and every line of a
# task body including its own "# " headings and any marker pair it quotes - and an absent
# marker, an unbalanced marker, or a marked region that does not open with a generated
# heading widens the haystack rather than narrowing it, so the gate can never quietly cover
# less than the captain believes. FM_CLOSED_EXPLAIN=1 shows exactly what was matched.
REOPENED_CLOSED=
# An unresolvable register is not "no closures set": it is the gate having no idea
# what the captain closed, which is exactly the state that must never pass quietly.
# It warns rather than refuses, because failing closed on every dispatch from a
# secondmate home would be its own outage.
if [ "$KIND" != secondmate ] && [ -n "$CLOSED_UNRESOLVED" ]; then
  fm_fleet_register_warning "$FM_HOME" closed.md "$CLOSED_UNRESOLVED"
fi
if [ "$KIND" != secondmate ] && [ -n "$CLOSED_SHADOW" ]; then
  fm_fleet_shadow_warning "$CLOSED_SHADOW" closed.md "$CLOSED"
fi
if [ "$KIND" != secondmate ] && [ -n "$CLOSED" ] && [ -f "$CLOSED" ]; then
  # A "- " line that is not a well-formed entry gates nothing, so say so out loud
  # rather than skipping it: a typo'd closure that fails silently leaves the captain
  # believing a topic is closed when the gate has quietly stopped covering it. It is
  # a warning, not a refusal - an unrelated task must not be blocked by someone
  # else's typo.
  closed_bad=$(fm_closed_malformed "$CLOSED")
  if [ -n "$closed_bad" ]; then
    {
      echo "warning: $CLOSED has line(s) that are NOT well-formed closures, so they close NOTHING:"
      printf '%s\n' "$closed_bad" | sed 's/^/  /'
      echo "expected format: - <slug>: <comma-separated keywords>: <one-line why> (closed <date>)"
    } >&2
  fi
  closed_hay=$(mktemp "${TMPDIR:-/tmp}/fm-closed.XXXXXX")
  { printf '%s\n' "$ID"; fm_closed_haystack_body "$BRIEF"; } > "$closed_hay"
  # Narrowing the haystack is the one place this gate can quietly cover less than the
  # captain believes, so it has to be inspectable rather than merely asserted to be
  # correct: FM_CLOSED_EXPLAIN=1 shows what was dropped and what was actually matched.
  case "${FM_CLOSED_EXPLAIN:-}" in
    ''|0|false|no|off) : ;;
    *)
      closed_markers=$(fm_closed_marker_status "$BRIEF")
      read -r closed_marker_state closed_marker_count closed_marker_kept <<EOF
$closed_markers
EOF
      {
        echo "closed-topic gate: brief $BRIEF"
        echo "closed-topic gate: boilerplate markers: $closed_marker_state, regions stripped: $closed_marker_count, regions kept: $closed_marker_kept"
        echo "closed-topic gate: haystack matched against $CLOSED follows"
        sed 's/^/  | /' "$closed_hay"
      } >&2
      ;;
  esac
  closed_hits=$(fm_closed_match "$CLOSED" "$closed_hay" || true)
  rm -f "$closed_hay"
  if [ -n "$closed_hits" ]; then
    closed_slugs=$(printf '%s\n' "$closed_hits" | cut -f1 | paste -sd, -)
    if [ -n "$REOPEN_CLOSED" ]; then
      REOPENED_CLOSED=$closed_slugs
      {
        echo "!!! WARNING: --reopen-closed is REOPENING a topic the captain closed."
        echo "!!! Closure(s) overridden: $closed_slugs"
        printf '%s\n' "$closed_hits" | cut -f2- | sed 's/^/!!!   /'
        echo "!!! This is only correct if the captain authorised the reopen. Recorded in $STATE/$ID.meta."
      } >&2
    else
      {
        echo "error: refusing to spawn $ID - this topic is CLOSED."
        printf '%s\n' "$closed_hits" | cut -f2- | sed 's/^/  /'
        echo
        echo "The captain closed it; a closure is a decision, not a stale note. Do not"
        echo "re-investigate, re-litigate, or re-raise it. If the captain has explicitly"
        echo "authorised reopening it, pass --reopen-closed (it is recorded in meta);"
        echo "otherwise drop the work. The register is $CLOSED."
      } >&2
      exit 3
    fi
  fi
fi

# Same session when firstmate already runs inside tmux; dedicated session otherwise.
if [ -n "${TMUX:-}" ]; then
  SES=$(tmux display-message -p '#S')
else
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  SES=firstmate
fi

W="fm-$ID"
T="$SES:$W"
if tmux list-windows -t "$SES:" -F '#{window_name}' | grep -qx "$W"; then
  echo "error: window $T already exists" >&2
  exit 1
fi

# Target the session with a trailing colon ("$SES:") so tmux places the new window at
# the session's next free index (honouring base-index). A bare "$SES" is parsed as a
# target-window, so a numeric or auto-named session (the common in-tmux case where
# '#S' is "0") would be read as window index 0 and fail with "index 0 in use" or land
# in the wrong session - the failure under non-default tmux config this guards against.
tmux new-window -d -t "$SES:" -n "$W" -c "$PROJ_ABS"
if [ "$KIND" != secondmate ]; then
  tmux send-keys -t "$T" 'treehouse get' Enter

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  for _ in $(seq 1 60); do
    p=$(tmux display-message -p -t "$T" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$p" ] && [ "$p" != "$PROJ_ABS" ]; then
      WT="$p"
      break
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi

  # Isolation guard: refuse to launch unless WT is a genuine, ISOLATED worktree -
  # a real git worktree root, distinct from the project's primary checkout
  # (PROJ_ABS). Firstmate is a treehouse-pooled repo of itself, so a treehouse-get
  # misfire can leave the pane in (or in a subdir of, or a symlink to) the primary
  # checkout; branching/committing there would tangle the primary onto a feature
  # branch (see fm-tangle-lib.sh). The wait loop above only proves the pane left
  # PROJ_ABS's exact path; this proves it landed in a true, separate worktree.
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=
  if ! proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P); then
    proj_real=
  fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: treehouse get did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect window $T" >&2
    exit 1
  fi
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

mkdir -p "$STATE"
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  else
    # Why this work exists (intake gate 1) and any closure it overrode (gate 2), so the
    # provenance of a task survives the session that dispatched it.
    echo "why=$WHY_RECORD"
    if [ -n "$REOPENED_CLOSED" ]; then echo "reopened_closed=$REOPENED_CLOSED"; fi
  fi
} > "$STATE/$ID.meta"

# Repo-local git identity for this worktree/home from config/git-author, so agent
# commits carry the captain's own GitHub identity instead of the machine default
# (which would make GitHub suggest a Co-authored-by trailer on squash merge; see
# fm-git-author-lib.sh). The command targets $WT - the isolated worktree
# (ship/scout) or the secondmate home fm-spawn launches into; fm-spawn never runs
# it inside a projects/ primary directory. The write still propagates: a
# treehouse worktree's --local config resolves to the pooled clone's shared
# common config, so the effective git identity of that project's checkouts
# changes too - the intended mechanism by which crew commits attribute
# correctly. Per-field, advisory, never global; a conflicting identity is
# preserved and reported to stderr. No-op without the file.
fm_git_author_apply "$WT" "$CONFIG/git-author" report

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi

# Model-pin hygiene, applied to every launch path (ship, scout, secondmate, raw): strip the
# whole model-selection family so the agent resolves its model from its own harness config
# instead of inheriting a stale pin. A tmux pane inherits its session environment, so a pin
# recorded there once (a firstmate session started when an older Opus was current) otherwise
# reaches every agent launched in that session forever, including brand-new crewmates a
# pinned secondmate spawns. ANTHROPIC_MODEL is only the direct form: ANTHROPIC_DEFAULT_*_MODEL
# re-points the very `opus`/`sonnet`/`haiku` aliases this fix falls back on, and
# ANTHROPIC_SMALL_FAST_MODEL and CLAUDE_CODE_SUBAGENT_MODEL redirect the background and
# subagent models the same way, so all of them are stripped together. We unset rather than
# pass an id: claude's "model": "opus" alias already tracks the current Opus, while an id
# pinned in this tracked script would go stale the same way. `env -u` strips them at exec
# time, whatever the pane shell and wherever the values came from (tmux global or session
# environment, pane environment, or fm-spawn's own). A raw launch command must therefore be a
# simple command, as the harness-name scan above assumes - env execs the command word
# directly, so it cannot be a shell alias, function, or builtin, and a compound command
# (`cd /x && agent`) fails in the pane rather than at spawn time. Set FM_KEEP_MODEL_ENV
# truthy to skip the strip where these variables are the real model selection (Bedrock,
# Vertex); it is read from this script's own environment, so set it where every firstmate
# home inherits it - a shell profile or the tmux environment, the same place those model
# variables are set - since a launched pane inherits the tmux session environment rather
# than the environment of the process that ran fm-spawn, and setting it only in one agent's
# own process environment never reaches a secondmate or the crewmates that secondmate spawns.
# The stripped family is Anthropic/Claude-specific: the claude launch was verified live end
# to end under it, and the codex launch was verified live to start correctly under it (codex
# selects its model and auth OpenAI-side, and macOS `ps` exposes no environment for that
# binary, so its evidence is the successful launch rather than an environment read). The
# opencode and pi launches are unverified under the strip.
case "$(printf '%s' "${FM_KEEP_MODEL_ENV-}" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|off) LAUNCH="env -u ANTHROPIC_MODEL -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u ANTHROPIC_SMALL_FAST_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL $LAUNCH" ;;
esac
tmux send-keys -t "$T" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$T" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
