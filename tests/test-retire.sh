#!/usr/bin/env bash
# Tests for scripts/worker-retire.sh and the spawner's retire handling, on a rendered scratch repo.
#   tests/test-retire.sh            (run by tests/run-battery.sh too)
# Needs: git, node, npm, bash. tmux is stubbed.
set -uo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'kill $spid 2>/dev/null; rm -rf "$tmp"' EXIT
spid=""
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fail=1; }
q() { "$@" >/dev/null 2>&1; }

mkdir -p "$tmp/bin"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/tmux"; chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b dev "$tmp/origin.git"
git init -q -b dev "$tmp/app"; cd "$tmp/app"
printf '{"name":"app","scripts":{"test":"true"}}\n' > package.json
q git add -A; q git commit -m init; git remote add origin "$tmp/origin.git"; q git push origin dev
q "$kit/install.sh" "$tmp/app"; q "$kit/install.sh" "$tmp/app"
[ -x scripts/worker-retire.sh ] || { echo "render failed"; exit 1; }
q git add -A; q git commit -m setup; GIT_PUSH_TO_PROTECTED=1 q git push origin dev
wtr="$tmp/app-wt"

mk() {  # mk <name> <merged:yes|no>: a worker worktree with one commit and a done reply
  local name=$1 merged=$2 w="$wtr/$1"
  q git -C "$tmp/app" worktree add -b "feat/$name" "$w" refs/remotes/origin/dev
  echo "$name" > "$w/$name.txt"; q git -C "$w" add -A; q git -C "$w" commit -m "$name"
  mkdir -p "$w/.claude/bridge/"{inbox,processed,outbox}
  echo "x" > "$w/.claude/bridge/processed/100-wp-$name.md"
  printf -- '---\nid: wp-%s\nstatus: done\n---\n' "$name" > "$w/.claude/bridge/outbox/wp-$name.md"
  if [ "$merged" = yes ]; then
    q git -C "$tmp/app" fetch origin
    q git -C "$tmp/app" merge --no-ff -m "merge $name" "feat/$name"
    GIT_PUSH_TO_PROTECTED=1 q git -C "$tmp/app" push origin dev
  fi
}
retire() { bash "$tmp/app/scripts/worker-retire.sh" "$@" 2>&1; }

mk good yes
if out=$(retire good) && [ ! -d "$wtr/good" ] && ! git show-ref -q --verify refs/heads/feat/good; then ok "merged+clean worker is retired"; else bad "merged+clean worker: $out"; fi

mk open no
if ! out=$(retire open) && [ -d "$wtr/open" ] && [[ $out == *"not in origin/dev"* ]]; then ok "unmerged worker refused"; else bad "unmerged: $out"; fi

mk dirty yes; echo wip >> "$wtr/dirty/dirty.txt"
if ! out=$(retire dirty) && [ -d "$wtr/dirty" ] && [[ $out == *"uncommitted"* ]]; then ok "dirty worktree refused"; else bad "dirty: $out"; fi

mk untracked yes; echo new > "$wtr/untracked/new.txt"
if ! out=$(retire untracked) && [ -d "$wtr/untracked" ]; then ok "untracked file refused"; else bad "untracked: $out"; fi

mk ignored yes; echo "K=V" > "$wtr/ignored/.env"; mkdir -p "$wtr/ignored/.claude/bridge/node_modules/x"
if out=$(retire ignored) && [ ! -d "$wtr/ignored" ]; then ok "ignored files (.env, node_modules) do not block"; else bad "ignored: $out"; fi

mk waiting yes; echo t > "$wtr/waiting/.claude/bridge/inbox/wp-next.md"
if ! out=$(retire waiting) && [ -d "$wtr/waiting" ] && [[ $out == *"inbox"* ]]; then ok "pending inbox task refused"; else bad "inbox: $out"; fi

mk unanswered yes; echo t > "$wtr/unanswered/.claude/bridge/processed/200-wp-r2.md"
if ! out=$(retire unanswered) && [ -d "$wtr/unanswered" ] && [[ $out == *"no reply"* ]]; then ok "delivered task without reply refused"; else bad "unanswered: $out"; fi

ln -s "$wtr/good-target" "$wtr/alias" 2>/dev/null; mk aliased yes; rm -f "$wtr/alias"; ln -s "$wtr/aliased" "$wtr/alias"
if ! out=$(retire alias) && [ -d "$wtr/aliased" ] && [[ $out == *"symlink"* ]]; then ok "symlink alias refused"; else bad "symlink alias: $out"; fi
if ! out=$(retire 'x;rm') ; then ok "invalid name refused"; else bad "invalid name accepted"; fi
if ! out=$(retire nosuch) && [[ $out == *"does not exist"* ]]; then ok "missing worktree refused"; else bad "missing: $out"; fi

# Spawner: a retire request, and the sweep (old done reply → retired; fresh one → kept)
mk req yes; mk old yes; mk fresh yes
touch -t 202001010000 "$wtr/old/.claude/bridge/outbox/wp-old.md"
mkdir -p "$tmp/app/.claude/bridge/retire"; : > "$tmp/app/.claude/bridge/retire/.req.tmp"; mv "$tmp/app/.claude/bridge/retire/.req.tmp" "$tmp/app/.claude/bridge/retire/req"
RETIRE_AFTER_H=1 bash "$tmp/app/scripts/worker-spawner.sh" > "$tmp/spawner.log" 2>&1 & spid=$!
for _ in $(seq 1 40); do [ -f "$tmp/app/.claude/bridge/retire-log/req.done" ] && [ -f "$tmp/app/.claude/bridge/retire-log/old.done" ] && break; sleep 0.5; done
kill $spid 2>/dev/null; wait $spid 2>/dev/null; spid=""
if [ ! -d "$wtr/req" ] && [ -f "$tmp/app/.claude/bridge/retire-log/req.done" ]; then ok "spawner handles a retire request"; else bad "retire request: $(cat "$tmp/spawner.log")"; fi
if [ ! -d "$wtr/old" ]; then ok "sweep retires a done worker idle past RETIRE_AFTER_H"; else bad "sweep old: $(cat "$tmp/spawner.log")"; fi
if [ -d "$wtr/fresh" ]; then ok "sweep keeps a recently finished worker"; else bad "sweep removed a fresh worker"; fi
if [ -d "$wtr/open" ] && [ -d "$wtr/dirty" ]; then ok "sweep never touches unmerged/dirty workers"; else bad "sweep removed an unmerged/dirty worker"; fi

[ $fail = 0 ] && echo "retire tests: all $n OK" || { echo "retire tests: FAILED"; exit 1; }
