# Architecture

## Pieces and who runs them
| Piece | Runs where | Started by |
|---|---|---|
| Cowork session + `cc-orchestrator` skill | Claude desktop app (cloud sandbox, linked to the Mac's folders) | you |
| `worker-spawner.sh` (one per repo) | Mac, launchd agent | `mac/launchd/install.sh` |
| Worker = `claude --dangerously-load-development-channels server:cowork-bridge` in tmux `cc-<name>` | Mac, worktree `<parent>/<WT_DIR>/<name>` | spawner → `worker-up.sh` → `worker.sh` |
| `cowork-bridge` MCP channel server (`.claude/bridge/server.mjs`) | inside each worker (stdio MCP) | Claude Code, from `.mcp.json` |
| Agent tracker server (`mac/tracker/server.mjs`) | Mac, launchd agent, port 7777 | `mac/launchd/install.sh` |
| Tracker hook (`mac/tracker/hook.mjs`) | every Claude Code session on the Mac | `~/.claude/settings.json` hooks |

## The file protocol (`.claude/bridge/`, per worktree, gitignored)
- `spawn/<name>` (main checkout only): a request to start a worker. The first line is an optional branch. It is written atomically (`.<name>.tmp`, then `mv`).
- `spawn-log/<name>.starting|up|failed`: the spawner's result. A `failed` file carries the last screen or the refusal reason.
- `retire/<name>` (main checkout only): a request to retire a finished worker. `scripts/worker-retire.sh` closes its tmux session, removes the worktree and deletes the branch, and only when the branch is merged into `origin/BASE`, the worktree is clean and no task is open. The result goes to `retire-log/<name>.done|refused`. The spawner also sweeps every 30 min and retires workers whose last reply is `done` and older than `RETIRE_AFTER_H`.
- `inbox/<id>.md`: a task (frontmatter `id, branch, base, goal, budget_usd, approved_deps, merge, timeout_min` plus sections).
- `processed/<ts>-<id>.md`: the server claims a task here before delivering it, so a crash never delivers twice.
- `outbox/<id>.md`: the worker's single reply via the `bridge_reply` tool: `status`, plus `needs`/`action` when blocked.
- Follow-ups get new ids (`<id>-r2`). There is one reply per id. The Stop hook does not let a worker go idle with a task unanswered.

## A task's life
1. Cowork writes `inbox/<id>.md`. `server.mjs` (polling every 1.5 s) moves it to `processed/` and pushes it into the session as a `<channel source="cowork-bridge">` event.
2. The worker loads `work-package` and syncs with `origin/BASE`. It installs dependencies (`INSTALL_CMD`). It runs the mandatory agent loop, commits, pushes the feature branch and opens a PR. Then `pr-reviewer` runs in a fresh context, CI runs, and the worker merges.
3. The worker calls `bridge_reply`. Cowork polls `outbox/`, verifies the merge on `origin/BASE`, then decides the next step or escalates to you.

## Guards (defence in depth, each one assumes the others failed)
1. **`.claude/settings.json`.** An allow list covers everything a worker needs without prompts. A deny list blocks pushes to protected branches, force pushes, destructive git, `rm -rf`, dependency upgrades, writes to `.env*`, migrations, CI, settings, hooks and git hooks, and GitHub API writes.
2. **`.claude/hooks/bash-guard.sh`** (PreToolUse). It blocks the shell spellings the deny prefixes miss: `HEAD:dev`, quoting, line continuations, `-c` config keys that run programs, redirects onto protected files, `--no-verify`, and hooksPath changes. It checks four normalised views of every command. Rules are only ever added, never replaced. A regression battery of about 670 probes lives in `tests/`.
3. **`scripts/git-hooks/pre-push`**, installed into `<git-common-dir>/protected-hooks` and shared by all worktrees. It refuses protected refs on the resolved remote ref, whatever the command looked like. A human can override it with `GIT_PUSH_TO_PROTECTED=1`. Optionally seal it: `sudo chown -R root .git/protected-hooks`.
4. **Branch trust** (`scripts/lib/branch-trust.sh`). Before a worker starts, the files that configure it (settings, MCP, hooks, git hooks, bridge server and its npm inputs) must equal `origin/BASE` byte for byte. They are hashed by the trusted repo, and symlinks, hard links and redirected gitdirs are refused. Workers auto-accept the folder-trust dialog, so this is what keeps a branch from granting itself new powers.
5. **Bridge dependencies.** In python/generic repos they are installed fresh in `.claude/bridge/node_modules`, and npm files at the worktree root must be absent. In node repos they are installed once per bridge version under `<git-common-dir>/cc-bridge-deps/` and linked in, so the project's own `package.json` and `node_modules` never touch the bridge.
6. **Existing git hooks.** `install-git-hooks.sh` records the previous hooks dir (`core.hooksPath` or `.git/hooks`). Every client hook in `protected-hooks` chains to it; `pre-push` chains only after its own check.
7. **The spawner.** It accepts only plain names and branch names, never protected or ref-like branches. It starts tmux in argv form, so there is no shell re-parsing.

## Why these choices
- **A file channel, not cross-session messaging.** A cloud Cowork session cannot message local Claude Code sessions, but it can write into a linked folder. Channels push the file into the running session without polling on the model's side.
- **Worktrees.** Each worker gets its own checkout and branch, so many can run in parallel. Frequent merges of `origin/BASE` keep them close.
- **Mandatory agents.** A separate test author, runner and reviewer, each with fresh context, catch what the implementer rationalises away. `pr-reviewer` is the merge gate.
- **`needs: human` versus `orchestrator`.** Only policy-listed items page you. Everything else is Cowork's job, so your phone stays quiet.
