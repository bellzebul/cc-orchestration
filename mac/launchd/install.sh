#!/bin/bash
# Login agents (launchd) for the agent tracker server and for one worker spawner per repo.
#   mac/launchd/install.sh [--spawner <repo-dir>]... [--no-tracker]
#   mac/launchd/install.sh --uninstall
# Each agent starts at login and is restarted by launchd if it exits. Logs: ~/Library/Logs/cc-*.log
# Re-running replaces the agents it manages (repos not named again keep their spawner).
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
dst="$HOME/Library/LaunchAgents"; uid=$(id -u); user=$(id -un | tr -c 'A-Za-z0-9\n' '-')
mkdir -p "$dst" "$HOME/Library/Logs"
tracker=1; spawners=(); uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --spawner) spawners+=("$(cd "$2" && pwd)"); shift 2 ;;
    --no-tracker) tracker=0; shift ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
# launchd jobs get a minimal PATH: add the usual places for claude, node, tmux, gh, uv.
path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for t in node claude tmux gh uv npm; do p=$(command -v $t 2>/dev/null || true); [ -n "$p" ] && case ":$path:" in *":$(dirname "$p"):"*) ;; *) path="$(dirname "$p"):$path" ;; esac; done

unload() { launchctl bootout "gui/$uid/$1" 2>/dev/null || true
  for _ in $(seq 1 50); do launchctl print "gui/$uid/$1" >/dev/null 2>&1 || break; sleep 0.2; done; }   # bootout is async
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
agent() {  # agent <label> <workdir> <command> <log>
  local label=$1 dir=$2 cmd=$3 log=$4 f="$dst/$1.plist"
  unload "$label"
  cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-c</string><string>cd "$(xml "$dir")" &amp;&amp; exec $(xml "$cmd")</string></array>
  <key>WorkingDirectory</key><string>$(xml "$dir")</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$path")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(xml "$log")</string>
  <key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$uid" "$f"
  echo "loaded $label"
}

if [ $uninstall = 1 ]; then
  for f in "$dst"/com."$user".cc-*.plist; do [ -f "$f" ] || continue; l=$(basename "$f" .plist); unload "$l"; rm -f "$f"; echo "removed $l"; done
  exit 0
fi
[ $tracker = 1 ] && agent "com.$user.cc-tracker" "$kit/tracker" "node server.mjs" "$HOME/Library/Logs/cc-tracker.log"
for repo in ${spawners[@]+"${spawners[@]}"}; do
  [ -x "$repo/scripts/worker-spawner.sh" ] || { echo "$repo has no scripts/worker-spawner.sh — run install.sh on it first" >&2; exit 1; }
  # basename + short hash of the full path: two repos with the same folder name get separate agents
  name="$(basename "$repo" | tr -c 'A-Za-z0-9\n' '-')-$(printf '%s' "$repo" | shasum | cut -c1-6)"
  agent "com.$user.cc-spawner.$name" "$repo" "bash scripts/worker-spawner.sh" "$HOME/Library/Logs/cc-spawner-$name.log"
done
sleep 2
launchctl list | grep "com.$user.cc-" || true
cat <<'TXT'

If a spawner log says "Operation not permitted": macOS blocks launchd jobs from ~/Documents, ~/Desktop
and ~/Downloads. System Settings → Privacy & Security → Full Disk Access → + → Cmd+Shift+G → /bin/bash
→ enable, then re-run this script (or keep repos outside those folders).
TXT
