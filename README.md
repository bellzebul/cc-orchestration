# cc-orchestration

Let Cowork run Claude Code for you: it spawns workers in git worktrees, hands them tasks, and they implement, test, review, open PRs and merge on their own, even overnight. Guarded against pushes to protected branches, with a phone tracker that pings you only when a decision is yours.

Cowork orchestrates Claude Code workers on your Mac. You agree on a design with Cowork; Cowork cuts it
into work packages, starts Claude Code sessions in their own git worktrees, hands them the tasks, watches,
verifies and merges. Each worker implements, tests and reviews its change with dedicated agents,
opens a PR, waits for CI and merges into your base branch. You are pulled in only for the decisions that
are yours (schema migrations, contract changes, secrets, big spend). Your phone buzzes when that happens.

It runs unattended, overnight included: Cowork spawns workers itself, and scheduled wake-ups resume the chain
after usage limits reset.

```
 you ── design ──► Cowork (orchestrator, cc-orchestrator skill)
                     │  spawn/<name>          inbox/<id>.md            outbox/<id>.md
                     ▼                           ▼                          ▲
          worker-spawner (launchd) ──► tmux: claude + cowork-bridge channel ┘
                                         │ implementer → test-author → test-runner → code-reviewer
                                         │ → PR → pr-reviewer → CI → merge into BASE
                                         ▼
                 guards: settings allow/deny · bash-guard hook · sealed pre-push hook · branch-trust
 phone ◄── ntfy ◄── agent tracker (hooks on every session: red = needs you, yellow = Cowork's, blue = CI)
```

## What is in the box
| Path | What it is |
|---|---|
| `install.sh` | Installs/updates the setup into one repo. It writes `.claude/orchestration.conf` (branches, stack, commands, policy) on the first run, then renders the files below into the repo. |
| `repo/` | The per-repo kit: the cowork-bridge channel server (`.claude/bridge`), hooks (bash guard, lint, reply guard), 6 agents, the `work-package` SOP skill, the worker scripts (`worker.sh`, `worker-up.sh`, `worker-spawner.sh`, branch-trust), the sealed pre-push hook, and the `guard-selftest.sh` smoke test. |
| `scripts/worker-retire.sh` (in `repo/`) | Retires a finished worker (merged, clean, no open task): closes its tmux session, removes the worktree, deletes the branch. Cowork requests it, or the spawner's sweep does it after `RETIRE_AFTER_H`. |
| `mac/setup.sh` | One-time machine setup. It checks the tools, writes the global `~/.claude` defaults and installs the tracker hooks. |
| `mac/launchd/install.sh` | Login agents: the tracker server plus one worker spawner per repo. They always run and restart themselves. |
| `mac/tracker/` | The agent tracker: a phone board, plus ntfy pushes for anything that needs you. |
| `skills/` | Two Cowork skills: `cc-orchestrator` (day-to-day operation) and `cc-orchestration-setup` (install and repair). |
| `docs/` | `ARCHITECTURE.md` (how and why), `TROUBLESHOOTING.md`. |
| `tests/run-battery.sh` | The full regression run of the kit: about 740 tests on guards, hooks and worker scripts. |

## Quick start (about 20 minutes)
Hand this README to a Cowork session that has the `cc-orchestration-setup` skill, and it walks you through
the steps. Or run them by hand:

1. **Prerequisites.** You need macOS, Homebrew, `git`, `node` 18 or newer, `tmux`, `gh` (logged in with
   `gh auth login`), the Claude Code CLI, and the Claude desktop app with Cowork.
2. **Machine.** Run `git clone https://github.com/bellzebul/cc-orchestration ~/cc-orchestration && ~/cc-orchestration/mac/setup.sh --language English`.
3. **Repo.** Run `~/cc-orchestration/install.sh ~/code/myapp`. The first run writes the config; check it,
   then run the same command again. Commit the result on a branch and merge it through a PR into your
   base branch.
4. **Services.** Run `~/cc-orchestration/mac/launchd/install.sh --spawner ~/code/myapp`. If `~/Documents`
   is involved, see the Full Disk Access note it prints.
5. **Phone.** Install the ntfy app, subscribe to the topic from `~/Library/Logs/cc-tracker.log`, open the
   board URL and add it to the Home Screen.
6. **Cowork.** Add the two skills from `skills/` to your Claude account. Connect the folder that contains
   the repo and its `<repo>-wt` worktree folder. Then say what to build.

Updating: `git -C ~/cc-orchestration pull && ~/cc-orchestration/install.sh <repo>`, then PR the diff.

## The policy it enforces (change it in `orchestration.conf`)
- **Workers** push only feature branches (`feat/*`, `fix/*`, `chore/*`, `wp*`). They open PRs into BASE
  and merge them themselves when the reviewer approves, CI is green and there are no conflicts. They
  never push to BASE or RELEASE directly. They never edit `.env*`, migrations, CI workflows, Claude
  settings, hooks or git hooks.
- **Money.** A worker may spend up to WORKER_USD on paid API runs. Up to HUMAN_USD, Cowork decides.
  Above that, you do.
- **Dependencies.** New ones only with Cowork's approval. Never upgrades of pinned versions.
- **What comes to you.** Missing secrets, schema migrations (you apply them), contract changes, big spend
  and org/billing matters. Everything else Cowork handles.
- **Volume.** Fewer, fuller PRs: one PR is one substantive change, including its tests and docs.

## Security model (short)
- **Instructions.** Anything that can write a worker's `inbox/` can instruct that worker. The folders are
  local to your Mac, gitignored, and spawn requests are denied to agents.
- **Settings and hooks.** Workers auto-accept the folder-trust dialog. `worker.sh` therefore refuses a
  branch whose settings, MCP config, hooks or bridge code differ from `origin/BASE`, so those files only
  change through a reviewed PR.
- **Existing git hooks.** Hooks the repo already has (husky, pre-commit, a custom `core.hooksPath`)
  keep running: they are chained after the protected-branch check.
- **Node repos.** In a node repo the bridge's own npm dependencies are installed outside the worktree,
  so nothing in the project's `node_modules` can change the bridge's code.
- **Protected branches.** They are guarded three times: settings deny rules, the bash guard (the shell
  spellings) and a pre-push hook installed outside the working tree. The hook checks the resolved refs.
- **Known limit.** Code run through an interpreter can still reach anything your user can. Turn on
  server-side branch protection where your GitHub plan allows it.

## Requirements and limits
- **Platform.** macOS for the always-on parts (launchd, tmux) and the Claude desktop app for Cowork. The
  repo kit itself is plain bash, node and git.
- **Channels.** Claude Code Channels are a research preview: workers start with
  `--dangerously-load-development-channels`. The start-up dialog texts are matched exactly. After a
  Claude Code upgrade, check `docs/TROUBLESHOOTING.md` if spawns start failing.
- **Language.** The tracker UI is in Ukrainian.

## License
MIT — see `LICENSE`.
