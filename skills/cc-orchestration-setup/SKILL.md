---
name: cc-orchestration-setup
description: Install, update or repair the cc-orchestration setup (Cowork orchestrating Claude Code workers through the cowork-bridge channel, worker spawner, guards, agent tracker) on a user's Mac and in one of their git repos. Use when the user wants Cowork to run Claude Code workers in a repo, asks to set up / onboard the worker setup, gives the cc-orchestration kit link, or workers fail to start.
---

# cc-orchestration-setup — get a Mac and a repo ready for orchestrated workers

The kit is a git repo, https://github.com/bellzebul/cc-orchestration (usual local clone `~/cc-orchestration`). It contains
`install.sh` (renders the per-repo setup), `mac/` (one-time machine setup, tracker, launchd agents),
`skills/` (this skill and `cc-orchestrator`) and `docs/`. Read the kit's `README.md` and
`docs/TROUBLESHOOTING.md` first — they are the source of truth; this skill is the procedure.

Everything that installs runs on the user's Mac in Terminal, NOT in your sandbox shell: git hooks get
absolute Mac paths, launchd and the tracker live on the Mac. You prepare, explain and verify; the user
pastes commands. Give them ONE block at a time, wait for the output, check it, continue.

## 0. Ask once (then decide everything else yourself)
- Which repo (path on the Mac) and is it on GitHub (owner/repo)?
- Which branch do PRs merge into (BASE), and is there a release branch only humans merge (RELEASE)?
- Do they want the phone tracker (needs the ntfy app)?
If the user is not around, take the detected defaults and say so.

## 1. Machine (once per Mac)
Prerequisites: Homebrew, `git`, `node` ≥ 18, `tmux`, `gh` (logged in: `gh auth login`), Claude Code CLI
(native installer → `~/.local/bin/claude`), a Claude plan that includes Claude Code.
```
git clone https://github.com/bellzebul/cc-orchestration ~/cc-orchestration      # or git -C ~/cc-orchestration pull
~/cc-orchestration/mac/setup.sh --language <their language>
```
`setup.sh` checks the tools, writes the global `~/.claude/CLAUDE.md` section and settings (backups in
`~/.claude/backups/`), and installs the tracker hooks. Restart any Claude Code session that was open.

## 2. Repo
```
~/cc-orchestration/install.sh <repo>          # first run: writes <repo>/.claude/orchestration.conf and stops
```
Read the printed conf with the user. Typical fixes: TEST_CMD = the exact command CI gates on;
INTEGRATION_CMD if they have one; CONTRACTS = their shared-interface path (e.g. `src/shared`);
MIGRATIONS = their migrations dir; OWNER = their name. Then:
```
~/cc-orchestration/install.sh <repo>          # renders, installs the sealed pre-push hook, runs the guard self-test
```
The self-test must end with `guard self-test: all N probes OK`. Then the setup must reach BASE through a
normal PR (workers refuse to start until the trust files are on origin/BASE):
```
cd <repo> && git switch -c chore/cc-orchestration && git add -A && git commit -m "Add cc-orchestration worker setup" \
  && git push -u origin chore/cc-orchestration && gh pr create --base <BASE> --fill
```
After merge: `git switch <BASE> && git pull`. Recommend the CI `concurrency` block printed by install.sh
(cancel superseded PR runs) — the user adds it; workers may not edit workflows.
If the project already has a `CLAUDE.md`, the setup only appends a marked "Orchestration" section; the
project's own rules stay on top and stay the law. If it has none, help them write the project part
(stack, hard rules, where docs live) — workers obey it literally, it is the biggest quality lever.

## 3. Always-on services
```
~/cc-orchestration/mac/launchd/install.sh --spawner <repo> [--spawner <another-repo>]
tail -5 ~/Library/Logs/cc-tracker.log ~/Library/Logs/cc-spawner-*.log
```
Expected: the tracker prints its board URL and ntfy topic; each spawner prints `watching …/spawn`.
`Operation not permitted` → macOS privacy: System Settings → Privacy & Security → Full Disk Access →
`+` → Cmd+Shift+G → `/bin/bash` → enable, then re-run the launchd install.
`claude: not found` in a spawn log → the CLI is outside the PATH the script detected: re-run the launchd
install from a Terminal where `which claude` works.
Phone: ntfy app → subscribe to the topic; open the `http://<mac>.local:7777/?k=…` board → Add to Home Screen.

## 4. Cowork side
- Add the kit's two skills to the user's Claude account (`skills/cc-orchestrator`, this one) if they are
  not there yet (propose them from the kit's SKILL.md files).
- The user connects a folder that contains the repo AND its worktree folder (the parent directory).

## 5. Verify end to end (do not skip)
1. Spawn: write `<repo>/.claude/bridge/spawn/.e2e.tmp`, `mv` to `spawn/e2e` → `spawn-log/e2e.up`
   within ~2 min.
2. Ping: drop `ping-<hhmmss>.md` (only `*.md` is delivered) into `<wt-root>/e2e/.claude/bridge/inbox/` asking for PONG, branch, pwd
   and `git config --get core.hooksPath` → reply in outbox within ~30 s; hooksPath ends in `protected-hooks`.
3. Optional dry run: a tiny real task (a docs typo) that goes PR → review → CI → merge.
4. Cleanup (user runs; deletions are theirs):
   `tmux kill-session -t cc-e2e; git -C <repo> worktree remove --force <wt-root>/e2e; git -C <repo> branch -D feat/e2e`

## Updating
`git -C ~/cc-orchestration pull && ~/cc-orchestration/install.sh <repo>` → PR the diff like any change.
Root-sealed hook (`sudo chown -R root <repo>/.git/protected-hooks`) → install prints the sudo command
to update it. Re-run `mac/launchd/install.sh` after moving the kit or a repo.

## Repair checklist (workers do not start / misbehave)
- `spawn-log/<name>.failed` names the reason: trust files differ from origin/BASE (merge them first),
  invalid branch, dialog not recognised (Claude Code UI changed — see TROUBLESHOOTING), dead pane.
- Permission prompts stall a worker → the tracker shows it red with the command; add the command
  prefix to EXTRA_ALLOW in `orchestration.conf`, re-run install.sh, merge, restart the worker.
- `bash scripts/guard-selftest.sh` in the repo must pass after any guard/hook/settings change.
