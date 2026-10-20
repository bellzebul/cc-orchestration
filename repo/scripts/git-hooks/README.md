# Versioned git hooks

`pre-push` refuses any push whose remote ref is a protected branch (@@PROTECTED_SLASH@@) — a local
stand-in for server-side branch protection, enforced at the resolved-ref level. Keep server-side
protection on too when your GitHub plan has it.

Install once per clone: `scripts/install-git-hooks.sh` — it copies the hook to
`$(git rev-parse --git-common-dir)/protected-hooks/` (outside every working tree, shared by all
worktrees) and sets `core.hooksPath` to that absolute path. `scripts/worker.sh` runs it for every
worker worktree; run it yourself once in the main checkout, and again after changing the hook.
Human override for a deliberate push: `GIT_PUSH_TO_PROTECTED=1 git push origin @@BASE@@`.
Agents cannot set that variable, use `--no-verify`, or change `core.hooksPath` — the bash guard
blocks those spellings and the settings deny `.git/**` writes.
