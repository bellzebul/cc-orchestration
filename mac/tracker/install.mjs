#!/usr/bin/env node
// Adds (or with --uninstall removes) the status hooks in the user-level ~/.claude/settings.json.
// Idempotent: our entries are recognised by the hook.mjs path; a timestamped backup is written first.
import { existsSync, readFileSync, writeFileSync, copyFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HOOK = join(dirname(fileURLToPath(import.meta.url)), "hook.mjs");
const SETTINGS = join(homedir(), ".claude", "settings.json");
const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"];
const TOOL_EVENTS = new Set(["PreToolUse", "PostToolUse"]);
const uninstall = process.argv.includes("--uninstall");

mkdirSync(dirname(SETTINGS), { recursive: true });
let cfg = {};
if (existsSync(SETTINGS)) {
  cfg = JSON.parse(readFileSync(SETTINGS, "utf8"));
  copyFileSync(SETTINGS, `${SETTINGS}.bak-${Date.now()}`);
}
cfg.hooks ??= {};
const ours = (h) => typeof h?.command === "string" && h.command.includes(HOOK);

for (const ev of EVENTS) {
  // Drop our previous entries, keep everything else untouched.
  const groups = (cfg.hooks[ev] || [])
    .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !ours(h)) }))
    .filter((g) => g.hooks.length);
  if (!uninstall) {
    const group = { hooks: [{ type: "command", command: `node "${HOOK}"`, timeout: 5 }] };
    if (TOOL_EVENTS.has(ev)) group.matcher = "*";
    groups.push(group);
  }
  if (groups.length) cfg.hooks[ev] = groups; else delete cfg.hooks[ev];
}
if (!Object.keys(cfg.hooks).length) delete cfg.hooks;

writeFileSync(SETTINGS, JSON.stringify(cfg, null, 2) + "\n");
console.log(`${uninstall ? "Removed" : "Installed"} agent-tracker hooks in ${SETTINGS}`);
if (!uninstall) console.log("Restart running Claude Code sessions (or open /hooks in them) so they pick the hooks up.");
