#!/usr/bin/env bash
# Retire a finished worker: close its tmux session, remove its worktree, delete its (merged) branch.
#   scripts/worker-retire.sh <name> [--auto]
# Run by worker-spawner.sh for a retire request (.claude/bridge/retire/<name>, written by the orchestrator)
# or by its periodic sweep (--auto). Runs as the human, so it only ever removes what is provably finished:
#   - <name> is a worktree of THIS repo under ../@@WT_DIR@@, on a worker branch (never a protected one);
#   - the branch tip is already contained in origin/@@BASE@@ (freshly fetched) — merged, nothing to lose;
#   - the worktree has no uncommitted or untracked (non-ignored) changes;
#   - its bridge has no undelivered task in inbox/ and no delivered task without a reply.
# Anything else refuses (exit 1) with the reason on the last line; nothing is touched. Ignored files
# (.env copies, node_modules, venvs) are disposable and go with the worktree. The remote branch is left
# to GitHub's "delete branch on merge" setting.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: scripts/worker-retire.sh <name> [--auto]" >&2; exit 1; }
name=$1; mode=${2:-}
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] || { echo "invalid worker name" >&2; exit 1; }
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
. "$repo/scripts/lib/branch-trust.sh"   # bt_git, valid_worker_branch, worktree_branch
refuse() { echo "worker '$name' NOT retired: $*" >&2; exit 1; }
common=$(bt_git -C "$repo" rev-parse --git-common-dir); case "$common" in /*) ;; *) common="$repo/$common" ;; esac
main=$(cd "$common/.." && pwd)
wt="$(dirname "$main")/@@WT_DIR@@/$name"
base_ref=refs/remotes/origin/@@BASE@@

[ -d "$wt" ] || refuse "$wt does not exist"
# No symlink aliases: `../@@WT_DIR@@/<name>` -> some other worktree would make every check (and the removal)
# act on the target. The resolved path must be the literal one.
[ ! -L "$wt" ] || refuse "$wt is a symlink"
[ "$(cd "$wt" && pwd -P)" = "$(cd "$(dirname "$wt")" && pwd -P)/$name" ] || refuse "$wt resolves elsewhere"
branch=$(worktree_branch "$repo" "$wt") || refuse "$wt is not a worktree of $repo"
[ "$branch" != "(detached)" ] || refuse "$wt has a detached HEAD"
valid_worker_branch "$branch" || refuse "'$branch' is not a worker branch"

# Bridge: nothing waiting and nothing delivered without a reply (checked again right before removal).
bridge="$wt/.claude/bridge"
bridge_idle() {
  if [ -d "$bridge/inbox" ] && [ -n "$(find "$bridge/inbox" -maxdepth 1 -type f -name '*.md' ! -name '.*' 2>/dev/null | head -1)" ]; then
    refuse "a task is still waiting in its inbox"
  fi
  local newest id
  newest=$(ls -1 "$bridge/processed" 2>/dev/null | grep -E '\.md$' | sort | tail -1 || true)
  if [ -n "$newest" ]; then
    id=${newest#*-}; id=${id%.md}
    [ -f "$bridge/outbox/$id.md" ] || refuse "task '$id' was delivered but has no reply yet"
  fi
}
bridge_idle

# Merged: the branch tip must already be in a freshly fetched origin/BASE.
bt_git -C "$repo" fetch --no-tags -q origin "+refs/heads/@@BASE@@:$base_ref" || refuse "could not fetch origin @@BASE@@"
tip=$(bt_git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || refuse "branch $branch not found"
bt_git -C "$repo" merge-base --is-ancestor "$tip" "$base_ref" \
  || refuse "branch $branch has commits that are not in origin/@@BASE@@ (not merged, or squash-merged)"

# Clean: no tracked changes and no untracked, non-ignored files. Read with fsmonitor and hooks off.
dirty=$(bt_git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || refuse "git status failed in $wt"
for envf in @@ENV_FILES@@; do   # worker.sh's own copies of the env files are disposable even when not gitignored
  dirty=$(printf '%s\n' "$dirty" | grep -vxF -- "?? $envf" || true)
done
[ -z "$dirty" ] || refuse "uncommitted or untracked changes in $wt: $(printf '%s' "$dirty" | head -3 | tr '\n' ';')"

# Retire. A task that arrived during the fetch stops it here.
bridge_idle
tmux kill-session -t "=cc-$name" 2>/dev/null || true
for envf in @@ENV_FILES@@; do rm -f -- "$wt/$envf"; done   # worker.sh's copies; everything else must pass git's own check
# No --force: git re-checks that the worktree is clean (ignored files do not block a plain remove).
bt_git -C "$repo" worktree remove "$wt" || refuse "git worktree remove refused for $wt (its tmux session is already closed)"
if bt_git -C "$repo" branch -d "$branch" >/dev/null 2>&1; then gone="branch $branch deleted"; else gone="local branch $branch kept (git branch -d refused)"; fi
echo "worker '$name' retired${mode:+ ($mode)}: tmux cc-$name closed, $wt removed, $gone (merged into origin/@@BASE@@)"
