#!/usr/bin/env bash
# Install (or update) the Cowork → Claude Code worker setup into a git repository.
#
#   ./install.sh <repo-dir> [--stack python-uv|node|generic] [--base dev] [--release main|none]
#                [--gh owner/repo] [--owner "Name"] [--yes]
#
# First run: detects sensible values, writes <repo>/.claude/orchestration.conf and shows it; edit it if
# anything is off and run again. Every run renders the kit from ./repo into <repo> (idempotent), installs
# the sealed pre-push hook and the bridge's npm deps. Nothing is committed or pushed — review the diff,
# commit it on a branch and merge it through a PR like any other change.
set -euo pipefail
kit=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ $# -ge 1 ] || { sed -n '2,10p' "$0"; exit 1; }
target=$(cd "$1" && pwd -P); shift
stack="" base="" release="" gh="" owner="" yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) stack=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --release) release=$2; shift 2 ;;
    --gh) gh=$2; shift 2 ;;
    --owner) owner=$2; shift 2 ;;
    --yes|-y) yes=1; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

for t in git node npm; do command -v $t >/dev/null || { echo "missing: $t" >&2; exit 1; }; done
node -e 'process.exit(Number(process.versions.node.split(".")[0])>=18?0:1)' || { echo "node >= 18 required" >&2; exit 1; }
top=$(cd "$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P) || { echo "$target is not a git repository" >&2; exit 1; }
[ "$top" = "$target" ] || { echo "pass the repository root ($top), not a subfolder" >&2; exit 1; }
[ "$(git -C "$target" rev-parse --git-common-dir)" = ".git" ] || { echo "run it on the main checkout, not on a worktree" >&2; exit 1; }

conf="$target/.claude/orchestration.conf"
if [ -f "$conf" ] && [ -n "$stack$base$release$gh$owner" ]; then
  echo "NOTE: $conf already exists — the --stack/--base/--release/--gh/--owner flags are ignored; edit the file instead." >&2
fi
if [ ! -f "$conf" ]; then
  # ---- detect ----
  if [ -z "$stack" ]; then
    if [ -f "$target/pyproject.toml" ] && [ -f "$target/uv.lock" ]; then stack=python-uv
    elif [ -f "$target/package.json" ]; then stack=node
    else stack=generic; fi
  fi
  git -C "$target" fetch -q origin 2>/dev/null || true
  if [ -z "$base" ]; then
    if git -C "$target" show-ref --verify --quiet refs/remotes/origin/dev; then base=dev
    else base=$(git -C "$target" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
         base=${base:-$(git -C "$target" symbolic-ref --short HEAD 2>/dev/null || echo main)}; fi
  fi
  if [ -z "$release" ]; then
    if [ "$base" != main ] && git -C "$target" show-ref --verify --quiet refs/remotes/origin/main; then release=main
    elif [ "$base" != master ] && git -C "$target" show-ref --verify --quiet refs/remotes/origin/master; then release=master
    else release=none; fi
  fi
  if [ -z "$gh" ]; then
    url=$(git -C "$target" remote get-url origin 2>/dev/null || true)
    gh=$(printf '%s' "$url" | sed -nE 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
    gh=${gh:-none}
  fi
  owner=${owner:-$( (git -C "$target" config user.name 2>/dev/null || true) | awk '{print $1}')}; owner=${owner:-the owner}
  case "$stack" in
    python-uv) inst="uv sync --frozen"; test="uv run pytest -q"; lint="uv run ruff check"
               lintf='uv run --project "${CLAUDE_PROJECT_DIR:-.}" ruff check --no-fix "$file"'; ext="py" ;;
    node)      pm=npm; inst="npm install"
               if [ -f "$target/pnpm-lock.yaml" ]; then pm=pnpm; inst="pnpm install --frozen-lockfile"
               elif [ -f "$target/yarn.lock" ]; then pm=yarn; inst="yarn install --frozen-lockfile"
               elif [ -f "$target/package-lock.json" ] || [ -f "$target/npm-shrinkwrap.json" ]; then inst="npm ci"; fi
               test="$pm test"; lint=none; lintf=none; ext=""
               if grep -q '"eslint"' "$target/package.json" 2>/dev/null; then   # only when the repo really uses eslint
                 lint="npx --no-install eslint ."; lintf='npx --no-install eslint "$file"'; ext="js jsx ts tsx mjs cjs"
               fi ;;
    generic)   inst=none; test=none; lint=none; lintf=none; ext=""
               if [ -f "$target/go.mod" ]; then inst="go mod download"; test="go test ./..."; lint="go vet ./..."
               elif [ -f "$target/Cargo.toml" ]; then inst="cargo fetch"; test="cargo test"; lint="cargo clippy"
               elif [ -f "$target/Gemfile" ]; then inst="bundle install"; test="bundle exec rake test"
               elif [ -f "$target/pom.xml" ]; then test="mvn -q test"
               elif [ -f "$target/build.gradle" ] || [ -f "$target/build.gradle.kts" ]; then test="./gradlew test"
               elif [ -f "$target/Makefile" ] && grep -q '^test:' "$target/Makefile"; then test="make test"; fi ;;
    *) echo "--stack must be python-uv, node or generic" >&2; exit 1 ;;
  esac
  mig=none; for d in supabase/migrations migrations db/migrate prisma/migrations alembic/versions; do [ -d "$target/$d" ] && { mig=$d; break; }; done
  mkdir -p "$target/.claude"
  cat > "$conf" <<EOF
# cc-orchestration config — the single place to change. Re-run install.sh after editing.
# Branches
BASE=$base                 # where work-package PRs merge (workers merge here themselves when CI is green)
RELEASE=$release              # only a human merges into it; "none" if the repo has no release branch
PROTECTED=                 # extra branches nobody may push to directly (BASE and RELEASE always are)
GH_REPO=$gh
WT_DIR=                    # worktree folder next to the checkout; empty = <repo-name>-wt
# Stack and commands (shown to workers in CLAUDE.md and the agents; keep them one line)
STACK=$stack
INSTALL_CMD=$inst
TEST_CMD=$test
LINT_CMD=$lint
LINT_FILE_CMD=$lintf
LINT_EXT=$ext
INTEGRATION_CMD=none
EXTRA_ALLOW=               # comma-separated extra command prefixes workers may run without asking
# Policy
OWNER=$owner                # the human the workers escalate to
CONTRACTS=shared-interface # what counts as a cross-module contract change (e.g. src/shared) — needs the human
MIGRATIONS=$mig
WORKER_USD=10              # paid API spend a worker decides alone (per task, within budget_usd)
HUMAN_USD=50               # at or above this the human decides; in between the orchestrator does
ENV_FILES=.env .env.test   # copied from the main checkout into every worker worktree
RETIRE_AFTER_H=24          # a finished (done + merged + clean) worker is retired after this many idle hours; 0 = only on request
EOF
  echo "Wrote $conf:"; echo; sed 's/^/    /' "$conf"; echo
  [ "$test" != none ] || echo "!! TEST_CMD is none: set the command CI gates on, or workers have no test gate." >&2
  if [ "$yes" != 1 ]; then
    echo "Check the values (edit the file if needed), then run the same command again to render."; exit 0
  fi
fi

node "$kit/lib/render.mjs" --target "$target"
bash "$target/scripts/install-git-hooks.sh" "$target"
(cd "$target/.claude/bridge" && npm install --prefix "$target/.claude/bridge" --workspaces=false --ignore-scripts --no-package-lock --no-audit --no-fund >/dev/null)
bash "$target/scripts/guard-selftest.sh" || { echo "guard self-test failed — do not use workers until it passes" >&2; exit 1; }
command -v tmux >/dev/null || echo "NOTE: tmux is not installed — brew install tmux (the spawner needs it)"
command -v gh >/dev/null || echo "NOTE: GitHub CLI is not installed — brew install gh && gh auth login"
cat <<EOF

Done. From now on nobody pushes to the protected branches directly from this clone — not even you
(the pre-push hook refuses). Deliberate human override: GIT_PUSH_TO_PROTECTED=1 git push …

Next:
  1. Review:  git -C "$target" status && git -C "$target" diff
     Commit on a branch (e.g. chore/cc-orchestration), open a PR into the base branch, merge it.
     Workers refuse to start until these files are on origin/<base> (branch-trust check).
  2. CI (recommended, by hand — workers may not edit workflows): add to each workflow
       concurrency: { group: ci-\${{ github.workflow }}-\${{ github.event.pull_request.number || github.ref }}, cancel-in-progress: \${{ github.event_name == 'pull_request' }} }
  3. Machine (once per Mac): $kit/mac/setup.sh   then   $kit/mac/launchd/install.sh --spawner "$target"
  4. Cowork: add the two skills from $kit/skills/ to your Claude account, connect the folder that
     contains this repo, and say what to build.
EOF
