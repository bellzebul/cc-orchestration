#!/usr/bin/env bash
# Full regression run for the kit: renders it (BASE=dev, RELEASE=main) into a scratch repo with a scratch
# origin and runs the reference pytest suites against the rendered files:
#   - test_bash_guard_battery.py  (~670 guard probes + the differential vs origin/dev)
#   - test_pre_push_hook.py       (the sealed pre-push hook)
#   - test_worker_scripts.py      (branch-trust, worker.sh, worker-up.sh, spawner)
#   - test_bridge_yaml_scalar.py  (bridge_reply needs/action validation and YAML quoting)
# Needs: python3 with pytest, pydantic-settings and pyyaml, git, node, npm, bash. Run it before publishing a kit change.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git init -q --bare -b dev "$tmp/origin.git"
git init -q -b dev "$tmp/app"; cd "$tmp/app"
git config user.email kit@test; git config user.name "Kit Test"; git config commit.gpgsign false
printf '[project]\nname = "app"\n' > pyproject.toml; : > uv.lock
git add -A; git commit -qm init; git remote add origin "$tmp/origin.git"; git push -q origin dev; git push -q origin dev:main
"$kit/install.sh" "$tmp/app" >/dev/null                           # writes the conf
sed -i.bak 's/^WT_DIR=.*/WT_DIR=app-wt/' .claude/orchestration.conf && rm -f .claude/orchestration.conf.bak   # the suites expect this name
"$kit/install.sh" "$tmp/app" >/dev/null
mkdir -p src/tests/unit; cp "$kit"/tests/reference/*.py src/tests/unit/
cp "$kit/tests/guard_battery.jsonl" scripts/; : > scripts/guard_relaxations.jsonl
git add -A; git commit -qm render; GIT_PUSH_TO_PROTECTED=1 git push -q origin dev 2>/dev/null
python3 -m pytest -q -p no:cacheprovider -o addopts= -m "" src/tests/unit "$@"
