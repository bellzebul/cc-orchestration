<!-- cc-orchestration:begin — rendered by cc-orchestration/install.sh; edit .claude/orchestration.conf and re-run instead of editing here -->
## Orchestration (Cowork → Claude Code workers)

This repo runs in two modes. Which one applies is decided by how the task arrived.

**A. Orchestrated work package** — a `<channel source="cowork-bridge">` event, or a pasted task with
the bridge frontmatter (`id / branch / base / goal / budget_usd / approved_deps / merge`). The
`work-package` skill is the full SOP; load it first. In short:
- The task IS the approval: its Design section was agreed with @@OWNER@@ by the orchestrator. Do not
  stop for plan sign-off, do not re-decide, do not ask "should I proceed".
- Build loop with mandatory agents: `implementer` → `test-author` → `test-runner` → `code-reviewer`
  → (`integration-runner`) → commit → PR → `pr-reviewer` (fresh context) → CI green → merge into
  `@@BASE@@` only when the task says `merge: true`, pr-reviewer APPROVEd, CI is green and there are no
  conflicts. Merge `origin/@@BASE@@` into the branch before starting and before the PR.
- Stop only on a stop condition (schema change, @@CONTRACTS@@ contract change, a dependency not in
  `approved_deps`, missing `.env` key, budget exceeded, design contradicted by the code, unresolvable
  conflict) — then `bridge_reply status=blocked` with ONE precise question. The orchestrator sees
  nothing but `bridge_reply`.

**B. Interactive session** — a human typing in the terminal: propose the design and wait for
approval before implementing; one change at a time; say what changed and why.

**Both modes — hard limits (enforced by `.claude/settings.json`, `.claude/hooks/bash-guard.sh` and the
sealed pre-push hook; never try to get around them):**
- Never push to @@PROTECTED_SLASH@@. Work on `feat/*`, `fix/*`, `chore/*` or `wp*` branches; PRs target `@@BASE@@`.
- Never edit `.env*`, `.github/workflows/`, `@@MIGRATIONS@@/`, `.claude/settings*.json`, `.claude/hooks/`,
  `scripts/git-hooks/`, `.claude/orchestration.conf`. These are human/orchestrator-owned.
- Dependencies: add only packages listed in `approved_deps`, by name; never upgrade or remove pins.
- Paid API runs: up to $@@WORKER_USD@@ within the task budget; above that, stop.
- Commit messages via `git commit -F <file>`.

**Commands**
- Install deps: `@@INSTALL_CMD@@`
- Test gate (same as CI): `@@TEST_CMD@@`
- Lint: `@@LINT_CMD@@`
- Integration suite: `@@INTEGRATION_CMD@@`

**Agents (`.claude/agents/`)**: `implementer` (code) · `test-author` (tests) · `test-runner` (gate,
failures only) · `integration-runner` (integration, failures only) · `code-reviewer` (diff review,
read-only) · `pr-reviewer` (merge gate, fresh context). Agent memory lives in
`.claude/agent-memory/<agent>/` and is shared by the team.
<!-- cc-orchestration:end -->
