#!/usr/bin/env bash
# Smoke test for this repo's orchestration guards (rendered by cc-orchestration for THIS repo's branches).
#   bash scripts/guard-selftest.sh
# Feeds probe commands to .claude/hooks/bash-guard.sh as PreToolUse payloads (nothing is executed) and
# pushes probe refs through the installed pre-push hook. Exit 0 = every probe got the expected verdict.
# The full regression battery (~670 probes) lives in the cc-orchestration kit: tests/run-battery.sh.
set -uo pipefail
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
guard="$repo/.claude/hooks/bash-guard.sh"
protected=(@@PROTECTED_WORDS@@)
release="@@RELEASE_CASE@@"
fail=0; n=0
probe() {  # probe <block|pass> <branch-the-agent-is-on> <command>
  local want=$1 br=$2 cmd=$3 rc
  n=$((n+1))
  printf '%s' "$cmd" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:s}})))' \
    | GUARD_TEST_MODE=1 GUARD_CURRENT_BRANCH="$br" GH_TOKEN= GITHUB_TOKEN= bash "$guard" >/dev/null 2>&1; rc=$?
  if { [ "$want" = block ] && [ $rc -ne 2 ]; } || { [ "$want" = pass ] && [ $rc -ne 0 ]; }; then
    echo "FAIL ($want, on $br, rc=$rc): $cmd"; fail=1
  fi
}
for b in "${protected[@]}"; do
  probe block feat/x "git push origin $b"
  probe block feat/x "git push origin HEAD:$b"
  probe block feat/x "git push origin HEAD:refs/heads/$b"
  probe block feat/x "git push -u origin feat/x:$b"
  probe block "$b"   "git push"
  probe block "$b"   "git push origin HEAD"
  probe block feat/x "GIT_PUSH_TO_PROTECTED=1 git push origin $b"
done
probe pass  feat/x "git push -u origin feat/x"
probe pass  feat/x "git push origin HEAD"
probe pass  feat/x "git status && git log --oneline -5"
probe block feat/x "git push --force origin feat/x"
probe block feat/x "git push --no-verify origin feat/x"
probe block feat/x "git config core.hooksPath /tmp/x"
probe block feat/x "echo KEY=1 >> .env"
probe block feat/x "sed -i s/a/b/ .claude/settings.json"
probe block feat/x "cp /tmp/x .claude/hooks/bash-guard.sh"
probe block feat/x "rm -rf build"
probe block feat/x "git reset --hard origin/@@BASE@@"
probe block feat/x "gh api -X DELETE repos/o/r/git/refs/heads/x"
probe block feat/x "uv lock --upgrade"
probe block feat/x "npm update"
probe pass  feat/x "gh pr create --base @@BASE@@ --title t --body-file /tmp/b"
if [ "$release" != "__cc_no_release_branch__" ]; then
  probe block feat/x "gh pr create --base $release --title t --body-file /tmp/b"
fi

# pre-push hook: the installed (sealed) copy refuses protected refs on the resolved remote ref
hooks=$(git -C "$repo" config --get core.hooksPath || true)
if [ -z "$hooks" ] || [ ! -x "$hooks/pre-push" ]; then
  echo "FAIL: pre-push hook not installed (core.hooksPath=$hooks) — run scripts/install-git-hooks.sh"; fail=1
else
  for b in "${protected[@]}"; do
    n=$((n+1))
    if printf 'refs/heads/x 1111 refs/heads/%s 0000\n' "$b" | env -u GIT_PUSH_TO_PROTECTED "$hooks/pre-push" origin url >/dev/null 2>&1; then
      echo "FAIL: pre-push let refs/heads/$b through"; fail=1
    fi
  done
  n=$((n+1))
  printf 'refs/heads/x 1111 refs/heads/feat/x 0000\n' | env -u GIT_PUSH_TO_PROTECTED "$hooks/pre-push" origin url >/dev/null 2>&1 \
    || { echo "FAIL: pre-push refused a feature branch"; fail=1; }
fi
[ $fail = 0 ] && echo "guard self-test: all $n probes OK (protected: ${protected[*]})" || { echo "guard self-test: FAILED"; exit 1; }
