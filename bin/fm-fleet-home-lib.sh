# shellcheck shell=bash
# Shared resolution of the ONE main firstmate home, for the fleet-wide registers
# that have to mean the same thing in every home.
# Usage: . bin/fm-fleet-home-lib.sh
#
# data/closed.md (the closed-topic register) and data/access.md (the fleet access
# map) are captain-scoped facts about the whole fleet, not about one home. Most
# crews here are dispatched BY SECONDMATES rather than by the main home - AGENTS.md
# section 7 routes whole domains to them deliberately - so a register that lived
# only in the main home would be enforced exactly where work is NOT started and
# inert everywhere it is. Worse, inert SILENTLY: an absent register is
# indistinguishable from "no closures set", so nobody would ever learn the control
# had stopped covering the dispatches that matter.
#
# There is therefore ONE register, in the main home, and every secondmate home
# reads it through a pointer file recorded at seed time (bin/fm-home-seed.sh) and
# refreshed on every launch (bin/fm-spawn.sh --secondmate). A secondmate home
# deliberately keeps NO copy of its own: a copy drifts, and a stale copy is a
# closure that silently expires, which is the same failure in a new costume.
#
# The pointer is the one new thing that can break, so it breaks LOUD:
#   - a MAIN home with no register simply has no closures set. Silent, by design,
#     and bootstrap's silence-means-all-good contract depends on that staying so.
#   - a SECONDMATE home that cannot resolve the main home has a BROKEN control, not
#     an empty one: every ship and scout spawn from it warns on stderr naming what
#     could not be resolved, and its bootstrap reports the same.
# It does not refuse. Failing closed on every dispatch is its own outage, and the
# rest of this repo proceeds loudly rather than stopping the fleet on degraded
# state.

FM_SECONDMATE_HOME_MARKER=".fm-secondmate-home"
# Relative to the secondmate home. Lives under config/ with the rest of the local,
# gitignored operational configuration.
FM_PRIMARY_HOME_POINTER="config/primary-home"

# CALLING CONVENTION for every function below: on success stdout carries the value
# (a path, or nothing), on failure stdout carries the human reason and the exit code
# is non-zero. The reason travels on stdout rather than in a global on purpose -
# every caller resolves these in a $(...) command substitution, and a global set
# inside that subshell would be lost, leaving the caller reporting "unknown" exactly
# when it most needs to name what broke.

# fm_is_secondmate_home <home>: 0 when <home> is a seeded secondmate home.
fm_is_secondmate_home() {
  [ -f "$1/$FM_SECONDMATE_HOME_MARKER" ]
}

fm_fleet_resolved_dir() {
  ( cd "$1" 2>/dev/null && pwd ) || return 1
}

# fm_primary_home <home>: print the absolute path of the main firstmate home whose
# data/ holds the fleet-wide registers. A home with no secondmate marker IS that
# home. On failure prints the reason instead and returns 1, so the caller can be
# loud about a broken control rather than guessing at what went wrong.
fm_primary_home() {
  local home=$1 pointer target abs_home abs_target
  if ! fm_is_secondmate_home "$home"; then
    fm_fleet_resolved_dir "$home" || printf '%s\n' "$home"
    return 0
  fi
  pointer="$home/$FM_PRIMARY_HOME_POINTER"
  if [ -L "$pointer" ]; then
    printf '%s is a symlink, which could point the fleet registers anywhere\n' "$pointer"
    return 1
  fi
  if [ ! -f "$pointer" ]; then
    printf 'no main firstmate home recorded at %s\n' "$pointer"
    return 1
  fi
  if [ ! -r "$pointer" ]; then
    printf '%s cannot be read\n' "$pointer"
    return 1
  fi
  target=$(head -n 1 "$pointer" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$target" ]; then
    printf '%s is empty\n' "$pointer"
    return 1
  fi
  case "$target" in
    /*) ;;
    *)
      printf '%s must hold an absolute path, found: %s\n' "$pointer" "$target"
      return 1
      ;;
  esac
  if [ ! -d "$target" ]; then
    printf '%s names %s, which does not exist\n' "$pointer" "$target"
    return 1
  fi
  if ! abs_target=$(fm_fleet_resolved_dir "$target"); then
    printf '%s names %s, which cannot be entered\n' "$pointer" "$target"
    return 1
  fi
  abs_home=$(fm_fleet_resolved_dir "$home" || printf '%s' "$home")
  if [ "$abs_target" = "$abs_home" ]; then
    printf '%s names the secondmate home itself, so there is no main home to read\n' "$pointer"
    return 1
  fi
  printf '%s\n' "$abs_target"
}

# fm_fleet_register <home> <local-data-dir> <basename>: print the path of the
# fleet-wide register <basename> that <home> must read.
#
# A main home reads its own <local-data-dir>/<basename>, so FM_DATA_OVERRIDE keeps
# working; a secondmate home reads <main-home>/data/<basename>. On failure prints the
# reason instead and returns 1.
fm_fleet_register() {
  local home=$1 data=$2 name=$3 primary
  if ! fm_is_secondmate_home "$home"; then
    printf '%s/%s\n' "$data" "$name"
    return 0
  fi
  primary=$(fm_primary_home "$home") || { printf '%s\n' "$primary"; return 1; }
  printf '%s/data/%s\n' "$primary" "$name"
}

# fm_fleet_register_warning <home> <basename> <reason>: the loud stderr block for an
# unresolvable fleet register.
fm_fleet_register_warning() {
  local home=$1 name=$2 reason=$3
  {
    echo "warning: this secondmate home cannot reach the fleet's data/$name, so that"
    echo "  control is BROKEN here rather than empty."
    echo "  home:   $home"
    echo "  reason: ${reason:-unknown}"
    echo "  Record the main firstmate home's absolute path in"
    echo "  $home/$FM_PRIMARY_HOME_POINTER, or re-launch this secondmate from the main"
    echo "  home with bin/fm-spawn.sh <id> --secondmate, which rewrites it."
  } >&2
}

# fm_write_primary_home_pointer <home> <primary-home>: record which main firstmate
# home this secondmate home reads its fleet registers from. Prints nothing on
# success; on failure prints the reason and returns 1 rather than writing through a
# symlink, which would put the pointer outside the home it belongs to.
fm_write_primary_home_pointer() {
  local home=$1 primary=$2 pointer
  pointer="$home/$FM_PRIMARY_HOME_POINTER"
  if [ -L "$pointer" ]; then
    printf '%s is a symlink; refusing to write the fleet-home pointer through it\n' "$pointer"
    return 1
  fi
  if ! mkdir -p "$(dirname "$pointer")" 2>/dev/null; then
    printf 'cannot create %s\n' "$(dirname "$pointer")"
    return 1
  fi
  if ! printf '%s\n' "$primary" > "$pointer" 2>/dev/null; then
    printf 'cannot write %s\n' "$pointer"
    return 1
  fi
}
