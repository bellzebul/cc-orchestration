#!/usr/bin/env bash
# PostToolUse on Edit|Write|MultiEdit: lint the touched file and REPORT. It never rewrites the file:
# auto-formatting here would turn one-line edits into whole-file diffs and make parallel worktrees
# conflict. Exit 2 only annotates (feeds the findings back to Claude). Rendered by cc-orchestration.
set -uo pipefail
input=$(cat)
file=$(printf '%s' "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.tool_input?.file_path??""))}catch{process.stdout.write("")}})')
case "$file" in
  @@LINT_EXT_CASE@@) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
if ! out=$(@@LINT_FILE_CMD@@ 2>&1); then
  echo "lint findings in $file (fix the ones your edit introduced; do not reformat the whole file):" >&2
  echo "$out" | tail -40 >&2
  exit 2
fi
exit 0
