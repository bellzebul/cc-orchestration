#!/usr/bin/env bash
# Install the versioned pre-push hook OUTSIDE every working tree and point core.hooksPath at it.
#   scripts/install-git-hooks.sh [checkout-dir]      (default: the current directory)
# Why outside: a relative core.hooksPath lives in the working tree, where a checkout, restore, chmod -x
# or truncate of a tracked file would disarm it. $(git rev-parse --git-common-dir)/protected-hooks/ is
# shared by the main checkout and all its worktrees, is not a tracked path, and is denied to agents
# (Edit/Write .git/**, bash guard). Re-run after changing scripts/git-hooks/pre-push.
set -euo pipefail
dir=${1:-.}
common=$(git -C "$dir" rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$(cd "$dir" && cd "$common" && pwd)" ;; esac
src="$(git -C "$dir" rev-parse --show-toplevel)/scripts/git-hooks/pre-push"
[ -f "$src" ] || { echo "install-git-hooks: $src not found (pull @@BASE@@ first)" >&2; exit 1; }
dst="$common/protected-hooks/pre-push"
mkdir -p "$common/protected-hooks"   # a no-op on an existing (even root-sealed) dir; a real failure fails
if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
  echo "pre-push hook already installed and up to date at $dst"
elif [ -f "$dst" ] && [ ! -w "$dst" ]; then
  # root-owned seal (sudo chown -R root …/protected-hooks): a deliberate human choice — never fail on it
  echo "pre-push hook at $dst is write-protected (root-owned seal) and DIFFERS from scripts/git-hooks/pre-push." >&2
  echo "To update it: sudo cp $src $dst && sudo chmod 755 $dst" >&2
else
  cp "$src" "$dst"
  chmod 755 "$dst"
  echo "pre-push hook installed at $dst"
fi
cur=$(git -C "$dir" config --get core.hooksPath || true)
prot="$common/protected-hooks"
# Keep the repo's existing hooks working (husky, pre-commit, a custom hooksPath or .git/hooks): their dir is
# recorded once and every client hook in protected-hooks chains to it (pre-push after its own check).
prev=""
if [ -n "$cur" ] && [ "$cur" != "$prot" ]; then
  prev=$cur
elif [ -z "$cur" ] && [ -n "$(find "$common/hooks" -maxdepth 1 -type f -perm -u+x ! -name '*.sample' 2>/dev/null | head -1)" ]; then
  prev="$common/hooks"
fi
if [ -n "$prev" ] && [ -w "$prot" ]; then
  printf '%s\n' "$prev" > "$prot/previous-hooks-path"
  for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
           post-commit pre-rebase post-checkout post-merge post-rewrite pre-auto-gc push-to-checkout; do
    printf '#!/bin/sh\n# chained by cc-orchestration install-git-hooks.sh\nprev=$(head -1 "$(dirname "$0")/previous-hooks-path" 2>/dev/null)\n[ -n "$prev" ] && [ -x "$prev/%s" ] && exec "$prev/%s" "$@"\nexit 0\n' "$h" "$h" > "$prot/$h"
    chmod 755 "$prot/$h"
  done
  echo "existing hooks in '$prev' stay active: chained from $prot (re-run this script if that folder moves)"
fi
if [ "$cur" != "$prot" ]; then
  git -C "$dir" config core.hooksPath "$prot"
  echo "core.hooksPath set to $prot (shared by all worktrees of this clone)"
fi
