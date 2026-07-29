#!/usr/bin/env bash
# fm-disk-preflight.sh - disk guard run BEFORE any heavy build/sim dispatch or resume.
#
# Why: RN Release-build + sim + video work can drive the shared volume to hard-zero
# (ENOSPC), which fails builds AND wedges the harness (it cannot even allocate a
# command's output file). This guard fires exactly when needed - it is strictly
# better than a blind timer because it reclaims only when free space is low and
# never mid-build (it runs before a build starts).
#
# Contract:
#   - If free >= RECLAIM_AT (default 15G): print "disk OK" and exit 0 (no-op fast path).
#   - Else reclaim cheap->expensive: DerivedData + sim caches/logs + npm cacache,
#     unavailable sims, OLD sim runtimes (keep newest KEEP_RUNTIMES), erase stale
#     sim data, returned-slot build artifacts, then teardown LANDED workspaces
#     (fm-teardown safety intact - never force, never unlanded).
#   - Re-check: print freed GB. Exit 0 if free >= HARD_FLOOR (default 10G), else
#     exit 3 (caller must NOT start the heavy build - escalate for external relief).
#
# Usage: bin/fm-disk-preflight.sh [reclaim_at_gb] [hard_floor_gb]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RECLAIM_AT="${1:-15}"        # GB: reclaim when free falls below this
HARD_FLOOR="${2:-10}"        # GB: block the build if still below this after reclaim
KEEP_RUNTIMES="${FM_KEEP_SIM_RUNTIMES:-2}"

free_gb() { df -g "$FM_HOME" 2>/dev/null | awk 'NR==2{print $4}'; }

start_free="$(free_gb)"
[ -z "$start_free" ] && { echo "disk-preflight: cannot read free space; proceeding"; exit 0; }
if [ "$start_free" -ge "$RECLAIM_AT" ]; then
  echo "disk-preflight: disk OK (${start_free}G free >= ${RECLAIM_AT}G)"; exit 0
fi
echo "disk-preflight: LOW (${start_free}G free < ${RECLAIM_AT}G) - reclaiming..."

# 1. Caches (safe, always regenerable)
rm -rf ~/Library/Developer/Xcode/DerivedData/* \
       ~/Library/Developer/CoreSimulator/Caches/* \
       ~/Library/Logs/CoreSimulator/* \
       ~/.npm/_cacache >/dev/null 2>&1
find "${TMPDIR:-/tmp}" -maxdepth 3 -name 'metro-*' -mtime +0 -prune -exec rm -rf {} + >/dev/null 2>&1

# 2. Simulators: remove unavailable devices, then OLD runtimes (keep newest N),
#    then erase stale data. Old iOS runtimes are ~7G each - the biggest single hog.
if command -v xcrun >/dev/null 2>&1; then
  xcrun simctl delete unavailable >/dev/null 2>&1
  # Delete all runtimes except the newest KEEP_RUNTIMES (by version sort).
  ids="$(xcrun simctl runtime list 2>/dev/null | sed -nE 's/.*iOS ([0-9.]+).*- ([0-9A-F-]{36}).*/\1 \2/p' \
         | sort -V | awk '{print $2}')"
  n="$(printf '%s\n' "$ids" | grep -c .)"
  if [ "$n" -gt "$KEEP_RUNTIMES" ]; then
    drop="$(printf '%s\n' "$ids" | head -n "$((n - KEEP_RUNTIMES))")"
    for rid in $drop; do xcrun simctl runtime delete "$rid" >/dev/null 2>&1 && echo "  purged sim runtime $rid"; done
  fi
  # Erase stale sim data (safe: preflight runs BEFORE a build, so nothing is mid-run).
  xcrun simctl shutdown all >/dev/null 2>&1
  xcrun simctl erase all >/dev/null 2>&1
fi

# 3. Returned pool-slot build artifacts (never a LIVE lease). Live leases = worktree=
#    paths recorded in this home's state/*.meta.
live_wts=" $(grep -ho '^worktree=[^ ]*' "$FM_HOME"/state/*.meta 2>/dev/null | cut -d= -f2 | tr '\n' ' ') "
for pool in /Users/claude/.treehouse/*/; do
  for slot in "$pool"*/; do
    for repo in "$slot"*/; do
      case "$live_wts" in *" ${repo%/} "*) continue;; esac
      rm -rf "${repo}node_modules" "${repo}ios/build" "${repo}ios/Pods" \
             "${repo}android/app/build" "${repo}android/build" "${repo}.expo" >/dev/null 2>&1
    done
  done
done

# 4. Teardown ABANDONED workspaces that are also landed.
#
#    LANDED AND IN USE ARE DIFFERENT PROPERTIES, and conflating them is what made
#    this script eat live crews. The original test was "would anything be LOST?"
#    (0 uncommitted files + HEAD on a remote) and never "is anything USING this?".
#    A crew that has just run `git checkout -b` and changed nothing is MAXIMALLY
#    LANDED and MAXIMALLY IN USE at the same moment - nothing to lose, and a live
#    agent working in it. That shape scored as disposable, so the workspace was
#    torn down underneath the very crew that invoked this script, which also
#    deleted its state/<id>.meta and released its treehouse lease. Every symptom
#    ("spawning is intermittent") was this.
#
#    So liveness is now the FIRST gate, and it is checked three ways:
#      (a) never the CALLER's own workspace (we may be running from inside it),
#      (b) never a workspace whose tmux window still exists (a live crew),
#      (c) never a secondmate home (persistent by design).
#    Only then does the landed check apply, so unlanded work is still never lost.
#
#    NOTE: `live_wts` (built above) is every meta's worktree, so it cannot be used
#    as the step-4 guard directly - that would skip everything and make this a
#    no-op. The meaningful question is per-workspace liveness, below.
self_path="$(pwd -P 2>/dev/null || pwd)"
for meta in "$FM_HOME"/state/*.meta; do
  [ -e "$meta" ] || continue
  id="$(basename "$meta" .meta)"
  wt="$(grep -o '^worktree=[^ ]*' "$meta" | cut -d= -f2)"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then continue; fi

  # (c) secondmate homes are persistent - never auto-teardown them here
  grep -qx 'kind=secondmate' "$meta" && continue

  # (a) SELF-EXCLUSION: never tear down the workspace we are running inside.
  case "$self_path/" in "$wt"/*) echo "  skip (self): $id"; continue;; esac

  # (b) LIVENESS: a recorded tmux window that still exists means a crew is working.
  win="$(grep -o '^window=[^ ]*' "$meta" | cut -d= -f2)"
  if [ -n "$win" ] && tmux list-windows -a -F '#S:#W' 2>/dev/null | grep -qx "$win"; then
    echo "  skip (in use): $id"; continue
  fi

  # Only now: is it safe to lose? fm-teardown re-checks and refuses unlanded work.
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  onremote="$(git -C "$wt" branch -r --contains HEAD 2>/dev/null | grep -c .)"
  if [ "$dirty" = "0" ] && [ "$onremote" -gt 0 ]; then
    "$SCRIPT_DIR/fm-teardown.sh" "$id" >/dev/null 2>&1 && echo "  torn down abandoned workspace: $id"
  fi
done

sync
end_free="$(free_gb)"
freed="$(( end_free - start_free ))"
echo "disk-preflight: reclaimed ~${freed}G (${start_free}G -> ${end_free}G free)"
if [ "$end_free" -lt "$HARD_FLOOR" ]; then
  echo "disk-preflight: STILL LOW (${end_free}G < ${HARD_FLOOR}G) - DO NOT start the heavy build; escalate for external relief (another home building, or expand disk)." >&2
  exit 3
fi
echo "disk-preflight: OK to build (${end_free}G free)"
exit 0
