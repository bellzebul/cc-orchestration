#!/usr/bin/env bash
# Spawn requests from the orchestrator: a file dropped into <main checkout>/.claude/bridge/spawn/<name>
# (optional first line = branch) starts a worker via scripts/worker-up.sh. Results land in
# .claude/bridge/spawn-log/<name>.<status>. Run once, keep it running:  scripts/worker-spawner.sh
# Writers must create the request atomically: write spawn/.<name>.tmp, then mv it to spawn/<name>.
# Files starting with "." or ending in ".tmp" are never picked up.
# WORKER_RC=1 in this script's environment starts every worker with Remote Control (see worker-up.sh).
set -euo pipefail
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel 2>/dev/null) || repo=""
[ -n "$repo" ] || { echo "worker-spawner: cannot resolve the repository root — run it from a checkout" >&2; exit 1; }
spawn="$repo/.claude/bridge/spawn"; log="$repo/.claude/bridge/spawn-log"
mkdir -p "$spawn" "$log"
. "$repo/scripts/lib/branch-trust.sh"   # valid_worker_branch

# A killed spawner must not lose a request: the one THIS process claimed (and only that one — another
# spawner's .starting is not ours) goes back to spawn/. ln is an atomic no-clobber: it fails if a newer
# request for the same name arrived meanwhile.
claimed=""
requeue_starting() {
  local f n=$claimed
  [ -n "$n" ] || return 0
  f="$log/$n.starting"
  [ -f "$f" ] || return 0
  if ln -- "$f" "$spawn/$n" 2>/dev/null && rm -f -- "$f"; then
    echo "$(date +%T) requeued: $n"
  else
    echo "$(date +%T) could not requeue $n — left at $f" >&2
  fi
}
trap requeue_starting EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "worker-spawner: watching $spawn (Ctrl-C to stop)"
while true; do
  for req in "$spawn"/*; do
    [ -f "$req" ] || continue
    name=$(basename "$req")
    case "$name" in .*|*.tmp) continue ;; esac            # in-flight writes (.<name>.tmp) and dotfiles
    # Every step is guarded (if / ||): under set -e one bad request must never stop the loop.
    branch=$(head -1 -- "$req" 2>/dev/null | tr -d '[:space:]') || continue   # vanished meanwhile
    # The spawner runs as the human, outside every agent guard: refuse any name/branch that is not a
    # plain identifier, so a request file can never smuggle shell syntax or extra arguments; and never
    # a branch a worker must not sit on (@@PROTECTED_SLASH@@) or one that reads as a ref (origin/*, refs/*, HEAD).
    if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] \
       || { [ -n "$branch" ] && ! valid_worker_branch "$branch"; }; then
      mv -- "$req" "$log/rejected.$(date +%s).$RANDOM" 2>/dev/null || rm -f -- "$req" || true
      echo "$(date +%T) REJECTED: invalid name or branch"; continue
    fi
    mv -- "$req" "$log/$name.starting" || continue
    claimed=$name
    if out=$(bash "$repo/scripts/worker-up.sh" "$name" ${branch:+"$branch"} 2>&1); then
      printf '%s\n' "$out" > "$log/$name.up" || true
      rm -f -- "$log/$name.starting"; claimed=""; echo "$(date +%T) up: $name"
    else
      printf '%s\n' "$out" > "$log/$name.failed" || true
      rm -f -- "$log/$name.starting"; claimed=""; echo "$(date +%T) FAILED: $name — $out"
    fi
  done
  sleep 3
done
