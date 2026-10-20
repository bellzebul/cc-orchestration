#!/bin/bash
# One-time machine setup for the Cowork → Claude Code worker setup (macOS).
#   mac/setup.sh [--language Ukrainian] [--no-global] [--no-tracker]
# 1. checks the tools (git, node >= 18, npm, tmux, gh + auth, claude CLI);
# 2. global Claude Code config (backup first): ~/.claude/CLAUDE.md gets the cc-orchestration section,
#    ~/.claude/settings.json loses `ask` rules for git push (they stall unattended workers), gains a
#    few hard denies and crossSessionInbound=accept, and defaultMode=auto unless one is already set;
# 3. installs the agent-tracker hooks (user-level) — the tracker server itself runs from launchd.
# Then: mac/launchd/install.sh --spawner <repo>  (tracker + one spawner per repo, start at login).
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
lang="" global=1 tracker=1
while [ $# -gt 0 ]; do
  case "$1" in
    --language) lang=$2; shift 2 ;;
    --no-global) global=0; shift ;;
    --no-tracker) tracker=0; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

missing=()
for t in git node npm tmux gh claude; do command -v $t >/dev/null || missing+=("$t"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing: ${missing[*]}"
  echo "  brew install ${missing[*]/claude/}   # claude CLI: https://docs.claude.com/en/docs/claude-code (native installer → ~/.local/bin/claude)"
  exit 1
fi
node -e 'process.exit(Number(process.versions.node.split(".")[0])>=18?0:1)' || { echo "node >= 18 required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }
echo "tools: ok ($(claude --version 2>/dev/null | head -1))"

if [ $global = 1 ]; then
  cc="$HOME/.claude"; mkdir -p "$cc/backups"; stamp=$(date +%Y%m%d-%H%M%S)
  [ -f "$cc/CLAUDE.md" ] && cp "$cc/CLAUDE.md" "$cc/backups/CLAUDE.md.$stamp"
  [ -f "$cc/settings.json" ] && cp "$cc/settings.json" "$cc/backups/settings.json.$stamp"
  node - "$kit/mac/global/CLAUDE.md" "$cc/CLAUDE.md" "$lang" <<'JS'
const fs = require("fs");
const [src, dst, lang] = process.argv.slice(2);
let section = fs.readFileSync(src, "utf8").trimEnd();
if (lang) section = section.replace("- Explanations to me in English;", `- Explanations to me in ${lang};`);
const re = /<!-- cc-orchestration:global:begin[\s\S]*?<!-- cc-orchestration:global:end -->/;
let cur = ""; try { cur = fs.readFileSync(dst, "utf8"); } catch {}
fs.writeFileSync(dst, re.test(cur) ? cur.replace(re, section) : (cur.trim() ? cur.trimEnd() + "\n\n" : "") + section + "\n");
console.log("~/.claude/CLAUDE.md: cc-orchestration section written");
JS
  node - "$cc/settings.json" <<'JS'
const fs = require("fs");
const p = process.argv[2];
let s = {}; try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
s.permissions ??= {};
if (Array.isArray(s.permissions.ask)) {
  s.permissions.ask = s.permissions.ask.filter((r) => !/git push/.test(r));
  if (!s.permissions.ask.length) delete s.permissions.ask;
}
s.permissions.deny = [...new Set([...(s.permissions.deny ?? []), "Bash(rm -rf:*)", "Bash(git push --force:*)", "Bash(supabase db push:*)"])];
s.permissions.defaultMode ??= "auto";
s.crossSessionInbound = "accept";
fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
console.log(`~/.claude/settings.json: git-push ask rules removed, denies added, defaultMode=${s.permissions.defaultMode}, crossSessionInbound=accept`);
JS
fi

if [ $tracker = 1 ]; then
  node "$kit/mac/tracker/install.mjs"
fi
cat <<TXT

Next:
  $kit/mac/launchd/install.sh --spawner <repo-dir> [--spawner <another-repo>]
Then on the phone: install the ntfy app, subscribe to the topic printed in ~/Library/Logs/cc-tracker.log,
and open the board URL from the same log ("Add to Home Screen").
Restart Claude Code sessions that were already running so they load the new hooks and settings.
TXT
