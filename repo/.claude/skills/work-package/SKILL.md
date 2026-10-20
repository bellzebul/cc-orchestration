---
name: work-package
description: The worker's standard operating procedure for a cowork-bridge work package (a channel event from cowork-bridge, or a pasted task with the same frontmatter) — sync with the base branch, implement via the implementer agent, MANDATORY test-author → test-runner → code-reviewer → (integration-runner) → PR → pr-reviewer → CI → merge, then bridge_reply. Use the moment a work package arrives; it defines what "done" means and when to stop with status=blocked.
---

# Work package SOP

The orchestrator (@@OWNER@@'s Cowork session) designed this change with @@OWNER@@ and already made
the design decisions written in the task. **The task is the approval.** Do not stop to ask for a
plan sign-off, do not re-open decisions the task made, do not ask "should I proceed". Stop only on
a stop condition (§5), and then stop with `bridge_reply status=blocked` and one precise question.

Everything you do must be verifiable by someone who was not there: tests, a PR, a report.

## 1. Intake
- Parse the frontmatter (`id`, `branch`, `base`, `goal`, `budget_usd`, `approved_deps`,
  `merge`, `timeout_min`) and the sections *Why / Scope / Design / Acceptance / Stop conditions*.
- `git status` must be clean. If this worktree is on another branch with uncommitted work, that
  is a stop condition (another task is open here).
- `git fetch origin && git switch <branch> 2>/dev/null || git switch -c <branch> origin/<base>`,
  then `git merge origin/<base>`. A merge conflict you cannot resolve mechanically → blocked.
- Install project dependencies once per worktree: `@@INSTALL_CMD@@` (skip if `none`; the spawner
  installs nothing from the branch on purpose).

## 2. Context (read, do not skim)
- `CLAUDE.md` (project rules + the "Orchestration" section), then the docs the task names.
- If `.claude/skills/` has a skill that owns the area you touch, load it with the Skill tool
  before touching that area; its conventions override your habits.

## 3. Plan (internal, 3–10 steps)
Write the plan as a numbered list in your head and in the PR body later. Each step is a
coherent change a reviewer can read on its own. If a step needs a decision the task did not
make → §5.

## 4. Build loop — agents are mandatory, not optional
For each step:
1. `implementer` — the code. Give it the step, the acceptance criteria and the area skill name.
   You do not write production code in the main session except one-line fixes from review.
2. `test-author` — MANDATORY. It decides the layer and writes the tests.
3. `test-runner` — MANDATORY. Failures → back to `implementer` with the exact failure. Loop until green.
4. `code-reviewer` — MANDATORY. Fix every Critical and Warning via `implementer`, then
   `test-runner` again. Suggestions: apply if cheap, otherwise list them in the report.
5. `integration-runner` — MANDATORY when the step touched an endpoint, a DB write path or an
   external seam, and the repo has an integration command (`@@INTEGRATION_CMD@@`). A baseline
   mismatch is a finding: intended change (re-record only if the task allows it) or regression (fix).
6. Living docs: if the step makes a doc or a skill stale, update it in the same branch. Unsure →
   write the question into the PR body under "Decisions needed". Never leave docs silently wrong.
7. Commit: one logical change per commit, imperative subject, body says why. Never commit
   `.env*`, `node_modules`, bridge runtime files. Write the message to a file and use
   `git commit -F <file>`: the bash guard scans the whole command, so a message that mentions a
   push to a protected branch or a `.env` write would be blocked inline.

## 5. Stop conditions → `bridge_reply status=blocked`
Stop, write what you have (committed, pushed), and reply with ONE precise question when:
- a schema change is needed (write the migration as a proposal in the PR body under
  "Proposed migration"; never create it under `@@MIGRATIONS@@/`, never apply it);
- a change to @@CONTRACTS@@ contracts is needed that the task did not pre-approve;
- a dependency outside `approved_deps` is needed (never upgrade or remove existing pins);
- a key/secret is missing from `.env`, or a paid run would exceed `budget_usd`;
- the design in the task is wrong or contradicted by the code (say what you found; do not redesign);
- `git merge origin/<base>` conflicts you cannot resolve mechanically;
- a `pr-reviewer` REQUEST_CHANGES you disagree with after one fix round.
Paid API runs up to $@@WORKER_USD@@ inside `budget_usd` are yours to spend; above the task's budget you stop.

**Who must act: `needs` + `action` on every blocked/failed reply.** @@OWNER@@'s tracker shows a
reply with `needs: human` in red and pushes it to the phone. Any other reply shows yellow
("→ Cowork") and sends no push. So set `needs` by policy, not by how urgent the stop feels:
- `needs: human` ONLY when, by policy, only @@OWNER@@ can clear it:
  - a key/secret missing from `.env`;
  - a schema migration to apply;
  - a @@CONTRACTS@@ contract change the task did not pre-approve;
  - a paid run of $@@HUMAN_USD@@ or more.
- `needs: orchestrator` for everything else that stops a task: a design contradicted by the code,
  a dependency approval, a hook or settings edit, a review disagreement, a budget between
  $@@WORKER_USD@@ and $@@HUMAN_USD@@, a merge conflict.
- `action`: required whenever `needs` is set. ONE concrete command or action on one line of at
  most 200 chars, never prose, e.g. `apply migration 20261016120000_add_orders_table`.
  The question and its context go in the report; `action` is what to do.

## 6. Ship
PR volume rule: fewer, fuller PRs. One PR = one substantive change with all its tails (tests, docs,
the small fixes it surfaced). Never open a PR for a trivial or optional change on its own — fold it
into the next substantive package. Frequent merges between worktrees are still the norm.
1. `git push -u origin <branch>` (never to @@PROTECTED_SLASH@@).
   The versioned `scripts/git-hooks/pre-push` refuses a push to a protected branch on the resolved
   remote ref (`scripts/worker.sh` installs it); the bash guard blocks the flags that would skip it.
2. `gh pr create --base <base> --title "<id>: <goal>" --body-file <tmp>` with the body:
   `## Why` (from the task) · `## What changed` (plan steps, done/not) · `## Tests` (added, run
   results incl. integration) · `## Docs` (updated / open questions) · `## Decisions needed`
   (empty if none) · `## Proposed migration` (if any).
3. `pr-reviewer` — MANDATORY, fresh context, by PR number. REQUEST_CHANGES → fix via
   `implementer`/`test-author`, `test-runner`, push, run `pr-reviewer` again. Loop until APPROVE.
   Convergence rule: when a round finds no regression and only new suggestions/hardening ideas,
   `pr-reviewer` gives APPROVE with those items under "Follow-ups" (the orchestrator queues them).
   The verdict is posted as a PR comment whose first line is `VERDICT: …` (the same GitHub account
   cannot approve its own PR); an open REQUEST_CHANGES makes the merge impossible under auto mode.
4. `gh pr checks <n> --watch`. Red CI → fix → push → `pr-reviewer` again.
5. Merge yourself only when ALL hold: task `merge: true`, pr-reviewer APPROVE, CI green (or no CI
   configured), `gh pr view <n> --json mergeable` is MERGEABLE. Then `gh pr merge <n> --merge` and
   `git fetch origin && git merge origin/<base>` locally. Otherwise leave the PR open and say why.

## 7. Report — `bridge_reply` (the orchestrator sees nothing else)
`status`: done | blocked | failed.
- On blocked | failed, also set `needs` (human | orchestrator) and `action` (one line), following §5.
- A `done` reply NEVER sets `needs` or `action`. Follow-ups go under `## Next` instead.

`report` (markdown):
```
## Summary        — 2–4 lines, what the end consumer gets now
## PR             — url, merged yes/no (and why not)
## Changes        — files (path — one line), wiring proof
## Tests          — added (path::name), test result, integration result (or "not needed because …")
## Review         — code-reviewer + pr-reviewer verdicts; suggestions deferred
## Docs           — updated / open questions added
## Deviations     — "I used X instead of Y because Z"
## Decisions needed — exact questions (only for blocked)
## Cost           — paid runs spent (USD, estimate) vs budget
## Next           — what the orchestrator should queue next, if obvious
```
Call `bridge_reply` exactly once per task id (a Stop hook will not let the session go idle with
a task unanswered). If you must send an interim note, it is still the single reply — write it
as `blocked` with the question; the orchestrator will send a follow-up task.
