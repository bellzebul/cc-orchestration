#!/usr/bin/env bash
# Start an orchestrated Claude Code worker in its own git worktree, wired to cowork-bridge.
#   scripts/worker.sh <name> [branch] [extra claude flags…]
# name   → worktree ../@@WT_DIR@@/<name> and the session name
# branch → defaults to feat/<name>; created from origin/@@BASE@@ when it does not exist. Never @@PROTECTED_SLASH@@,
#          never a ref-like name (origin/*, refs/*, HEAD, *@{*) — see valid_worker_branch. A reused
#          worktree must already sit on exactly this branch.
# WORKER_RC=1 adds --remote-control so the session is reachable from phone/browser.
# Refuses (exit 1) a worktree whose trust files (BRANCH_TRUST_PATHS: Claude settings incl. the local
# one, .mcp.json, .claude/hooks/, scripts/git-hooks/, the bridge server, package.json, .npmrc,
# lockfiles, node_modules — and npm's package.json/.npmrc/node_modules at the root and in .claude/,
# which must be absent) are not exactly @@BASE@@'s — see scripts/lib/branch-trust.sh. The checker is
# always sourced from THIS checkout, never from the branch under test, and never asks the worktree's own
# git anything. Project deps are NOT installed here: the worker runs the install command itself (CLAUDE.md).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: scripts/worker.sh <name> [branch] [claude flags…]" >&2; exit 1; }
name=$1; shift
branch=${1:-feat/$name}; [ $# -ge 1 ] && shift

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
. "$repo/scripts/lib/branch-trust.sh"   # bt_git, valid_worker_branch, worktree_branch, reset_bridge_deps, check_branch_trust
refuse() { echo "worker '$name' REFUSED: $*" >&2; exit 1; }
valid_worker_branch "$branch" \
  || refuse "'$branch' is not a branch a worker may use (@@PROTECTED_SLASH@@, origin/*, refs/*, HEAD and ref syntax are refused)"
dev_ref=refs/remotes/origin/@@BASE@@   # full ref everywhere: a local branch or tag named origin/@@BASE@@ must not win
# The MAIN checkout, whichever worktree this script runs from: worktrees live beside it in ../@@WT_DIR@@
common=$(bt_git -C "$repo" rev-parse --git-common-dir); case "$common" in /*) ;; *) common="$repo/$common" ;; esac
main=$(cd "$common/.." && pwd)
wt_root="$(dirname "$main")/@@WT_DIR@@"
wt="$wt_root/$name"
mkdir -p "$wt_root"

# Fresh origin/@@BASE@@ or no start: the trust check compares against it, and a stale ref is not @@BASE@@.
bt_git -C "$repo" fetch --no-tags origin "+refs/heads/@@BASE@@:$dev_ref" \
  || refuse "could not fetch origin @@BASE@@ — the trust check needs a current $dev_ref"
if [ ! -d "$wt" ]; then
  if bt_git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    bt_git -C "$repo" worktree add "$wt" "$branch"   # a branch NAME (a full ref would detach HEAD)
  elif bt_git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    bt_git -C "$repo" worktree add --track -b "$branch" "$wt" "refs/remotes/origin/$branch"
  else
    bt_git -C "$repo" worktree add -b "$branch" "$wt" "$dev_ref"
  fi
fi

# The branch actually checked out there, from the repo's admin data (not the worktree's .git): a reused
# worktree on another branch is refused, never started silently.
actual=$(worktree_branch "$repo" "$wt") || refuse "$wt exists but is not a worktree of $repo"
[ "$actual" = "$branch" ] \
  || refuse "worktree $wt is on '$actual', not the requested '$branch' — switch it or remove it first"

# Bridge deps are npm's per-worktree output: drop them BEFORE the check (so the check sees only what the
# branch carries — a lockfile or node_modules there is refused), reinstall into an empty dir after it.
reset_bridge_deps "$wt" || refuse "could not reset the bridge deps in $wt"

# Branch trust. The last line names the reason, so worker-up.sh's "last screen" carries it into the
# spawner's spawn-log/<name>.failed.
check_branch_trust "$wt" "$dev_ref" "$repo" \
  || refuse "branch $actual (in $wt) changes trust files (settings/MCP/hooks/bridge) vs origin/@@BASE@@ — merge them to @@BASE@@ via a PR first"

# Per-worktree runtime: secrets (gitignored), bridge deps + queue folders.
for envf in @@ENV_FILES@@; do   # copied from the main checkout when present there, never overwritten
  [ -f "$wt/$envf" ] || { [ -f "$main/$envf" ] && cp "$main/$envf" "$wt/$envf"; } || true
done
mkdir -p "$wt/.claude/bridge/inbox" "$wt/.claude/bridge/outbox" "$wt/.claude/bridge/processed"
# Empty node_modules (reset above), no dependency lifecycle scripts, no lockfile read or written.
# --prefix pins the project to the bridge dir (npm must not walk up to a root package.json/.npmrc), and
# --workspaces=false keeps it from acting as a workspace member; the trust check already refuses a root
# or .claude/ package.json, .npmrc or node_modules — belt and braces.
if [ "@@BRIDGE_DEPS@@" = isolated ]; then
  # Node repos: the worktree root legitimately has package.json / node_modules (the worker runs npm ci),
  # so the bridge's deps are installed OUTSIDE the worktree — in the trusted clone's git dir, keyed by the
  # bridge package.json (already verified equal to origin/@@BASE@@) — and linked in. Node resolves the
  # bridge's imports through that link first, so nothing at the worktree root can shadow them.
  key=$(bt_git -C "$repo" hash-object --no-filters -- "$wt/.claude/bridge/package.json")
  deps="$common/cc-bridge-deps/$key"
  if [ ! -d "$deps/node_modules" ]; then
    mkdir -p "$common/cc-bridge-deps"
    tmpd=$(mktemp -d "$common/cc-bridge-deps/.tmp.XXXXXX")
    cp "$wt/.claude/bridge/package.json" "$tmpd/package.json"
    (cd "$tmpd" && npm install --prefix "$tmpd" --workspaces=false --ignore-scripts --no-package-lock \
      --no-audit --no-fund >/dev/null)
    mv "$tmpd" "$deps" 2>/dev/null || rm -rf "$tmpd"   # a parallel start won the race: use theirs
  fi
  ln -s "$deps/node_modules" "$wt/.claude/bridge/node_modules"
else
  (cd "$wt/.claude/bridge" && npm install --prefix "$wt/.claude/bridge" --workspaces=false \
    --ignore-scripts --no-package-lock --no-audit --no-fund >/dev/null)
fi
gh_repo="@@GH_REPO@@"
[ -z "$gh_repo" ] || (cd "$wt" && gh repo set-default "$gh_repo" >/dev/null 2>&1 || true)  # gh needs a default repo in a worktree
bash "$repo/scripts/install-git-hooks.sh" "$wt"                              # pre-push hook, sealed outside the working tree

rc=()
[ "${WORKER_RC:-0}" = "1" ] && rc=(--remote-control)
echo "worker '$name' → $wt (branch $branch). Drop tasks into $wt/.claude/bridge/inbox/"
cd "$wt"
exec claude --dangerously-load-development-channels server:cowork-bridge \
  --name "$name" ${rc[@]+"${rc[@]}"} "$@"
