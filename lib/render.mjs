#!/usr/bin/env node
// Renders the cc-orchestration repo kit (../repo) into a target git repository.
//   node lib/render.mjs --target <repo-dir> [--dry-run]
// Reads <target>/.claude/orchestration.conf (KEY=value lines, written by install.sh), fills the
// @@PLACEHOLDERS@@, merges settings.json / .mcp.json / CLAUDE.md / .gitignore with what is already
// there, and copies the rest. Idempotent: re-run it after editing orchestration.conf or pulling a
// newer kit. Never touches .github/workflows, .env or anything outside the target.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const KIT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SRC = path.join(KIT, "repo");
const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const target = path.resolve(opt("--target") ?? ".");
const dry = args.includes("--dry-run");
const die = (m) => { console.error(`render: ${m}`); process.exit(1); };

// ---------- config ----------
const confPath = path.join(target, ".claude", "orchestration.conf");
if (!fs.existsSync(confPath)) die(`${confPath} not found — run install.sh first`);
const conf = {};
for (const raw of fs.readFileSync(confPath, "utf8").split(/\r?\n/)) {
  const line = raw.trim();
  if (!line || line.startsWith("#")) continue;
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (!m) die(`bad line in orchestration.conf: ${raw}`);
  let v = m[2].replace(/\s+#.*$/, "").trim();   // inline comments start with whitespace + #
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  conf[m[1]] = v;
}
const need = (k) => { if (conf[k] === undefined || conf[k] === "") die(`orchestration.conf: ${k} is required`); return conf[k]; };
const none = (v) => !v || v === "none";
const words = (v) => (none(v) ? [] : v.split(/[\s,]+/).filter(Boolean));
const check = (k, v, re, what) => { if (!re.test(v)) die(`orchestration.conf: ${k}=${JSON.stringify(v)} — ${what}`); return v; };
const BR = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const SAFE_TEXT = /^[^`'"\n\r\\$]*$/;           // goes into markdown, JS strings and bash comments
const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

const BASE = check("BASE", need("BASE"), BR, "a plain branch name");
const RELEASE = none(conf.RELEASE) ? "" : check("RELEASE", conf.RELEASE, BR, "a plain branch name or none");
if (RELEASE && RELEASE === BASE) die("orchestration.conf: RELEASE must differ from BASE (use RELEASE=none when PRs merge into the release branch)");
const PROTECTED = [...new Set([BASE, ...(RELEASE ? [RELEASE] : []), ...words(conf.PROTECTED)])];
PROTECTED.forEach((b) => { check("PROTECTED", b, BR, "plain branch names"); if (b.includes("..")) die("PROTECTED: '..' not allowed"); });
const NOREL = "__cc_no_release_branch__";
const repoName = path.basename(target);
const WT_DIR = check("WT_DIR", conf.WT_DIR || `${repoName.replace(/[^A-Za-z0-9._-]+/g, "-")}-wt`, /^[A-Za-z0-9._-]+$/, "a folder name (letters, digits, . _ -)");
const GH_REPO = none(conf.GH_REPO) ? "" : check("GH_REPO", conf.GH_REPO, /^[\w.-]+\/[\w.-]+$/, "owner/repo");
const ENV_FILES = words(conf.ENV_FILES ?? ".env .env.test");
ENV_FILES.forEach((f) => check("ENV_FILES", f, /^\.env[\w.-]*$/, ".env-style file names"));
const MIGRATIONS = none(conf.MIGRATIONS) ? "" : check("MIGRATIONS", conf.MIGRATIONS.replace(/\/+$/, ""), /^[A-Za-z0-9._/-]+$/, "a relative path or none");
const OWNER = check("OWNER", conf.OWNER || "the owner", /^[\p{L}\p{N} ._-]{1,40}$/u, "letters, digits, space, . _ -");
const CONTRACTS = check("CONTRACTS", conf.CONTRACTS || "shared-interface", SAFE_TEXT, "no quotes, backticks, $ or newlines");
const WORKER_USD = check("WORKER_USD", conf.WORKER_USD || "10", /^\d+$/, "a whole number");
const HUMAN_USD = check("HUMAN_USD", conf.HUMAN_USD || "50", /^\d+$/, "a whole number");
const cmd = (k) => check(k, conf[k] || "none", /^[^`\n\r]*$/, "one line, no backticks");
const INSTALL_CMD = cmd("INSTALL_CMD"), TEST_CMD = cmd("TEST_CMD"), LINT_CMD = cmd("LINT_CMD"), INTEGRATION_CMD = cmd("INTEGRATION_CMD");
const LINT_FILE_CMD = none(conf.LINT_FILE_CMD) ? "" : check("LINT_FILE_CMD", conf.LINT_FILE_CMD, /^[^\n\r`]*$/, "one line");
const LINT_EXT = words(conf.LINT_EXT);
LINT_EXT.forEach((e) => check("LINT_EXT", e, /^[A-Za-z0-9]+$/, "extensions without dots"));
const STACK = conf.STACK || "generic";
const EXTRA_ALLOW = (conf.EXTRA_ALLOW || "").split(",").map((s) => s.trim()).filter(Boolean);
EXTRA_ALLOW.forEach((e) => check("EXTRA_ALLOW", e, /^[^\n\r`()]+$/, "comma-separated command prefixes"));

const P = {
  BASE, RELEASE: RELEASE || "(no release branch)",
  PROTECTED_ALT: PROTECTED.map(escRe).join("|"),
  PROTECTED_CASE: PROTECTED.join("|"),
  PROTECTED_SLASH: PROTECTED.join(", "),
  PROTECTED_WORDS: PROTECTED.join(" "),
  PROTECTED_REFS_CASE: PROTECTED.map((b) => `refs/heads/${b}`).join("|"),
  RELEASE_ALT: RELEASE ? escRe(RELEASE) : NOREL,
  RELEASE_CASE: RELEASE || NOREL,
  WT_DIR, GH_REPO, ENV_FILES: ENV_FILES.join(" "),
  // Node repos keep package.json/node_modules at the worktree root, so the bridge's deps live outside it.
  BRIDGE_DEPS: STACK === "node" ? "isolated" : "inplace",
  TRUST_ROOT_NPM: STACK === "node" ? "" : "package.json .npmrc node_modules",
  MIGRATIONS: MIGRATIONS || "the migrations folder", MIGRATIONS_RE: MIGRATIONS ? escRe(MIGRATIONS) : "__cc_no_migrations__",
  OWNER, CONTRACTS, WORKER_USD, HUMAN_USD,
  INSTALL_CMD, TEST_CMD, LINT_CMD, INTEGRATION_CMD,
  LINT_FILE_CMD, LINT_EXT_CASE: LINT_EXT.map((e) => `*.${e}`).join("|") || "__cc_no_lint__",
};
const KNOWN_LITERALS = new Set(["GUARD_PASS_SPLIT"]);   // the guard's own marker, not a placeholder
const fill = (text, file) => {
  const out = text.replace(/@@([A-Z_]+)@@/g, (m, k) => (k in P ? P[k] : KNOWN_LITERALS.has(k) ? m : die(`${file}: unknown placeholder ${m}`)));
  return out;
};

// ---------- write helpers ----------
const written = [];
const write = (rel, content, mode) => {
  const dst = path.join(target, rel);
  written.push(rel);
  if (dry) return;
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.writeFileSync(dst, content);
  if (mode) fs.chmodSync(dst, mode);
};
const read = (rel) => { try { return fs.readFileSync(path.join(target, rel), "utf8"); } catch { return null; } };
const backup = (rel) => { const cur = read(rel); if (cur !== null && !dry) fs.writeFileSync(path.join(target, `${rel}.bak-cc`), cur); };

// ---------- plain files ----------
const SKIP = new Set(["CLAUDE.orchestration.md", ".mcp.json", "gitignore.snippet", ".claude/hooks/lint-after-edit.sh"]);
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const p = path.join(dir, e.name);
  return e.isDirectory() ? walk(p) : [path.relative(SRC, p)];
});
// Agents and skills are starting points a team tunes to its repo: a file that differs from what we rendered
// last time (or that existed before us) is kept, and the new version is written next to it as <file>.cc-new.
// Infrastructure (bridge, hooks, scripts) is always replaced — the guards must match the kit.
const sha = (t) => createHash("sha256").update(t).digest("hex");
let prevRendered = {};
try { prevRendered = JSON.parse(read(".claude/orchestration.rendered.json") ?? "{}").files ?? {}; } catch {}
const renderedHashes = {};
const customizable = (rel) => rel.startsWith(".claude/agents/") || rel.startsWith(".claude/skills/");
const kept = [];
for (const rel of walk(SRC)) {
  if (SKIP.has(rel)) continue;
  const text = fill(fs.readFileSync(path.join(SRC, rel), "utf8"), rel);
  const exec = rel.endsWith(".sh") || rel === "scripts/git-hooks/pre-push";
  if (customizable(rel)) {
    renderedHashes[rel] = sha(text);
    const cur = read(rel);
    if (cur !== null && cur !== text && sha(cur) !== prevRendered[rel]) {
      write(`${rel}.cc-new`, text, 0o644); kept.push(rel); continue;
    }
  }
  write(rel, text, exec ? 0o755 : 0o644);
}
if (LINT_FILE_CMD && LINT_EXT.length) {
  write(".claude/hooks/lint-after-edit.sh", fill(fs.readFileSync(path.join(SRC, ".claude/hooks/lint-after-edit.sh"), "utf8"), "lint-after-edit.sh"), 0o755);
} else if (read(".claude/hooks/lint-after-edit.sh") !== null && !dry) {
  fs.rmSync(path.join(target, ".claude/hooks/lint-after-edit.sh"));   // linting switched off: drop the stale hook
  console.log("removed .claude/hooks/lint-after-edit.sh (no LINT_FILE_CMD)");
}

// ---------- .mcp.json (merge) ----------
{
  let cur; try { cur = JSON.parse(read(".mcp.json") ?? "{}"); } catch { die(".mcp.json is not valid JSON — fix it first"); }
  cur.mcpServers = { ...(cur.mcpServers ?? {}), "cowork-bridge": { command: "node", args: [".claude/bridge/server.mjs"] } };
  write(".mcp.json", JSON.stringify(cur, null, 2) + "\n");
}

// ---------- .claude/settings.json (generate + merge) ----------
{
  const stackAllow = {
    "python-uv": ["Bash(uv run pytest:*)", "Bash(uv run python:*)", "Bash(uv run python3:*)", "Bash(uv run ruff:*)", "Bash(uv sync)", "Bash(uv sync --frozen)", "Bash(uv add:*)", "Bash(ruff:*)", "Bash(pytest:*)"],
    node: ["Bash(npm ci:*)", "Bash(npm install:*)", "Bash(npm test:*)", "Bash(npm run:*)", "Bash(npx --no-install:*)", "Bash(npx vitest:*)", "Bash(npx jest:*)", "Bash(npx tsc:*)", "Bash(npx eslint:*)", "Bash(npx prettier --check:*)", "Bash(pnpm install:*)", "Bash(pnpm add:*)", "Bash(pnpm test:*)", "Bash(pnpm run:*)", "Bash(pnpm exec:*)", "Bash(yarn install:*)", "Bash(yarn add:*)", "Bash(yarn test:*)", "Bash(yarn run:*)"],
    generic: [],
  }[STACK];
  if (!stackAllow) die(`STACK=${STACK} — use python-uv, node or generic`);
  const fromCmds = [INSTALL_CMD, TEST_CMD, LINT_CMD, INTEGRATION_CMD].filter((c) => !none(c)).map((c) => `Bash(${c}:*)`);
  const supa = MIGRATIONS.startsWith("supabase") ? ["Bash(supabase migration:*)", "Bash(supabase db diff:*)"] : [];
  if (TEST_CMD === "none") console.warn("WARNING: TEST_CMD=none — workers have no test gate and will stall on permission prompts for whatever test command they try. Set TEST_CMD in orchestration.conf.");
  const allow = [
    "Read", "Edit", "Write", "Glob", "Grep", "Agent", "WebSearch", "WebFetch", "SendMessage", "ListAgents", "Skill",
    "mcp__cowork-bridge__bridge_reply",
    ...stackAllow, ...fromCmds, ...supa, ...EXTRA_ALLOW.map((c) => `Bash(${c}:*)`),
    "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git branch:*)", "Bash(git add:*)",
    "Bash(git commit:*)", "Bash(git fetch:*)", "Bash(git pull:*)", "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git checkout:*)",
    "Bash(git switch:*)", "Bash(git stash:*)", "Bash(git rev-parse:*)", "Bash(git ls-files:*)",
    "Bash(gh pr:*)", "Bash(gh run:*)", "Bash(gh repo set-default:*)", "Bash(gh repo view:*)",
    "Bash(gh api repos/*/pulls*)", "Bash(gh api repos/*/actions*)", "Bash(gh api repos/*/commits*)", "Bash(gh api repos/*/branches*)",
    "Bash(gh api repos/*/check-runs*)", "Bash(gh api repos/*/issues*)", "Bash(gh api user*)",
    "Bash(docker:*)", "Bash(lsof:*)", "Bash(node:*)",
    "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(grep:*)", "Bash(rg:*)", "Bash(mkdir:*)",
    "Bash(sleep:*)", "Bash(echo:*)", "Bash(date:*)", "Bash(which:*)",
    ...["feat", "chore", "fix"].flatMap((p) => [`Bash(git push -u origin ${p}/*)`, `Bash(git push origin ${p}/*)`]),
    "Bash(git push -u origin wp*)", "Bash(git push origin wp*)",
  ];
  const perBranch = PROTECTED.flatMap((b) => [
    `Bash(git push origin ${b}:*)`, `Bash(git push * ${b})`, `Bash(git push origin HEAD:${b}:*)`, `Bash(git push * HEAD:${b}:*)`,
    `Bash(git push origin HEAD:refs/heads/${b}:*)`, `Bash(git push * HEAD:refs/heads/${b}:*)`, `Bash(git push origin refs/heads/${b}:*)`,
  ]);
  const perRelease = RELEASE ? ["create", "edit"].flatMap((v) => [
    `Bash(gh pr ${v} * --base ${RELEASE}*)`, `Bash(gh pr ${v} * -B ${RELEASE}*)`, `Bash(gh pr ${v} * --base=${RELEASE}*)`,
    `Bash(gh pr ${v} -B ${RELEASE}*)`, `Bash(gh pr ${v} --base ${RELEASE}*)`, `Bash(gh pr ${v} --base=${RELEASE}*)`,
  ]) : [];
  const deny = [
    ...perBranch,
    "Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(git push --mirror:*)", "Bash(git push --all:*)",
    "Bash(git push --no-verify:*)", "Bash(git push -n:*)",
    "Bash(git reset --hard:*)", "Bash(git clean:*)", "Bash(git branch -D:*)", "Bash(rm -rf:*)", "Bash(dd:*)",
    "Bash(git config core.hooksPath:*)", "Bash(git config --global core.hooksPath:*)", "Bash(git config --local core.hooksPath:*)",
    "Bash(git * --output*)",
    "Bash(supabase db push:*)", "Bash(supabase db reset:*)",
    "Bash(uv lock --upgrade:*)", "Bash(uv sync --upgrade:*)", "Bash(uv add --upgrade:*)", "Bash(uv remove:*)",
    "Bash(npm update:*)", "Bash(npm upgrade:*)", "Bash(npm uninstall:*)", "Bash(pnpm update:*)", "Bash(pnpm remove:*)", "Bash(yarn upgrade:*)", "Bash(yarn remove:*)",
    "Bash(gh api --method:*)", "Bash(gh api -X:*)", "Bash(gh api * -X *)", "Bash(gh api * --method *)", "Bash(gh api * -f *)", "Bash(gh api * -F *)", "Bash(gh api * --input *)", "Bash(gh api * -X*)", "Bash(gh api * --method*)", "Bash(gh api * -f*)", "Bash(gh api * -F*)",
    "Bash(gh api * --field*)", "Bash(gh api * --raw-field*)", "Bash(gh api * --input*)",
    "Bash(gh pr merge --admin:*)", "Bash(gh pr merge * --admin*)", "Bash(gh repo delete:*)",
    ...perRelease,
    "Edit(.env)", "Edit(.env.*)", "Write(.env)", "Write(.env.*)",
    "Edit(.github/workflows/*)", "Write(.github/workflows/*)",
    ...(MIGRATIONS ? [`Edit(${MIGRATIONS}/*)`, `Write(${MIGRATIONS}/*)`] : []),
    "Edit(.claude/bridge/node_modules/**)", "Write(.claude/bridge/node_modules/**)",
    "Edit(.claude/settings.json)", "Write(.claude/settings.json)", "Edit(.claude/settings.local.json)", "Write(.claude/settings.local.json)",
    "Edit(.claude/hooks/*)", "Write(.claude/hooks/*)", "Edit(.claude/orchestration.conf)", "Write(.claude/orchestration.conf)",
    "Edit(scripts/git-hooks/**)", "Write(scripts/git-hooks/**)",
    "Edit(.git/**)", "Write(.git/**)", "Edit(//**/.git/config)", "Write(//**/.git/config)",
    "Edit(//**/protected-hooks/**)", "Write(//**/protected-hooks/**)",
    "Edit(.claude/bridge/spawn/**)", "Write(.claude/bridge/spawn/**)", "Edit(//**/.claude/bridge/spawn/**)", "Write(//**/.claude/bridge/spawn/**)",
    "Edit(.claude/bridge/spawn-log/**)", "Write(.claude/bridge/spawn-log/**)",
  ];
  const hooks = {
    PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: 'bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/bash-guard.sh' }] }],
    ...(LINT_FILE_CMD && LINT_EXT.length ? { PostToolUse: [{ matcher: "Edit|Write|MultiEdit", hooks: [{ type: "command", command: 'bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/lint-after-edit.sh' }] }] } : {}),
    Stop: [{ hooks: [{ type: "command", command: 'bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/bridge-reply-guard.sh' }] }],
  };
  const MARK = "cc-orchestration";
  const curText = read(".claude/settings.json");
  let cur = {};
  if (curText) { try { cur = JSON.parse(curText); } catch { die(".claude/settings.json is not valid JSON — fix it first"); } }
  const ours = (cur.$comment ?? "").includes(MARK);
  if (curText && !ours) backup(".claude/settings.json");
  const uniq = (a) => [...new Set(a)];
  // Our own previous render is replaced; a foreign file keeps its entries (allow/deny unioned, its hooks kept).
  // The lists we rendered last time live in .claude/orchestration.rendered.json (settings.json must not carry
  // unknown keys); entries we no longer render are dropped, anything a human added is kept.
  let prev = { allow: [], deny: [] };
  try { prev = JSON.parse(read(".claude/orchestration.rendered.json") ?? "") ; } catch {}
  const keepAllow = (cur.permissions?.allow ?? []).filter((x) => !(ours && prev.allow?.includes(x)));
  const keepDeny = (cur.permissions?.deny ?? []).filter((x) => !(ours && prev.deny?.includes(x)));
  const isOurHook = (g) => JSON.stringify(g).match(/bash-guard\.sh|lint-after-edit\.sh|bridge-reply-guard\.sh/);
  const mergedHooks = {};
  for (const ev of new Set([...Object.keys(cur.hooks ?? {}), ...Object.keys(hooks)])) {
    mergedHooks[ev] = [...(cur.hooks?.[ev] ?? []).filter((g) => !isOurHook(g)), ...(hooks[ev] ?? [])];
    if (!mergedHooks[ev].length) delete mergedHooks[ev];
  }
  const out = {
    ...cur,
    $comment: `Rendered by ${MARK} (edit .claude/orchestration.conf and re-run install.sh). Project settings for orchestrated worker sessions. deny beats allow. Protected branches, secrets, migrations, CI and dependency upgrades are never auto-approved.`,
    permissions: { ...(cur.permissions ?? {}), allow: uniq([...allow, ...keepAllow]), deny: uniq([...deny, ...keepDeny]) },
    hooks: mergedHooks,
    enabledMcpjsonServers: uniq([...(cur.enabledMcpjsonServers ?? []), "cowork-bridge"]),
  };
  write(".claude/settings.json", JSON.stringify(out, null, 2) + "\n");
  write(".claude/orchestration.rendered.json", JSON.stringify({ note: "written by cc-orchestration render — do not edit", allow, deny, files: renderedHashes }, null, 2) + "\n");
}

// ---------- CLAUDE.md (marked section) ----------
{
  const section = fill(fs.readFileSync(path.join(SRC, "CLAUDE.orchestration.md"), "utf8"), "CLAUDE.orchestration.md").trimEnd();
  const cur = read("CLAUDE.md");
  const re = /<!-- cc-orchestration:begin[\s\S]*?<!-- cc-orchestration:end -->/;
  let next;
  if (cur === null) next = `# ${repoName}\n\n<!-- Project rules, architecture and conventions go here. Workers obey this file literally. -->\n\n${section}\n`;
  else if (re.test(cur)) next = cur.replace(re, section);
  else next = `${cur.trimEnd()}\n\n${section}\n`;
  write("CLAUDE.md", next);
}

// ---------- .gitignore (marked block) ----------
{
  const block = ["# cc-orchestration:begin — bridge runtime (per machine, never committed)", ".claude/bridge/inbox/", ".claude/bridge/outbox/",
    ".claude/bridge/processed/", ".claude/bridge/node_modules/", ".claude/bridge/package-lock.json", ".claude/bridge/stderr.log",
    ".claude/bridge/spawn/", ".claude/bridge/spawn-log/", ".claude/settings.local.json", ".claude/settings.json.bak-cc", "# cc-orchestration:end"].join("\n");
  const cur = read(".gitignore") ?? "";
  const re = /# cc-orchestration:begin[\s\S]*?# cc-orchestration:end/;
  write(".gitignore", re.test(cur) ? cur.replace(re, block) : `${cur.trimEnd()}${cur ? "\n\n" : ""}${block}\n`);
}

// ---------- leftovers ----------
if (!dry) {
  for (const rel of written) {
    const t = fs.readFileSync(path.join(target, rel), "utf8");
    const left = [...t.matchAll(/@@([A-Z_]+)@@/g)].map((m) => m[1]).filter((k) => !KNOWN_LITERALS.has(k));
    if (left.length) die(`${rel}: unrendered ${left.join(", ")}`);
  }
}
console.log(`${dry ? "[dry-run] would write" : "wrote"} ${written.length} files into ${target}`);
for (const r of written) console.log(`  ${r}`);
if (kept.length) {
  console.log("\nKept your customised versions (the kit's new version is next to each as .cc-new — merge by hand, then delete it):");
  for (const r of kept) console.log(`  ${r}`);
}
