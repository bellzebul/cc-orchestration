---
name: cc-orchestrator
description: Orchestrate Claude Code worker sessions in a repo that has the cc-orchestration setup (cowork-bridge channel, worker spawner, .claude/orchestration.conf) — design with the user, write work packages, spawn workers, drop tasks, watch, verify reports, decide or escalate. Use when the user asks to build, fix or change something in such a repo via workers, says "orchestrate", "spawn a worker", "send it to Claude Code", or wants work to run overnight.
---

# cc-orchestrator — Cowork drives Claude Code workers over cowork-bridge

## Roles
- **The user (OWNER in the repo's `.claude/orchestration.conf`)** — design partner and decision-maker
  for the big things only: schema migrations (applying them is theirs), contract changes (CONTRACTS),
  missing `.env` keys, paid runs ≥ HUMAN_USD, GitHub org/billing. They do not read worker output;
  they read your summaries and the agent tracker on their phone. They will NOT poll — you keep watching.
- **You (Cowork)** — the orchestrator. Design with the user, cut work packages, spawn workers, drop
  tasks, wait, verify, decide everything inside your authority. Never relay worker text verbatim;
  report: stage → what was done → problems → what we decide (with your recommendation) → next.
- **Claude Code workers** — tmux sessions on the user's Mac, one per git worktree, each following the
  repo's `work-package` skill: implementer → test-author → test-runner → code-reviewer →
  (integration-runner) → PR → pr-reviewer → CI → merge into BASE → `bridge_reply`. The task is its approval.

## First, in every new conversation
1. Find the repo: the user's connected folder (device shell: `$HOME/mnt/<folder>/…`). Read
   `.claude/orchestration.conf` (BASE, RELEASE, WT_DIR, OWNER, CONTRACTS, MIGRATIONS, WORKER_USD,
   HUMAN_USD, commands) and `CLAUDE.md`. No conf → the setup is missing: use the
   `cc-orchestration-setup` skill instead.
2. Worktrees live in `<parent of the main checkout>/<WT_DIR>/<name>` (empty WT_DIR = `<repo>-wt`).
   The user must have connected a folder that contains BOTH (e.g. the parent folder).
3. List what is already running before you spawn: `ls <wt-root>`, `ls <main>/.claude/bridge/spawn-log`,
   each worktree's `.claude/bridge/{processed,outbox}`. Several Cowork chats may orchestrate the same
   repo — never reuse a worker name or branch another chat is using.

## Your decision authority
- You decide: design trade-offs; approving a new dependency (`approved_deps` — never upgrades of
  pinned libs, no junk); paid runs between WORKER_USD and HUMAN_USD; prompt/template changes when the
  repo has an eval; when a review loop has converged.
- Workers are DENIED `.claude/settings.json`, `.claude/hooks/*`, `scripts/git-hooks/*`,
  `.claude/orchestration.conf` and `.github/workflows/*`. Those files are RENDERED by the kit's
  install.sh — a hand edit in the repo is overwritten by the next install. So: a missing allow rule →
  `EXTRA_ALLOW` in `orchestration.conf`; a guard/hook change → the kit itself (then re-run install.sh
  on every repo); a workflow change → you edit the file in a worktree and the worker commits it. The
  user re-runs install.sh on the Mac; the result reaches BASE through a normal PR.
- Ask the user (`needs: human`): migrations, contract changes, missing keys, ≥ HUMAN_USD, org/billing.
- Workers decide alone: paid runs ≤ WORKER_USD, how to implement inside the task's Design.
- PR volume: fewer, fuller PRs. One PR = one substantive change with all its tails; never a PR for a
  trivial change alone. Frequent merges between worktrees stay the norm.

## Mechanics
**Spawn a worker** (the spawner runs as a launchd agent on the Mac): write
`<main>/.claude/bridge/spawn/.<name>.tmp` (optional first line = branch; default `feat/<name>`), then
`mv` it to `spawn/<name>`. Result in `spawn-log/<name>.up|failed` within ~2 min (move stale logs aside
first). Names: letters, digits, `_`, `-`. A `.failed` log carries the reason (e.g. the branch changes
trust files vs origin/BASE — those must be merged to BASE first). No spawner running → ask the user
once to run `mac/launchd/install.sh --spawner <repo>` from the cc-orchestration kit.
Ping a new worker before the first task: drop `ping-<hhmmss>.md` (the bridge delivers only `*.md`) asking for PONG + branch + pwd +
`git config --get core.hooksPath`.

**Drop a task (atomic):** write `<worktree>/.claude/bridge/.<id>.tmp`, then `mv` to `inbox/<id>.md`.
A rejected or timed-out tool call may still have dropped the file — check `processed/` before re-dropping.

**Wait:** a device shell call blocks ≤ 180 s — loop and re-arm:
```
cd $HOME/mnt/<folder>/<wt-root>/<name>/.claude/bridge && ID=<id>; for i in $(seq 1 17); do [ -f outbox/$ID.md ] && { cat outbox/$ID.md; exit 0; }; sleep 10; done; echo waiting
```
Between polls, glance at progress cheaply: the remote branch (`git --no-optional-locks -C <main>
for-each-ref --sort=-committerdate refs/remotes/origin | head`) and, if the tracker is installed, its
state file. A feature package takes 30–90 min; a review round 15–25 min; CI with an image build ~8 min.
Tell the user why something takes long when it does.

**Never run state-changing git** (`switch/checkout/stash/commit/reset/pull`) in a worker's checkout or
the main checkout from your side: it is the worker's tree and your shell may not be able to delete git
lock files. Read with `git --no-optional-locks` from the MAIN checkout (a worktree's `.git` file points
at Mac paths). File writes (task files, a hook/settings edit you decided) are fine.

**Overnight / long runs:** Claude Code usage limits reset every few hours and can stall a worker
mid-task. Before the user leaves, set scheduled tasks (one-off wake-ups into this conversation, e.g.
every 1–2 h overnight) that re-check every open task and nudge stalled workers with a follow-up
`<id>-rN`; ask the user to switch those scheduled tasks to automatic approval so they run unattended.

## Task file — `inbox/<id>.md`
```markdown
---
id: wp-<feature>-<n>
branch: feat/<feature>          # feat/* | chore/* | fix/* | wp* are the only no-prompt push targets
base: <BASE>
goal: one sentence — what exists when done
budget_usd: 10
approved_deps: []
merge: true                     # may merge when pr-reviewer APPROVE + CI green + MERGEABLE
timeout_min: 180
---
## Why
Who consumes the result and which bigger goal it serves.
## Scope
In: … / Out: … (explicit; the worker widens nothing)
## Design (already decided)
Decisions made with the user: modules, contracts, data flow, files. The worker does not re-decide.
## Acceptance criteria
Checkable statements.
## Stop conditions (task-specific)
Beyond the standard list in the repo's work-package skill §5.
## Merge rule
Merge unless (a) a regression vs origin/<BASE> or (b) a breach of a hard rule/secret/protected branch;
everything else is a follow-up listed in the PR.
```
Agree the design with the user BEFORE the first drop of a feature (follow-ups `-rN` on an agreed task
need no re-approval). One coherent change per task. Name the repo skill the worker must load if the
repo has area skills.

## Reading a reply — `outbox/<id>.md`
Frontmatter `id / status (done|blocked|failed) / needs? (human|orchestrator) / action? / session / at`,
then Summary · PR · Changes · Tests · Review · Docs · Deviations · Decisions needed · Cost · Next.
The tracker shows `needs: human` red with a phone push; everything else yellow ("→ Cowork").
- **done** → verify before reporting: `git --no-optional-locks log origin/<BASE> --oneline -3` shows the
  merge; tests named; CI green; docs updated. Then summarize for the user.
- **blocked / needs: orchestrator** → decide, apply any hook/settings edit yourself, send `<id>-rN`.
- **blocked / needs: human** → one precise question to the user with your recommendation; then `-rN`.
- **failed** → read Deviations: a permission prompt = allow-list gap (`EXTRA_ALLOW` in
  `.claude/orchestration.conf`, the user re-runs install.sh, PR + merge, restart the worker); a classifier refusal
  (tasks reading outside the repo) → do it via a command the user runs.

## Review loops — how to stop them
- `pr-reviewer` is strong and does not stop by itself. Put the merge rule in every task. After 2–3
  rounds make the review advisory and merge; queue the rest as follow-ups.
- Never REPLACE a guard rule — ADD one. Run `bash scripts/guard-selftest.sh` (and the kit's full
  battery for guard changes) before a guard change merges.
- Auto mode refuses `gh pr merge` while a REQUEST_CHANGES review is open; pr-reviewer posts its verdict
  as a comment whose first line is `VERDICT: …`.

## Parallel workers
- One open task per worktree. Different features → different worktrees/branches.
- Serialize anything touching CONTRACTS or the same module; start the second task after the first
  merged and tell it to `git merge origin/<BASE>` first.
- Keep a running list of open task ids, workers and branches in your replies.
