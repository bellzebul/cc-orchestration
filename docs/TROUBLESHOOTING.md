# Troubleshooting

| Symptom | Cause → fix |
|---|---|
| `spawn-log/<name>.failed`: "changes trust files … vs origin/BASE" | The worker's branch carries different settings, hooks, MCP or bridge files. Merge those changes to BASE through a PR first, or spawn the worker from a branch based on current BASE. |
| `.failed`: "hit the MCP server consent dialog" | `enabledMcpjsonServers` is missing from `.claude/settings.json`. Re-run `install.sh` and merge. |
| `.failed`: "did not show the channel banner within 120 s" / stuck on a dialog | Claude Code changed a start-up dialog's wording. Run `tmux attach -t cc-<name>`, read the dialog, and update the dialog strings in `repo/scripts/worker-up.sh` in the kit (the `TRUST_DLG`, `DEVCH_DLG`, `RC_DLG`, … block under "Start-up dialogs"). Then re-run `install.sh`. |
| `.failed`: `exec: claude: not found` | The launchd PATH does not include the Claude CLI. Re-run `mac/launchd/install.sh` from a Terminal where `which claude` works. |
| Spawner log: `Operation not permitted` | macOS privacy protects `~/Documents`, `~/Desktop` and `~/Downloads`. Open Full Disk Access → `+` → `/bin/bash`, then re-run `mac/launchd/install.sh`. |
| `launchctl bootstrap … Input/output error` | The old agent was still unloading. Re-run the launchd installer, which waits for it now. |
| A worker sits red on the tracker: "Дозвіл: Bash: …" | The command is not in the allow list. Attach (`tmux attach -t cc-<name>`, detach with `Ctrl-b d`) and answer it. Then add the prefix to `EXTRA_ALLOW` in `orchestration.conf`, re-run `install.sh` and merge, so it never asks again. |
| The board does not open on the phone | The Mac's IP changed. Use `http://<mac-name>.local:7777/?k=…` from `~/Library/Logs/cc-tracker.log`; the phone must be on the same Wi-Fi. |
| No pushes | Check the ntfy app's subscription to the topic in `mac/tracker/ntfy-topic`. `NTFY=0` in the agent's environment disables pushes. |
| `gh pr merge` refused in auto mode | An open REQUEST_CHANGES review. `pr-reviewer` posts `VERDICT:` comments instead of formal reviews. Converge per the task's merge rule. |
| The worker cannot push: "pre-push: refusing …" | Working as intended for protected branches. For a feature branch, check that `git config --get core.hooksPath` points at `protected-hooks` and that the hook was re-installed after the config changed (`install.sh` does it). |
| Guard blocks something legitimate | Add the case to the kit's `tests/guard_battery.jsonl` as `pass`. Fix the guard by adding a narrower rule, never by replacing one. Run `tests/run-battery.sh`. |
| `install.sh`: "guard self-test failed" | The installed pre-push copy is stale (root-sealed) or a render went wrong. Run the printed `sudo cp` command, or re-run `install.sh`. |
| Workers stall overnight | Usage limits. Ask Cowork to set scheduled wake-ups before you leave, and switch them to automatic approval. |
| Cowork cannot see the worktrees | Connect the parent folder that holds both `<repo>` and `<repo>-wt`. |
