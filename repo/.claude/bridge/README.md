# cowork-bridge — orchestrator ↔ worker protocol

Cowork (the orchestrator, @@OWNER@@'s design partner) drops tasks into `inbox/`; `server.mjs`
(a Claude Code *channel* MCP server, see `.mcp.json`) pushes each one into the running session as
a `<channel source="cowork-bridge" id="…">` event; the worker answers with the `bridge_reply`
tool, which writes `outbox/<id>.md`. Runtime folders are per worktree and never committed.

Start a worker (one per worktree): `scripts/worker.sh <name> [branch]` — or let the orchestrator do it:
with `scripts/worker-spawner.sh` running on the Mac (a launchd agent from the cc-orchestration `mac/` kit, or one terminal kept open), a file dropped into
`<its checkout>/.claude/bridge/spawn/<name>` (optional first line = branch) starts the worker detached in
tmux (`scripts/worker-up.sh`: walks the start-up dialogs, attach with `tmux attach -t cc-<name>`); the
result lands in `.claude/bridge/spawn-log/<name>.up|failed`.
- **Write requests atomically:** write `spawn/.<name>.tmp`, then `mv` it to `spawn/<name>`. The spawner
  ignores files that start with `.` or end in `.tmp`, so it never reads a half-written request. A
  spawner killed mid-start puts the request it claimed (`spawn-log/<name>.starting`) back into `spawn/`.
- **Trust rule:** `worker.sh` refuses a worktree unless the files at its trust paths are EXACTLY @@BASE@@'s
  (`refs/remotes/origin/@@BASE@@`, freshly fetched — no fetch, no start): `.claude/settings.json`,
  `.claude/settings.local.json`, `.mcp.json`, `.claude/hooks/`, `scripts/git-hooks/`, and in
  `.claude/bridge/` `server.mjs`, `package.json`, `.npmrc`, `package-lock.json`, `npm-shrinkwrap.json`,
  `node_modules`, plus `package.json`, `.npmrc` and `node_modules` at the worktree root and in `.claude/`
  (absent on @@BASE@@, so they must be absent: they would redirect npm's install or Node's module resolution
  for the bridge) (`scripts/lib/branch-trust.sh`). The trust paths are walked on disk without following
  symlinks and every file is hashed by the spawner's own repo, so an extra file (even untracked or
  gitignored — a local `settings.local.json` is refused too), a missing one, a changed one, a symlink, a
  hard-linked file, a redirected `.git` / `commondir` or a per-worktree `config.worktree` refuses. The worktree's own git (index, config, `.git` link) is never asked. A worker
  auto-accepts the folder-trust dialog, so those files must reach `@@BASE@@` through a reviewed PR before any
  worker runs them. The refusal lists the files and lands in `spawn-log/<name>.failed`.
  Worker branches are never protected (@@PROTECTED_SLASH@@) and never ref-like (`origin/*`, `refs/*`, `HEAD`, `…@{…}`); the
  spawner rejects such requests, and a reused worktree sitting on another branch than the requested one
  is refused. Bridge deps: `node_modules` and `package-lock.json` are removed before the check and
  reinstalled into an empty dir with `npm install --prefix <wt>/.claude/bridge --workspaces=false
  --ignore-scripts --no-package-lock`.
- **Project deps are the worker's job:** `worker.sh` installs nothing from the branch. A worker runs the
  repo's install command (`@@INSTALL_CMD@@`, see CLAUDE.md) first, before any test.
- **`WORKER_RC=1`** (in the environment of `worker-spawner.sh` / `worker-up.sh` / `worker.sh`) starts
  the worker with Remote Control and accepts its dialog; without it the dialog is answered "Never mind".
  The MCP-server consent dialog is never answered: `enabledMcpjsonServers` pre-approves the project's
  servers, and if the dialog still appears the start fails.
Workers never push to @@PROTECTED_SLASH@@: `scripts/worker.sh` installs the versioned
`scripts/git-hooks/pre-push`, which refuses it on the resolved remote ref; the bash guard blocks
the flags that would skip the hook (`--no-verify`, a `core.hooksPath` override).

## Task file — `inbox/<id>.md`
```markdown
---
id: wp-orders-api-3              # unique; becomes the PR title prefix and the reply filename
branch: feat/orders-api           # the worker's branch (created from base if missing)
base: @@BASE@@
goal: one sentence, what exists when this is done
budget_usd: 10                    # paid API runs the worker may spend without asking
approved_deps: []                 # packages the worker may add (never upgrades)
merge: true                       # may merge its own PR when pr-reviewer APPROVE + CI green
timeout_min: 180
---
## Why
Who consumes the result and which bigger goal it serves (one paragraph).
## Scope
In: … / Out: … (explicit, the worker widens nothing)
## Design
Decisions already made — file/module names, contracts, data flow. The worker does not re-decide.
## Acceptance criteria
Checkable statements (endpoint returns …, test X pins …, doc Y updated).
## Stop conditions (task-specific)
Anything beyond the standard list in the `work-package` skill §5.
```

## Reply — `outbox/<id>.md` (written by `bridge_reply`)
The frontmatter lines come in this order: `id`, `status` (done|blocked|failed), `needs`?, `action`?, `session`, `at`. The report follows in the `work-package` skill §7 layout.
```markdown
---
id: wp-orders-api-2
status: blocked
needs: human
action: apply migration 20261016120000_add_orders_table
session: orders-api
at: 2026-10-16T10:59:46.678Z
---
## Summary …
```
`needs` and `action` are optional. When a reply has neither, those lines are omitted and the file is byte-identical to the format used before they existed.

**`needs`** says who must act: `human` or `orchestrator`. It is set only on blocked/failed replies, never on done ones. Which value to use is a policy decision, listed in `work-package` §5. `human` covers only what @@OWNER@@ alone can clear: a missing `.env` key, a migration to apply, an unapproved @@CONTRACTS@@ contract change, or a paid run of $@@HUMAN_USD@@ or more. Everything else is `orchestrator`.

**`action`** is required whenever `needs` is set. It is one line of at most 200 chars, naming the single concrete command or action. It is written bare (unquoted) in the common case. It is written as a double-quoted YAML string, with `\` and `"` escaped, only when a YAML reader would not read it back bare as the same string: it contains ` #`, `: ` or a tab; starts with a space or one of `"'[]{}&*!|>%@#?:,-` or a backtick; ends with `:` or whitespace; or would be typed as a non-string (`true`/`false`/`yes`/`no`/`on`/`off`/`null`/`~` in any case, a number such as `1`, `-2.5`, `0x1f`, `1e3`, `1:20`, `.inf`, or a date such as `2026-10-17`). `bridge_reply` rejects the call (`isError`) when:
- `needs` has an unknown value;
- `needs` is set on a `done` reply;
- `action` contains a line break (CR, LF, U+0085, U+2028 or U+2029) or is too long;
- `action` contains a control character (C0 other than tab, DEL, C1) or U+FEFF / U+FFFE / U+FFFF;
- `needs` is set without an `action`.

**Tracker semantics.** The agent tracker (cc-orchestration `mac/tracker`, installed per machine) reads this frontmatter:
- `status` blocked|failed **and** `needs: human` → shown red, with a push to the phone (ntfy);
- any other blocked/failed reply → shown yellow ("→ Cowork"), with no push.

One reply per id. A follow-up task gets a new id (`<id>-r2`); never send a second reply to the old one.

## Guarantees
- Delivery: the server claims a task (moves it to `processed/`) before pushing it, so a crash
  never delivers twice. Replies are written atomically (tmp + rename).
- Stop hook `.claude/hooks/bridge-reply-guard.sh`: the session cannot go idle with the newest
  task unanswered — it is told to reply (once; a second stop is allowed so nothing loops).
- Security: anything that can write to `inbox/` can task the session. The folder lives on this
  machine only; keep it that way. The auto-mode classifier treats channel tasks as less trusted
  than typed input — read-only tasks outside the repo (e.g. `~/.claude`) will be refused; keep
  tasks inside the repo.
