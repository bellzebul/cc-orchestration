#!/usr/bin/env node
// Tiny LAN server for the phone status board. No dependencies.
// Reads state/*.json written by hook.mjs, enriches it (branch, bridge report, last message,
// liveness) and serves public/index.html + GET /api/sessions.
import http from "node:http";
import os from "node:os";
import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync, unlinkSync, openSync, readSync, closeSync } from "node:fs";
import { dirname, join, basename, extname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(fileURLToPath(import.meta.url));
const STATE_DIR = join(ROOT, "state");
const PUBLIC_DIR = join(ROOT, "public");
const PORT = Number(process.env.PORT || 7777);
const HIDE_DEAD_AFTER_MS = 2 * 3600e3;      // dead sessions disappear from the board
const DELETE_STATE_AFTER_MS = 24 * 3600e3;  // and their state files are cleaned up
const SILENT_DEAD_MS = 6 * 3600e3;          // no pid known + silent this long → dead

const TOKEN_FILE = join(ROOT, "token");
if (!existsSync(TOKEN_FILE)) writeFileSync(TOKEN_FILE, randomBytes(12).toString("hex"));
const TOKEN = readFileSync(TOKEN_FILE, "utf8").trim();

const clip = (s, n) => (typeof s === "string" ? (s.length > n ? s.slice(0, n - 1) + "…" : s) : null);
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };

// --- small TTL caches -------------------------------------------------------------------
const cache = new Map();
function cached(key, ttlMs, fn) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < ttlMs) return hit.v;
  const v = fn();
  cache.set(key, { t: Date.now(), v });
  return v;
}

function gitBranch(cwd) {
  return cached(`br:${cwd}`, 15e3, () => {
    try { return execFileSync("git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8", timeout: 1500, stdio: ["ignore", "pipe", "ignore"] }).trim(); }
    catch { return null; }
  });
}

function alive(pid) {
  if (!pid) return null;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
}

function newestFile(dir, ext) {
  try {
    let best = null;
    for (const f of readdirSync(dir)) {
      if (ext && extname(f) !== ext) continue;
      const m = mtime(join(dir, f));
      if (!best || m > best.m) best = { f, m };
    }
    return best;
  } catch { return null; }
}

// Bridge worker: latest task taken (processed/) and latest reply (outbox/) in this worktree.
function bridgeInfo(cwd, sinceMs) {
  const base = join(cwd, ".claude", "bridge");
  if (!existsSync(base)) return { task: null, report: null };
  const task = newestFile(join(base, "processed"), ".md");
  const rep = newestFile(join(base, "outbox"), ".md");
  const taskId = task && task.m >= sinceMs ? basename(task.f, ".md") : null;
  let report = null;
  if (rep && rep.m >= sinceMs) {
    report = cached(`rep:${cwd}:${rep.f}:${rep.m}`, 3600e3, () => {
      const txt = readFileSync(join(base, "outbox", rep.f), "utf8");
      const fm = {};
      const m = txt.match(/^---\n([\s\S]*?)\n---/);
      if (m) for (const line of m[1].split("\n")) { const i = line.indexOf(":"); if (i > 0) fm[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
      const body = m ? txt.slice(m[0].length) : txt;
      const sm = body.match(/##\s*Summary\s*\n+([\s\S]*?)(\n##\s|$)/);
      const pr = body.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/);
      return {
        id: fm.id || basename(rep.f, ".md"),
        status: fm.status || null,
        needs: fm.needs || null,     // human | orchestrator (optional, set by bridge_reply)
        action: fm.action || null,   // the one thing the human has to do
        at: fm.at || new Date(rep.m).toISOString(),
        summary: clip((sm ? sm[1] : body).replace(/\*\*/g, "").trim(), 600),
        pr_url: pr ? pr[0] : null,
        mtime: rep.m,
      };
    });
  }
  return { task: taskId, taskMtime: task?.m ?? 0, report };
}

// Last assistant text from the session transcript (reads only the tail of the JSONL).
function lastAssistantText(path) {
  if (!path) return null;
  const m = mtime(path);
  if (!m) return null;
  return cached(`tr:${path}:${m}`, 3600e3, () => {
    let fd;
    try {
      fd = openSync(path, "r");
      const size = statSync(path).size;
      const len = Math.min(size, 512 * 1024);
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, size - len);
      const lines = buf.toString("utf8").split("\n").reverse();
      for (const line of lines) {
        if (!line.includes('"assistant"')) continue;
        try {
          const j = JSON.parse(line);
          if (j.type !== "assistant" || j.isSidechain) continue;
          const parts = (j.message?.content || []).filter((c) => c.type === "text").map((c) => c.text);
          if (parts.length) return clip(parts.join("\n").trim(), 600);
        } catch {}
      }
    } catch {} finally { if (fd !== undefined) closeSync(fd); }
    return null;
  });
}


// --- "external" (blue): the agent is only waiting for a shell command (CI watch, tests, sleep) ----
// Claude Code runs every Bash call as `<shell> -c "source …/shell-snapshots/… && eval '<cmd>' …"`,
// so a descendant with that marker is a command the session is waiting on (MCP servers don't have it).
const FOREGROUND_WAIT_MS = 30e3;  // a single foreground Bash call longer than this counts as waiting
function procTable() {
  return cached("ps", 2e3, () => {
    try {
      const out = execFileSync("ps", ["-A", "-o", "pid=,ppid=,command="], { encoding: "utf8", timeout: 2000, maxBuffer: 16 << 20 });
      const rows = [];
      for (const line of out.split("\n")) {
        const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
        if (m) rows.push({ pid: +m[1], ppid: +m[2], cmd: m[3] });
      }
      return rows;
    } catch { return []; }
  });
}
function waitingShell(rootPid) {
  if (!rootPid) return null;
  const rows = procTable();
  const kids = new Map();
  for (const r of rows) { if (!kids.has(r.ppid)) kids.set(r.ppid, []); kids.get(r.ppid).push(r); }
  const stack = [...(kids.get(rootPid) || [])];
  while (stack.length) {
    const r = stack.pop();
    if (/shell-snapshots|claude-[\w-]*-cwd/.test(r.cmd)) {
      const m = r.cmd.match(/eval '((?:[^']|'\\'')*)'/) || r.cmd.match(/eval "((?:[^"\\]|\\.)*)"/);
      const raw = m ? m[1].replace(/'\\''/g, "'") : r.cmd.replace(/^.*?shell-snapshots\S*\s*&&\s*/, "");
      return clip(raw.trim(), 140);
    }
    stack.push(...(kids.get(r.pid) || []));
  }
  return null;
}

const RANK = { waiting: 0, idle: 1, external: 2, working: 3, dead: 4 };

function sessions() {
  const now = Date.now();
  const out = [];
  let files = [];
  try { files = readdirSync(STATE_DIR).filter((f) => f.endsWith(".json")); } catch {}
  for (const f of files) {
    const p = join(STATE_DIR, f);
    let s;
    try { s = JSON.parse(readFileSync(p, "utf8")); } catch { continue; }
    const lastMs = Date.parse(s.last_event_at) || mtime(p);

    let state = s.state || "idle";
    let since = s.since || s.last_event_at;
    let headline = s.headline || null;
    const isAlive = alive(s.pid);
    if (s.ended || isAlive === false || (isAlive === null && now - lastMs > SILENT_DEAD_MS)) {
      if (state !== "dead") { state = "dead"; since = s.ended_at || s.last_event_at; headline = s.ended ? headline : "Процес не знайдено"; }
    }
    if (state === "dead" && now - (Date.parse(since) || lastMs) > HIDE_DEAD_AFTER_MS) {
      if (now - lastMs > DELETE_STATE_AFTER_MS) { try { unlinkSync(p); } catch {} }
      continue;
    }

    const cwd = s.cwd || "";
    const firstMs = Date.parse(s.first_seen) || 0;
    const { task, taskMtime, report } = cwd ? bridgeInfo(cwd, firstMs) : { task: null, report: null };
    const lastMessage = lastAssistantText(s.transcript_path);

    // A bridge worker that answered its newest task with blocked/failed is waiting on a human.
    const answered = report && (!task || report.id === task || report.mtime >= taskMtime);
    if (state === "idle" && answered) {
      if ((report.status === "blocked" || report.status === "failed") && report.needs === "human") {
        // The worker says only the human can unblock it (migration, .env key, paid run ≥ $50 …).
        state = "waiting"; since = report.at || since;
        headline = `Треба ти: ${report.action || report.id}`;
      } else if (report.status === "blocked" || report.status === "failed") {
        // Cowork reads the report and answers; only a terminal prompt means the human must click.
        headline = `${report.status === "failed" ? "Звіт failed" : "Звіт blocked"}: ${report.id} → Cowork`;
      } else if (report.status === "done") {
        headline = `Готово: ${report.id}`;
      }
    } else if (state === "idle" && lastMessage && (!headline || headline === "Хід завершено")) {
      headline = clip(lastMessage.split("\n").find((l) => l.trim()) || lastMessage, 140);
    }

    // Blue: nothing for the human or Cowork to do — the session waits on a command it started.
    if (state === "idle" && isAlive) {
      const cmd = waitingShell(s.pid);
      if (cmd) { state = "external"; headline = `Чекає: ${cmd}`; }
    } else if (state === "working" && s.tool === "Bash" && s.tool_started_at &&
               now - Date.parse(s.tool_started_at) >= FOREGROUND_WAIT_MS) {
      state = "external"; since = s.tool_started_at;
      headline = `Чекає: ${(s.headline || "").replace(/^Bash: /, "")}`;
    }

    out.push({
      id: s.session_id,
      name: basename(cwd) || s.session_id.slice(0, 8),
      branch: cwd ? gitBranch(cwd) : null,
      cwd,
      state,
      since,
      last_event_at: s.last_event_at,
      headline,
      tool: state === "working" || state === "external" ? s.tool || null : null,
      task,
      report: report ? { id: report.id, status: report.status, at: report.at, summary: report.summary, needs: report.needs, action: report.action } : null,
      last_message: lastMessage,
      prompt: s.prompt || null,
      pr_url: report?.pr_url || null,
    });
  }
  out.sort((a, b) => RANK[a.state] - RANK[b.state] || Date.parse(a.since) - Date.parse(b.since));
  return out;
}

// --- http -------------------------------------------------------------------------------
const TYPES = { ".html": "text/html; charset=utf-8", ".json": "application/json", ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml", ".js": "text/javascript", ".css": "text/css", ".mp4": "video/mp4" };

function authed(req, url) {
  if (url.searchParams.get("k") === TOKEN) return "set";
  const c = req.headers.cookie || "";
  return c.split(/;\s*/).includes(`ccd=${TOKEN}`) ? "ok" : null;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const auth = authed(req, url);
  const headers = { "Cache-Control": "no-store" };
  if (auth === "set") headers["Set-Cookie"] = `ccd=${TOKEN}; Path=/; Max-Age=31536000; SameSite=Strict; HttpOnly`;

  // The manifest and icons must load without the cookie (iOS fetches them separately).
  const publicAsset = /^\/(manifest\.webmanifest|icon[\w-]*\.(png|svg))$/.test(url.pathname);
  if (!auth && !publicAsset) {
    res.writeHead(401, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end("Відкрий посилання з ?k=<token> (його друкує сервер при старті).");
  }

  if (url.pathname === "/api/sessions") {
    res.writeHead(200, { ...headers, "Content-Type": "application/json" });
    return res.end(JSON.stringify({ now: new Date().toISOString(), sessions: sessions() }));
  }

  const rel = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
  if (rel.includes("..")) { res.writeHead(400); return res.end(); }
  const file = join(PUBLIC_DIR, rel);
  if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end("not found"); }
  res.writeHead(200, { ...headers, "Content-Type": TYPES[extname(file)] || "application/octet-stream" });
  res.end(readFileSync(file));
});


// --- push notifications via ntfy ---------------------------------------------------------
// The phone subscribes to a private random topic in the ntfy app; it vibrates when a session
// starts waiting on the human, goes idle, or dies unexpectedly. Disable with NTFY=0.
const NTFY_SERVER = process.env.NTFY_SERVER || "https://ntfy.sh";
const TOPIC_FILE = join(ROOT, "ntfy-topic");
if (!existsSync(TOPIC_FILE)) writeFileSync(TOPIC_FILE, `cc-${randomBytes(9).toString("hex")}`);
const TOPIC = readFileSync(TOPIC_FILE, "utf8").trim();
const NTFY_ON = process.env.NTFY !== "0" && typeof fetch === "function";
// Debounce: a state must hold this long before we buzz (permission prompts often clear fast).
const DELAY_MS = { waiting: 20e3, idle: 10 * 60e3, dead: 10e3 };
const REMIND_WAITING_MS = 15 * 60e3;  // one reminder if still waiting after this
const LABEL = { waiting: "Чекає тебе", idle: "Без роботи", dead: "Впала" };
const notified = new Map();  // `${id}|${since}` → { first, reminded }
let boardUrl = null;

async function push(s, reminder) {
  const title = `${reminder ? "Досі " + LABEL[s.state].toLowerCase() : LABEL[s.state]} · ${s.name}`;
  try {
    // JSON publishing keeps Cyrillic titles intact (HTTP header values must be Latin-1).
    const r = await fetch(NTFY_SERVER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        topic: TOPIC,
        title,
        message: clip(s.headline || s.branch || "", 200) || " ",
        priority: s.state === "waiting" ? 5 : 3,
        tags: [s.state === "waiting" ? "rotating_light" : s.state === "idle" ? "pause_button" : "skull"],
        ...(boardUrl ? { click: boardUrl } : {}),
      }),
    });
    if (!r.ok) console.error("ntfy push failed: HTTP", r.status);
  } catch (e) { console.error("ntfy push failed:", e.message); }
}

let seeded = false;
function notifyTick() {
  const now = Date.now();
  let list;
  try { list = sessions(); } catch { return; }
  const live = new Set();
  for (const s of list) {
    if (!LABEL[s.state]) continue;
    if (s.state === "dead" && /закрита/.test(s.headline || "")) continue;  // normal exit: no buzz
    const key = `${s.id}|${s.state}|${s.since}`;
    live.add(key);
    // Whatever is already red/amber when the server starts is on the screen; don't burst.
    if (!seeded) { notified.set(key, { first: true, reminded: true }); continue; }
    const age = now - (Date.parse(s.since) || now);
    const n = notified.get(key) || { first: false, reminded: false };
    if (!n.first && age >= DELAY_MS[s.state]) { n.first = true; push(s, false); }
    else if (s.state === "waiting" && n.first && !n.reminded && age >= REMIND_WAITING_MS) { n.reminded = true; push(s, true); }
    notified.set(key, n);
  }
  for (const k of notified.keys()) if (!live.has(k)) notified.delete(k);
  seeded = true;
}
if (NTFY_ON) setInterval(notifyTick, 5000);

server.listen(PORT, "0.0.0.0", () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter((i) => i && i.family === "IPv4" && !i.internal).map((i) => i.address);
  const host = (() => { try { return execFileSync("scutil", ["--get", "LocalHostName"], { encoding: "utf8" }).trim() + ".local"; } catch { return os.hostname(); } })();
  console.log(`agent tracker on :${PORT}. Open on the phone (same Wi-Fi):`);
  console.log(`  http://${host}:${PORT}/?k=${TOKEN}`);
  for (const ip of ips) console.log(`  http://${ip}:${PORT}/?k=${TOKEN}`);
  const lan = ips.find((ip) => /^(192\.168|10\.|172\.(1[6-9]|2\d|3[01]))\./.test(ip)) || ips[0];
  // The .local name survives DHCP changing the Mac's IP; the push's click-through uses it when mDNS works.
  boardUrl = `http://${host.endsWith(".local") ? host : (lan || host)}:${PORT}/?k=${TOKEN}`;
  if (NTFY_ON) console.log(`Push: install the ntfy app, subscribe to topic  ${TOPIC}  (server ${NTFY_SERVER})`);
  else console.log("Push: off (NTFY=0 or no fetch in this Node).");
});
