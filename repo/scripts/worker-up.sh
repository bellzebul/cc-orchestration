#!/usr/bin/env bash
# Start a bridge worker detached in tmux and get it past Claude Code's start-up dialogs.
#   scripts/worker-up.sh <name> [branch]
# Attach later with: tmux attach -t cc-<name>   (detach with Ctrl-b d)
# WORKER_RC=1 (in this script's environment) starts the worker with Remote Control and accepts the
# Remote Control dialog; otherwise that dialog is answered "Never mind".
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: scripts/worker-up.sh <name> [branch]" >&2; exit 1; }
name=$1; branch=${2:-}
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] || { echo "invalid worker name: letters, digits, _ and - only" >&2; exit 1; }
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
. "$repo/scripts/lib/branch-trust.sh"   # valid_worker_branch, worktree_branch
if [ -n "$branch" ] && ! valid_worker_branch "$branch"; then
  echo "invalid branch name (@@PROTECTED_SLASH@@, origin/*, refs/*, HEAD and ref syntax are refused)" >&2; exit 1
fi
command -v tmux >/dev/null || { echo "tmux is required: brew install tmux" >&2; exit 1; }
common=$(git -C "$repo" rev-parse --git-common-dir); case "$common" in /*) ;; *) common="$repo/$common" ;; esac
main=$(cd "$common/.." && pwd)
worker_rc=${WORKER_RC:-0}
sess="cc-$name"
# "=" makes tmux match the session name exactly; a bare -t cc-x also matches cc-x-anything (prefix).
sess_t="=$sess"; pane_t="=$sess:"   # session target / window-pane target

pane_is_dead() { [ "$(tmux list-panes -t "$pane_t" -F '#{pane_dead}' 2>/dev/null | head -1)" = 1 ]; }

if tmux has-session -t "$sess_t" 2>/dev/null; then
  if pane_is_dead; then
    # A previous start exited and its pane was kept (remain-on-exit): that is not a running worker.
    echo "worker '$name': tmux session $sess has a dead pane — killing it and starting fresh" >&2
    tmux kill-session -t "$sess_t"
  elif tmux capture-pane -p -S - -t "$pane_t" 2>/dev/null | grep -Fq -- 'Channels (experimental)'; then
    # Running — but on the branch that was asked for? Read from the repo's worktree admin data.
    want=${branch:-feat/$name}
    have=$(worktree_branch "$repo" "$(dirname "$main")/@@WT_DIR@@/$name" 2>/dev/null) || have="(unknown: not a worktree)"
    if [ "$have" != "$want" ]; then
      echo "worker '$name' is already running (tmux session $sess) on branch '$have', not the requested '$want'" >&2
      exit 1
    fi
    echo "worker '$name' already running (tmux session $sess, branch $have)"; exit 0
  else
    # Alive but never reached the channel banner (stuck on a dialog, still starting, or not a worker):
    # not "running". Left alone — it may be a session a human is attached to.
    echo "worker '$name': tmux session $sess exists but never showed the channel banner — attach and look: tmux attach -t $sess. Last screen:" >&2
    tmux capture-pane -p -t "$pane_t" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -25 >&2 || true
    exit 1
  fi
fi

# argv form (no shell string): tmux executes the command directly, so nothing in name/branch is re-parsed.
# remain-on-exit is chained into the SAME tmux invocation, so a worker that exits at once (e.g. a
# refused branch) still leaves its last screen to report. -e passes WORKER_RC explicitly: a tmux
# server started earlier would not inherit it from this shell.
tmux new-session -d -s "$sess" -x 200 -y 50 -c "$repo" -e "WORKER_RC=$worker_rc" \
  bash scripts/worker.sh "$name" ${branch:+"$branch"} \; set-option -t "$pane_t" remain-on-exit on
# Interrupted before the banner (Ctrl-C, or the spawner being killed): do not leave a half-started
# session behind that the next request would mistake for a worker. Cleared once the banner is seen.
trap 'tmux kill-session -t "$sess_t" 2>/dev/null || true; exit 130' INT
trap 'tmux kill-session -t "$sess_t" 2>/dev/null || true; exit 143' TERM

fail() {  # fail <message> <pane-text>: report, show the last screen, kill the session, exit 1
  echo "worker '$name' $1. Last screen:" >&2
  printf '%s\n' "$2" | grep -v '^[[:space:]]*$' | tail -25 >&2
  tmux kill-session -t "$sess_t" 2>/dev/null || true
  exit 1
}

# ─────────────────────────────────────────────
# Start-up dialogs
# ─────────────────────────────────────────────
# Texts are Claude Code's own UI strings (verified in the 2.1.301 bundle). Each dialog is a select
# menu whose focused option is drawn as "❯ <label>" or "❯ N. <label>". Enter is pressed ONLY when the
# cursor is on the option we want; otherwise one Down is sent and the next tick re-checks. Keys sent
# while a dialog is not yet armed are ignored by Claude Code, so a lost key costs one tick, never a
# wrong answer.
#   Trust:       options [No, exit | Yes, I trust this folder], focus starts on "No" → Down, Enter.
#                Accepting is safe only because worker.sh refused any branch whose settings, MCP config
#                or hooks differ from origin/@@BASE@@ before Claude started.
#   Dev channels:[I am using this for local development | Exit], focus on the first → Enter.
#   Remote Control: [1. Enable Remote Control | 2. Never mind], focus on the first. "Never mind"
#                (value "dismiss") is the No: Down, then Enter. Escape would also dismiss, but on a
#                screen where the dialog has already closed it reaches the prompt instead, so we only
#                ever select by label. Accepted only when WORKER_RC=1.
#   MCP consent: never answered. enabledMcpjsonServers in .claude/settings.json pre-approves the
#                project's servers; if the dialog still shows, the config is wrong → fail.
TRUST_DLG='Quick safety check: Is this a project you created or one you trust?'
TRUST_YES='Yes, I trust this folder'
DEVCH_DLG='WARNING: Loading development channels'
DEVCH_YES='I am using this for local development'
RC_DLG='Take this session with you and pick up right where you left off on any device'
RC_YES='Enable Remote Control'
RC_NO='Never mind'
MCP_DLG='New MCP server found in this project|new MCP servers found in this project'
BANNER='Channels (experimental)'

on_screen() { printf '%s\n' "$1" | grep -Fq -- "$2"; }

choose() {  # choose <pane-text> <label>: Enter if the cursor is on <label>, else move it one Down
  if printf '%s\n' "$1" | grep -Eq -- "❯[[:space:]]+([0-9]+\.[[:space:]]+)?$2"; then
    tmux send-keys -t "$pane_t" Enter
  else
    tmux send-keys -t "$pane_t" Down
  fi
}

for i in $(seq 1 60); do
  sleep 2
  if ! tmux has-session -t "$sess_t" 2>/dev/null; then
    echo "worker '$name' exited during start-up and its tmux session is gone (no screen to report)" >&2; exit 1
  fi
  pane=$(tmux capture-pane -p -t "$pane_t" 2>/dev/null || true)
  if pane_is_dead; then fail "exited during start-up" "$pane"; fi
  if printf '%s\n' "$pane" | grep -Eq -- "$MCP_DLG"; then
    fail "hit the MCP server consent dialog (enabledMcpjsonServers should have pre-approved it; never auto-accepted)" "$pane"
  fi
  if on_screen "$pane" "$TRUST_DLG" && on_screen "$pane" "$TRUST_YES"; then
    choose "$pane" "$TRUST_YES"; continue
  fi
  if on_screen "$pane" "$DEVCH_DLG" && on_screen "$pane" "$DEVCH_YES"; then
    choose "$pane" "$DEVCH_YES"; continue
  fi
  if on_screen "$pane" "$RC_DLG" && on_screen "$pane" "$RC_YES" && on_screen "$pane" "$RC_NO"; then
    if [ "$worker_rc" = 1 ]; then choose "$pane" "$RC_YES"; else choose "$pane" "$RC_NO"; fi
    continue
  fi
  if on_screen "$pane" "$BANNER"; then
    trap - INT TERM
    echo "worker '$name' is up (tmux session $sess, inbox: $(dirname "$main")/@@WT_DIR@@/$name/.claude/bridge/inbox)"; exit 0
  fi
done
echo "worker '$name' did not show the channel banner within 120 s — attach and look: tmux attach -t $sess" >&2
exit 1
