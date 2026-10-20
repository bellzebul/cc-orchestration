#!/usr/bin/env node
// Claude Code hook: records the session's current state into state/<session_id>.json.
// Must be fast, print nothing (stdout of some hooks is injected into the model context)
// and never fail — every error is swallowed and the process exits 0.
import { readFileSync, writeFileSync, renameSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const STATE_DIR = join(dirname(fileURLToPath(import.meta.url)), "state");

const clip = (s, n) => (typeof s === "string" ? (s.length > n ? s.slice(0, n - 1) + "…" : s) : null);

// Walk up the process tree to the Claude Code process, so the server can tell a dead session
// from a quiet one. Only done once per session (the pid is cached in the state file).
function findClaudePid() {
  let pid = process.ppid;
  for (let i = 0; i < 6 && pid > 1; i++) {
    try {
      const out = execFileSync("ps", ["-o", "ppid=,command=", "-p", String(pid)], { encoding: "utf8", timeout: 500 }).trim();
      const m = out.match(/^(\d+)\s+(.*)$/);
      if (!m) return null;
      if (/(^|\/)claude(\s|$)/.test(m[2]) || /claude-code|@anthropic-ai/.test(m[2])) return pid;
      pid = Number(m[1]);
    } catch { return null; }
  }
  return null;
}

function toolDetail(name, input = {}) {
  if (name === "Bash") return clip(input.command, 160);
  if (input.file_path) return input.file_path;
  if (input.pattern) return clip(input.pattern, 120);
  if (input.description) return clip(input.description, 120);
  if (input.url) return clip(input.url, 160);
  return null;
}

function main() {
  const ev = JSON.parse(readFileSync(0, "utf8"));
  const id = ev.session_id;
  if (!id || !/^[\w-]+$/.test(id)) return;
  mkdirSync(STATE_DIR, { recursive: true });
  const file = join(STATE_DIR, `${id}.json`);
  let s = {};
  try { s = JSON.parse(readFileSync(file, "utf8")); } catch {}

  const now = new Date().toISOString();
  const setState = (st) => { if (s.state !== st) { s.state = st; s.since = now; } };

  s.session_id = id;
  s.cwd = ev.cwd || s.cwd;
  s.transcript_path = ev.transcript_path || s.transcript_path;
  s.first_seen ??= now;
  s.last_event = ev.hook_event_name;
  s.last_event_at = now;
  if (!s.pid) s.pid = findClaudePid();

  switch (ev.hook_event_name) {
    case "SessionStart":
      if (ev.source === "compact" && s.state) break;  // compaction mid-work: keep state
      setState("idle"); s.headline = "Сесія запущена, чекає завдання"; s.tool = null;
      s.ended = false;
      break;
    case "UserPromptSubmit":
      setState("working"); s.prompt = clip(ev.prompt, 400); s.headline = clip(ev.prompt, 140); s.tool = null;
      break;
    case "PreToolUse":
      // These tools stop and wait for a click/answer in the terminal.
      if (ev.tool_name === "AskUserQuestion") {
        setState("waiting"); s.tool = ev.tool_name;
        const q = ev.tool_input?.questions?.[0]?.question;
        s.headline = clip(q ? `Питання: ${q}` : "Питання в терміналі", 200);
        break;
      }
      if (ev.tool_name === "ExitPlanMode") {
        setState("waiting"); s.tool = ev.tool_name; s.headline = "Чекає підтвердження плану";
        break;
      }
      setState("working"); s.tool = ev.tool_name; s.tool_started_at = now;
      s.headline = [ev.tool_name, toolDetail(ev.tool_name, ev.tool_input)].filter(Boolean).join(": ");
      break;
    case "PostToolUse":
      setState("working"); s.tool = null;
      break;
    case "Notification": {
      const msg = ev.message || "";
      const type = ev.notification_type || "";
      if (type === "permission_prompt" || type === "elicitation_dialog" || /permission|approv|needs your/i.test(msg)) {
        setState("waiting");
        // PreToolUse already fired for the tool being asked about, so s.headline holds
        // "Bash: <command>" — far more useful on the phone than Claude's generic message.
        s.headline = clip(s.tool && s.headline ? `Дозвіл: ${s.headline}` : msg, 200);
      } else if (type === "idle_prompt" || /waiting for your input/i.test(msg)) {
        if (s.state !== "waiting") setState("idle");
      } else {
        return;  // other notifications (auth etc.) don't change the state
      }
      break;
    }
    case "Stop":
      setState("idle"); s.tool = null; s.headline = "Хід завершено";
      break;
    case "SessionEnd":
      s.ended = true; s.ended_at = now; setState("dead"); s.headline = `Сесія закрита (${ev.reason || "exit"})`;
      break;
    default:
      return;
  }

  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(s));
  renameSync(tmp, file);
}

try { main(); } catch {}
process.exit(0);
