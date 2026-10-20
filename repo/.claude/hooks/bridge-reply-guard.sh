#!/usr/bin/env bash
# Stop hook: a session must not go idle while a cowork-bridge task is open without a reply.
# The bridge server moves each delivered task to processed/<ts>-<id>.md; a reply is outbox/<id>.md.
# If the newest processed task has no outbox file, exit 2 so Claude keeps going and calls
# bridge_reply. stop_hook_active=true means we already forced one continuation — let it stop then,
# so a session that genuinely cannot reply never loops forever.
set -uo pipefail
input=$(cat)
active=$(printf '%s' "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).stop_hook_active===true))}catch{process.stdout.write("false")}})')
[ "$active" = "true" ] && exit 0
bridge="${CLAUDE_PROJECT_DIR:-.}/.claude/bridge"
[ -d "$bridge/processed" ] || exit 0
newest=$(ls -1 "$bridge/processed" 2>/dev/null | grep -E '\.md$' | sort | tail -1)
[ -n "$newest" ] || exit 0
id=${newest#*-}          # strip the "<ts>-" prefix
id=${id%.md}
if [ ! -f "$bridge/outbox/$id.md" ]; then
  printf "cowork-bridge task '%s' has no reply yet. Finish it, or call bridge_reply with status=blocked and say exactly what blocks you. The orchestrator sees nothing else.\n" "$id" >&2
  exit 2
fi
exit 0
