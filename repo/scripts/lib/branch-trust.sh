# shellcheck shell=bash
# Branch-trust check for bridge workers (bash 3.2-compatible: macOS /bin/bash runs it). Source it, then:
#   check_branch_trust <worktree-dir> [base-ref] [repo]   base-ref: refs/remotes/origin/@@BASE@@ by default;
#                                                          repo: the checkout this lib lives in by default
#   valid_worker_branch <branch>                          0 = a branch a worker may sit on
#   worktree_branch <repo> <worktree-dir>                 the branch <repo>'s admin data has checked out there
#   reset_bridge_deps <worktree-dir>                      remove bridge node_modules + lockfiles (pre-check)
#
# Why: a worker starts with --dangerously-load-development-channels and auto-accepts the folder-trust
# dialog, so its project settings, MCP servers, hooks and the bridge server (plus whatever npm installs
# for it) apply without asking. A branch that changes any of them must reach @@BASE@@ through a reviewed PR.
#
# The worktree's OWN git data is never consulted: its .git file, config (core.fsmonitor, core.worktree,
# filter drivers, includeIf) and index are writable by whoever last ran in it, so a git command run
# there can lie or execute a planted program. Instead:
#   1. base-ref is a full ref (refs/…; a short "origin/@@BASE@@" could be shadowed by a local branch or tag),
#      resolved and read in the TRUSTED repo; a missing one is fetched once.
#   2. the worktree must be registered in the trusted repo, and its .git must be a plain file pointing
#      at exactly that admin dir (which points back) — no redirected gitdir survives into the session.
#   3. no symlinked parent (.claude, .claude/bridge, scripts).
#   4. every trust path is walked on disk with `find` (symlinks NOT followed — any symlink, fifo, device
#      or unreadable entry refuses), each regular file hashed by the trusted repo with
#      `hash-object --no-filters`, and the resulting {path, blob} set must EQUAL base-ref's set at those
#      paths, read with `ls-tree` in the trusted repo. An extra, missing or different file refuses —
#      which also makes "absent on @@BASE@@" mean "must be absent" (settings.local.json, .npmrc, lockfiles,
#      node_modules).
# Every git call runs with core.fsmonitor off and hooks pointed at /dev/null. Any error fails closed.
#
#   5. no regular file under a trust path has more than one hard link (an outside writer could change it
#      after the check through the other link).
#   A trust path with no entry on @@BASE@@ (node_modules, .npmrc, …) refuses as soon as anything but an empty
#   directory sits there, without walking all of it.
#
# Trust paths: see BRANCH_TRUST_PATHS. Besides Claude's own config they cover everything that decides
# what code the bridge server runs: npm's project root and config at the worktree root and in .claude/
# (a root package.json with "workspaces"/"overrides" or a root .npmrc would otherwise redirect the
# install), and every node_modules Node would resolve the bridge's imports from inside the worktree.
# .claude/bridge/node_modules and package-lock.json are generated per worktree by npm, so worker.sh calls
# reset_bridge_deps BEFORE the check and installs afresh after it. The root and .claude/ ones are never
# cleaned: their presence refuses.

BRANCH_TRUST_PATHS=(
  .claude/settings.json .claude/settings.local.json .mcp.json
  .claude/hooks scripts/git-hooks
  .claude/bridge/server.mjs .claude/bridge/package.json .claude/bridge/.npmrc
  .claude/bridge/package-lock.json .claude/bridge/npm-shrinkwrap.json .claude/bridge/node_modules
  @@TRUST_ROOT_NPM@@
  .claude/package.json .claude/.npmrc .claude/node_modules
)
# Parent directories a symlink could redirect a whole trust path through.
_BRANCH_TRUST_PARENTS=(.claude .claude/bridge scripts)

# git with the config keys that would make a read-only call run a program switched off (public:
# worker.sh uses it for every git call it makes).
bt_git() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }

_bt_refuse() {  # _bt_refuse <header> [newline-separated list]
  echo "branch-trust: $1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/  /' >&2
  return 1
}

_bt_default_repo() {  # the checkout this file lives in (scripts/lib/ → repo root)
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || return 1
  bt_git -C "$d" rev-parse --show-toplevel
}

_bt_common_dir() {  # absolute, symlink-free git common dir of <repo>
  local repo=$1 c
  c=$(bt_git -C "$repo" rev-parse --git-common-dir) || return 1
  case "$c" in /*) ;; *) c="$repo/$c" ;; esac
  (cd "$c" && pwd -P)
}

# ─────────────────────────────────────────────
# Branch names
# ─────────────────────────────────────────────
# A worker never sits on a protected branch (@@PROTECTED_SLASH@@), and a branch name must not be able to masquerade as a ref.
valid_worker_branch() {
  local b=${1:-}
  [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  case "$b" in
    *..*|*@\{*|HEAD|@@PROTECTED_CASE@@|origin/*|refs/*) return 1 ;;
  esac
  return 0
}

# Prints the short branch checked out in <worktree-dir> according to <repo>'s admin data ("(detached)"
# for a detached HEAD); exit 1 when <worktree-dir> is not a worktree of <repo>. Never reads the worktree.
worktree_branch() {
  local repo=$1 want out line path="" br=""
  want=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  out=$(bt_git -C "$repo" worktree list --porcelain) || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path=$(cd "${line#worktree }" 2>/dev/null && pwd -P) || path="${line#worktree }"; br="" ;;
      "branch refs/heads/"*) br=${line#branch refs/heads/} ;;
      detached) br="(detached)" ;;
      "") if [ -n "$path" ] && [ "$path" = "$want" ]; then printf '%s\n' "$br"; return 0; fi; path="" ;;
    esac
  done <<EOF
$out

EOF
  return 1
}

# ─────────────────────────────────────────────
# Bridge deps reset (runs BEFORE the check)
# ─────────────────────────────────────────────
# node_modules and package-lock.json are npm's per-worktree output, absent on @@BASE@@; a stale or planted
# copy is removed so the check sees only what the branch carries and npm installs into an empty dir.
reset_bridge_deps() {
  local wt=${1:-} p
  [ -n "$wt" ] && [ -d "$wt" ] || { _bt_refuse "worktree '$wt' not found"; return 1; }
  for p in .claude .claude/bridge; do   # never rm through a redirected parent
    if [ -L "$wt/$p" ] || { [ -e "$wt/$p" ] && [ ! -d "$wt/$p" ]; }; then
      _bt_refuse "$p is a symlink or not a directory — refusing to clean bridge deps"; return 1
    fi
  done
  [ -d "$wt/.claude/bridge" ] || return 0
  rm -rf -- "$wt/.claude/bridge/node_modules" && rm -f -- "$wt/.claude/bridge/package-lock.json"
}

# ─────────────────────────────────────────────
# The check
# ─────────────────────────────────────────────
_bt_check_gitlink() {  # <repo> <canonical-wt>: .git is a plain file → this repo's admin dir → back
  local repo=$1 wt=$2 common content admin back back_c
  common=$(_bt_common_dir "$repo") || { _bt_refuse "cannot resolve the git dir of $repo — refusing"; return 1; }
  if [ -L "$wt/.git" ] || [ ! -f "$wt/.git" ]; then
    _bt_refuse "$wt/.git is not a plain gitdir file (a worker always runs in a linked worktree) — refusing"; return 1
  fi
  content=$(cat -- "$wt/.git") || { _bt_refuse "cannot read $wt/.git — refusing"; return 1; }
  case "$content" in
    "gitdir: "*) admin=${content#gitdir: } ;;
    *) _bt_refuse "$wt/.git is not a 'gitdir:' link — refusing"; return 1 ;;
  esac
  case "$admin" in *$'\n'*) _bt_refuse "$wt/.git has more than one line — refusing"; return 1 ;; esac
  case "$admin" in /*) ;; *) admin="$wt/$admin" ;; esac
  admin=$(cd "$admin" 2>/dev/null && pwd -P) || { _bt_refuse "gitdir in $wt/.git does not exist — refusing"; return 1; }
  if [ "$(dirname "$admin")" != "$common/worktrees" ]; then
    _bt_refuse "$wt/.git points outside $common/worktrees ($admin) — refusing"; return 1
  fi
  back=$(cat -- "$admin/gitdir" 2>/dev/null) || { _bt_refuse "$admin/gitdir unreadable — refusing"; return 1; }
  back_c=$(cd "$(dirname "$back")" 2>/dev/null && pwd -P)/$(basename "$back")
  if [ "$back_c" != "$wt/.git" ]; then
    _bt_refuse "worktree admin dir $admin belongs to $back, not $wt — refusing"; return 1
  fi
  # The admin dir's commondir decides which repo (objects, refs, config) git uses there: it must be ours.
  local cd_raw cd_c
  cd_raw=$(cat -- "$admin/commondir" 2>/dev/null) || { _bt_refuse "$admin/commondir missing — refusing"; return 1; }
  case "$cd_raw" in /*) ;; *) cd_raw="$admin/$cd_raw" ;; esac
  cd_c=$(cd "$cd_raw" 2>/dev/null && pwd -P) || { _bt_refuse "$admin/commondir does not resolve — refusing"; return 1; }
  if [ "$cd_c" != "$common" ]; then
    _bt_refuse "$admin/commondir points at $cd_c, not $common — refusing"; return 1
  fi
  # A per-worktree config (extensions.worktreeConfig) can carry core.fsmonitor / core.worktree / filters
  # that every later git command in the worker would honour.
  if [ -e "$admin/config.worktree" ] || [ -L "$admin/config.worktree" ]; then
    _bt_refuse "$admin/config.worktree exists (per-worktree git config) — refusing"; return 1
  fi
}

check_branch_trust() {
  local wt=${1:-} base=${2:-refs/remotes/origin/@@BASE@@} repo=${3:-} p e rel sha line meta mode path
  local base_list="" disk_list="" bad="" out tmp rc
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then _bt_refuse "worktree '$wt' not found — refusing"; return 1; fi
  wt=$(cd "$wt" && pwd -P) || { _bt_refuse "cannot enter $wt — refusing"; return 1; }
  if [ -z "$repo" ]; then
    repo=$(_bt_default_repo) || { _bt_refuse "cannot resolve the trusted repo — refusing"; return 1; }
  fi

  # 1. Full ref, resolved in the trusted repo.
  case "$base" in origin/*) base="refs/remotes/$base" ;; esac
  case "$base" in
    refs/*) ;;
    *) _bt_refuse "base '$base' is not a full ref (refs/…) — refusing"; return 1 ;;
  esac
  if ! bt_git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    case "$base" in
      refs/remotes/origin/*)
        bt_git -C "$repo" fetch --quiet --no-tags origin "+refs/heads/${base#refs/remotes/origin/}:$base" >&2 || true ;;
    esac
    if ! bt_git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
      _bt_refuse "cannot resolve $base — refusing (fail closed)"; return 1
    fi
  fi

  # 2. The worktree is the trusted repo's, and its .git is not redirected.
  _bt_check_gitlink "$repo" "$wt" || return 1

  # 3. Symlinked parents.
  for p in "${_BRANCH_TRUST_PARENTS[@]}"; do
    [ -L "$wt/$p" ] && bad+="$p (symlink)"$'\n'
  done
  if [ -n "$bad" ]; then _bt_refuse "symlinked parent directories:" "${bad%$'\n'}"; return 1; fi

  # 4a. Base set: "<blob> <path>" for every base file under the trust paths (trusted repo).
  out=$(bt_git -c core.quotePath=true -C "$repo" ls-tree -r --full-tree "$base" -- "${BRANCH_TRUST_PATHS[@]}") \
    || { _bt_refuse "git ls-tree $base failed — refusing (fail closed)"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    meta=${line%%$'\t'*}; path=${line#*$'\t'}; mode=${meta%% *}; sha=${meta##* }
    case "$mode" in
      100644|100755) base_list+="$sha $path"$'\n' ;;
      *) bad+="$path (base entry mode $mode is not a regular file)"$'\n' ;;
    esac
  done <<EOF
$out
EOF

  # 4b. Disk set: walk each trust path without following symlinks; hash regular files.
  tmp=$(mktemp "${TMPDIR:-/tmp}/branch-trust.XXXXXX") || { _bt_refuse "mktemp failed — refusing"; return 1; }
  local base_paths
  base_paths=$(printf '%s' "$base_list" | sed 's/^[^ ]* //')
  for p in "${BRANCH_TRUST_PATHS[@]}"; do
    [ -e "$wt/$p" ] || [ -L "$wt/$p" ] || continue
    # Nothing on @@BASE@@ at or under this path: any non-directory entry refuses at the first one found (no
    # full walk of a planted node_modules); a tree of empty directories is inert and passes.
    if ! printf '%s\n' "$base_paths" | awk -v p="$p" '$0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }'; then
      rc=0; out=$(find "$wt/$p" ! -type d -print -quit 2>/dev/null) || rc=$?
      if [ "$rc" -ne 0 ] || [ -n "$out" ]; then bad+="$p (not on @@BASE@@ — must be absent)"$'\n'; fi
      continue
    fi
    rc=0; find "$wt/$p" -print0 > "$tmp" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then bad+="$p (find failed: unreadable entries)"$'\n'; continue; fi
    # A second link to a trust file lets someone outside the worktree rewrite it after the check.
    rc=0; out=$(find "$wt/$p" -type f -links +1 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then bad+="$p (find failed)"$'\n'; continue; fi
    if [ -n "$out" ]; then bad+=$(printf '%s\n' "$out" | sed "s|^$wt/||; s|\$| (hard link: more than one link)|")$'\n'; continue; fi
    while IFS= read -r -d '' e; do
      rel=${e#"$wt"/}
      case "$rel" in
        *$'\n'*|*$'\t'*|\"*) bad+="(entry with an unprintable name under $p)"$'\n'; continue ;;
      esac
      if [ -L "$e" ]; then bad+="$rel (symlink)"$'\n'
      elif [ -d "$e" ]; then :
      elif [ -f "$e" ]; then
        if sha=$(bt_git -C "$repo" hash-object --no-filters --stdin < "$e"); then
          disk_list+="$sha $rel"$'\n'
        else
          bad+="$rel (unreadable)"$'\n'
        fi
      else bad+="$rel (not a regular file)"$'\n'
      fi
    done < "$tmp"
  done
  rm -f -- "$tmp"
  if [ -n "$bad" ]; then _bt_refuse "trust paths hold entries that cannot be compared:" "${bad%$'\n'}"; return 1; fi

  # 4c. The two sets must be equal.
  base_list=$(printf '%s' "$base_list" | LC_ALL=C sort)
  disk_list=$(printf '%s' "$disk_list" | LC_ALL=C sort)
  if [ "$base_list" != "$disk_list" ]; then
    local bp dp changed
    # Only the labels below depend on this; the verdict is the inequality above. comm needs sorted input.
    bp=$(printf '%s\n' "$base_list" | sed 's/^[^ ]* //' | LC_ALL=C sort)
    dp=$(printf '%s\n' "$disk_list" | sed 's/^[^ ]* //' | LC_ALL=C sort)
    changed=$(LC_ALL=C comm -23 <(printf '%s\n' "$base_list") <(printf '%s\n' "$disk_list") | sed 's/^[^ ]* //' \
              | LC_ALL=C sort | LC_ALL=C comm -12 - <(printf '%s\n' "$dp"))
    out=$( { LC_ALL=C comm -23 <(printf '%s\n' "$bp") <(printf '%s\n' "$dp") | sed '/^$/d; s/$/ (on @@BASE@@, missing here)/'
             LC_ALL=C comm -13 <(printf '%s\n' "$bp") <(printf '%s\n' "$dp") | sed '/^$/d; s/$/ (not on @@BASE@@)/'
             printf '%s\n' "$changed" | sed '/^$/d; s/$/ (content differs from @@BASE@@)/'; } )
    _bt_refuse "trust files differ from $base:" "$out"; return 1
  fi
  return 0
}
