#!/usr/bin/env bash
# PreToolUse guard for Bash. Second line of defence behind settings.json `deny`:
# catches the spellings a prefix rule can't (git push origin HEAD:dev, --force-with-lease,
# in-place edits / redirects / copies onto protected files, dependency upgrades).
# Exit 2 = block + tell Claude why. Messages use single quotes only: backticks would execute.
set -euo pipefail
# Fail closed: any crash (an unbound variable on macOS bash 3.2, a missing node, …) blocks instead of
# exiting 1, which Claude Code treats as a non-blocking error and lets the command run.
trap 'rc=$?; [ "$rc" = 0 ] || [ "$rc" = 2 ] || { printf "BLOCKED by .claude/hooks/bash-guard.sh: the guard itself failed (exit %s) — refusing to pass an unchecked command.\n" "$rc" >&2; exit 2; }' EXIT
input=$(cat)
cmd=$(printf '%s' "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.tool_input?.command??""))}catch{process.stdout.write("")}})')

block() { printf 'BLOCKED by .claude/hooks/bash-guard.sh: %s\n' "$1" >&2; exit 2; }
has() { printf '%s' "$cmd" | grep -Eq -e "$1"; }
# One command segment per ';'-separated field: newlines and ; & | && || all split (read -a <<< reads one line only).
split_segs() { printf '%s' "$1" | tr '\n\r' ';;' | sed -E 's/(\|\||&&|[|;&])/;/g'; }
# Globs are expanded against the cwd before matching, so `cp x .en?` reads as `cp x .env`.
expand_globs() {
  local w m out="$cmd"
  set -f
  for w in $cmd; do
    case "$w" in
      *[?[]*) ;;                                   # has ? or [ → expand
      *[*]*) case "$w" in *[!*]*) ;; *) continue ;; esac ;;   # bare *, **, ***: skip (glob of cwd, costly, useless)
      *) continue ;;
    esac
    set +f; m=$( (compgen -G "$w" 2>/dev/null || true) | tr '\n' ' '); set -f
    [ -n "$m" ] && out=${out//"$w"/$m}
  done
  set +f
  cmd=$out
}
raw_cmd=$cmd
normalize() {
  # Matching runs on a normalized copy: quotes and backslashes removed, so 'de'v / de\v / .e""nv read as dev / .env.
  local bb nl
  bb='\\'; cmd=${cmd//"$bb"/}   # F-i: drop escaped backslashes first, so an even run before a newline is not read as a continuation
  nl=$'\\\n'; cmd=${cmd//"$nl"/}   # join backslash-newline continuations (bash, not sed: BSD sed's N drops the last line)
  cmd=$(printf '%s' "$cmd" | tr -d '"'"'"'\\')
  expand_globs
}

run_checks() {
# --- pushes that bypass the PR flow ---
if has '(git([[:space:]]+(-C|-c|--git-dir=?|--work-tree=?)[[:space:]]*[^[:space:]]+|[[:space:]]+--no-pager)*[[:space:]]+push|git[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)*)*push)[^|;&]*[[:space:]:+"'"'"'](refs/)?(heads/)?(@@PROTECTED_ALT@@)["'"'"']?([[:space:];&|)]|$)'; then
  block 'direct push to @@PROTECTED_SLASH@@. Open a PR and merge it (gh pr merge) when CI is green.'
fi
if has '(git([[:space:]]+(-C|-c|--git-dir=?|--work-tree=?)[[:space:]]*[^[:space:]]+|[[:space:]]+--no-pager)*[[:space:]]+push|git[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)*)*push)[^|;&]*(--force|-f([[:space:]]|$)|--force-with-lease|--mirror|--all|[[:space:]]\+[^[:space:]]+)'; then
  block 'force push. Never rewrite remote history.'
fi
if has 'gh[[:space:]]+api[^|;&]*(-X[[:space:]=]*|--method[[:space:]=]*)(POST|PATCH|PUT|DELETE)' || has 'gh[[:space:]]+api[^|;&]*([[:space:]]-[a-zA-Z]*[fF]|--field|--raw-field|--input)'; then
  block 'writes through the GitHub API are not allowed. PRs move via gh pr create / gh pr merge after an APPROVE; comments via gh pr comment.'
fi
if has '(git([[:space:]]+(-C|-c|--git-dir=?|--work-tree=?)[[:space:]]*[^[:space:]]+|[[:space:]]+--no-pager)*[[:space:]]+push|git[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)*)*push)[^|;&>]*[[:space:]][^[:space:]>]*[{$`]'; then
  block 'a push refspec with brace expansion, a variable or a command substitution cannot be checked. Spell the branch out.'
fi
# --- a push with no refspec, or HEAD, pushes the CURRENT branch: resolve it and refuse @@PROTECTED_SLASH@@ ---
if has '(git([[:space:]]+(-C|-c|--git-dir=?|--work-tree=?)[[:space:]]*[^[:space:]]+|[[:space:]]+--no-pager)*[[:space:]]+push|git[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)*)*push)([[:space:];&|]|$)'; then
  dir=$(printf '%s' "$cmd" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"?([^[:space:]"]+)"?.*/\1/p' | head -1)
  # Current-branch check runs PER LINE (origin/dev's sed semantics) with the last-`git … push` regex
  # on each line; any line with a bare/HEAD/@ push while on @@PROTECTED_SLASH@@ blocks. Union: never weaker.
  re=".*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+push([[:space:]#;&|].*)?$"
  re2=".*git[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)*)*push([[:space:]#;&|].*)?$"
  cur=""
  while IFS= read -r rawline || [ -n "$rawline" ]; do
    [[ "$rawline" == \#* ]] && continue
    cutline=${rawline%% \#*}   # the #-cut copy covers `git push origin HEAD # note`; the uncut one covers a quoted " #"
    # check the whole line AND each [;&|]-separated segment: `git push; git push origin feat/x` has two pushes
    IFS=';' read -r -a _parts <<< "$(printf '%s' "$rawline" | sed -E 's/(\|\||&&|[|;&])/;/g')"
    IFS=';' read -r -a _cparts <<< "$(printf '%s' "$cutline" | sed -E 's/(\|\||&&|[|;&])/;/g')"
    for line in "$rawline" "$cutline" ${_parts[@]+"${_parts[@]}"} ${_cparts[@]+"${_cparts[@]}"}; do   # bash 3.2: an empty array is unbound under set -u
    # arm 1: option values are single words (origin/dev + r4 shape); arm 2: option values may span
    # several words after quote stripping (`-c "a b" push origin HEAD`). Either arm yields the tail.
    if [[ "$line" =~ $re ]]; then tail=${BASH_REMATCH[3]}
    elif [[ "$line" =~ $re2 ]]; then tail=${BASH_REMATCH[3]}
    else continue; fi
    tail=${tail%%[;&|]*}   # no '#' cut: the cutline copy handles real comments; a quoted ' #' must not hide a later HEAD
    nonopt=0; headref=0
    set -f
    for tok in $tail; do
      case "$tok" in
        -*) ;;
        HEAD|HEAD:|HEAD:*|@|@:|@:*|+HEAD|+HEAD:*) headref=1; nonopt=$((nonopt+1)) ;;   # an explicit HEAD/@ token anywhere → current branch
        *) nonopt=$((nonopt+1)) ;;
      esac
    done
    set +f
    if [ "$nonopt" -le 1 ] || [ "$headref" = 1 ]; then
      [ -n "$cur" ] || cur=$( [ "${GUARD_TEST_MODE:-}" = 1 ] && [ -n "${GUARD_CURRENT_BRANCH:-}" ] && printf '%s' "$GUARD_CURRENT_BRANCH" || git --no-optional-locks ${dir:+-C "$dir"} symbolic-ref --short HEAD 2>/dev/null || true)   # GUARD_TEST_MODE=1 + GUARD_CURRENT_BRANCH: test injection only
      # S5: -C <dir> that resolves no branch (missing dir, not a repo) falls back to the cwd's branch. A -C repo with
      # a detached HEAD (symbolic-ref fails there too) also falls back to the cwd's branch: errs on the safe side.
      [ -n "$cur" ] || [ -z "$dir" ] || cur=$(git --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || true)
      case "$cur" in
        @@PROTECTED_CASE@@) block "you are on '$cur': a push with no refspec (or HEAD) would push it directly. Work on a feature branch and open a PR." ;;
      esac
    fi
    done
  done <<< "$cmd"
fi
if has 'gh[[:space:]]+pr[[:space:]]+(create|edit)[^|;]*(--base|-B)[[:space:]=]*["'"'"']?(@@RELEASE_ALT@@)([[:space:];&|)]|$)'; then
  block 'PRs target @@BASE@@, never @@RELEASE@@. @@RELEASE@@ moves only by a human.'
fi
# S6a: the admin check runs BEFORE the base lookup (which would otherwise answer first), and also
# matches -R/--repo (or anything) between gh, pr and merge.
if has 'gh[[:space:]]+pr[[:space:]]+merge[^|;&]*--admin' || has 'gh[[:space:]]+([^|;&]*[[:space:]])?pr[[:space:]]+([^|;&]*[[:space:]])?merge[[:space:]]([^|;&]*[[:space:]])?--admin'; then
  block 'admin merge bypasses the checks. Merge only when CI is green and the review is APPROVE.'
fi
# S7: `gh pr -R o/r merge N` / `gh pr --repo=o/r merge N` (the persistent repo flag before merge) is a merge too.
_ghmerge_re='gh[[:space:]]+pr[[:space:]]+((-R|--repo)([[:space:]]+|=)?[^[:space:]]+[[:space:]]+)*merge([[:space:]]|$)'
if has 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || has "$_ghmerge_re"; then
  # Each command segment is checked on its own; the first positional after `merge` must be a PR
  # number, #number or a /pull/N url (values of -R/-t/-b/-F/-A/--match-head-commit are skipped).
  set -f
  IFS=';' read -r -a _segs <<< "$(split_segs "$cmd")"
  for seg in ${_segs[@]+"${_segs[@]}"}; do
    printf '%s' "$seg" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' || printf '%s' "$seg" | grep -Eq "$_ghmerge_re" || continue
    # S7: the segment's -R/--repo value (before or after merge) is passed to gh pr view.
    repo=$(printf '%s' "$seg" | sed -nE 's/.*(^|[[:space:]])(-R|--repo)([[:space:]]+|=)?([^-[:space:]][^[:space:]]*).*/\4/p' | head -1)
    # Union: the tail after the last plain `gh pr merge` AND the tail after the last `gh pr [-R x] merge`.
    # The 'T:' prefix tells "no match" (empty output) from "matched with an empty tail" (bare merge).
    _lasthit=""
    for _tailre in 's/.*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*(.*)$/T:\1/p' 's/.*gh[[:space:]]+pr[[:space:]]+((-R|--repo)([[:space:]]+|=)?[^[:space:]]+[[:space:]]+)*merge[[:space:]]*(.*)$/T:\4/p'; do
      _tailhit=$(printf '%s' "$seg" | sed -nE "$_tailre" | head -1)
      [ -n "$_tailhit" ] && [ "$_tailhit" != "$_lasthit" ] || continue   # same tail twice → one gh lookup
      _lasthit=$_tailhit; tail=${_tailhit#T:}
      prn=""; skip=0; bad=0
      for tok in $tail; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$tok" in
          -R|--repo|-t|--subject|-b|--body|-F|--body-file|-A|--author-email|--match-head-commit) skip=1 ;;
          -*) ;;
          *://*/pull/[0-9]*) [ -z "$prn" ] && { prn=${tok##*/pull/}; prn=${prn%%[!0-9]*}; } ;;
          \#[0-9]*|[0-9]*) [ -z "$prn" ] && { prn=${tok#\#}; prn=${prn%%[!0-9]*}; } ;;
          *) [ -z "$prn" ] && bad=1 ;;
        esac
      done
      [ "$bad" = 1 ] && [ -z "$prn" ] && block 'gh pr merge: name the PR by number or URL (branch-name selectors are refused).'
      # The repo-less lookup (origin/dev's) ALWAYS runs: $repo comes from a quote-stripped segment, so a
      # quoted '-R o/r' in a -b body must not replace it. With a -R/--repo value the -R lookup runs too;
      # either one empty or 'main' blocks (union).
      for _ghrepo in "" ${repo:+"$repo"}; do
        if [ -n "$prn" ]; then
          base=$(gh pr view "$prn" ${_ghrepo:+-R "$_ghrepo"} --json baseRefName --jq .baseRefName 2>/dev/null || true)
        else
          base=$(gh pr view ${_ghrepo:+-R "$_ghrepo"} --json baseRefName --jq .baseRefName 2>/dev/null || true)   # PR of the current branch
        fi
        [ -z "$base" ] && block 'cannot resolve the PR base (gh pr view failed) — merge refused. Name the PR number and make sure gh is authenticated.'
        case "$base" in @@RELEASE_CASE@@) block "PR${prn:+ #$prn} targets $base. Only a human merges into $base." ;; esac
      done
    done
  done
  set +f
fi
# --- the pre-push hook is the real @@PROTECTED_SLASH@@ barrier: nothing may disable or bypass it ---
# 1. hard bypass spellings — always blocked
if has '(git[[:space:]]+([^|;&]*[[:space:]])?push[^|;&]*(--no-v[a-z]*|[[:space:]]-n([[:space:]]|$)))|GIT_PUSH_TO_PROTECTED|GIT_CONFIG_(COUNT|KEY|VALUE|PARAMETERS)|[Ii][Nn][Cc][Ll][Uu][Dd][Ee]\.[Pp][Aa][Tt][Hh]|[[:space:]]-c[[:space:]]*[Aa][Ll][Ii][Aa][Ss]\.|git[[:space:]]+rebase[^|;&]*([[:space:]]-[a-zA-Z]*x|--exec)|git[[:space:]]+([^|;&]*[[:space:]])?--output[=[:space:]]|git[[:space:]]+(fetch|pull|clone|ls-remote)[^|;&]*(--upload-pack|--exec[=[:space:]]|[[:space:]]-u[[:space:]])|git[[:space:]]+push[^|;&]*(--receive-pack|--exec[=[:space:]])'; then
  block 'the pre-push hook must not be bypassed: no --no-verify / -n on push, no GIT_PUSH_TO_PROTECTED, no GIT_CONFIG_* / include.path / -c alias.* / rebase -x / git --output / --upload-pack / --receive-pack.'
fi
# S1: git accepts unique-prefix abbreviations of long options; --o/--ou/--out/--outp/--outpu all mean --output.
# (--oneline, --ours, --onto, --orphan and --output-indicator-* do not match.)
if has 'git[[:space:]]+([^|;&]*[[:space:]])?--o(u(t(p(u(t)?)?)?)?)?([=[:space:]]|$)'; then
  block 'the pre-push hook must not be bypassed: git --output (or an abbreviation of it such as --out / --outp) writes a file.'
fi
# S2: config keys whose value git RUNS as a command, set via -c / --config-env / git config. Checked per segment;
# a segment that is a pure read of git config (a read flag, or the one-argument 'git config KEY') passes. Keys are matched case-insensitively, any subsection.
# A subsection is matched with [^=]+ (not [^[:space:]=]+): a quoted subsection may hold spaces
# ('diff.a b.textconv'), which normalize leaves as separate words; the -c / --config-env value's '=' still ends it.
_cmdkey='(core\.(pager|editor|fsmonitor|sshcommand|askpass|gitproxy|alternaterefscommand)|submodule\.[^=]+\.update|trailer\.[^=]+\.(cmd|command)|imap\.tunnel|sequence\.editor|diff\.external|diff\.[^=]+\.(textconv|command)|merge\.[^=]+\.driver|filter\.[^=]+\.(clean|smudge|process)|tar\.[^=]+\.command|credential(\.[^=]+)?\.helper|gpg(\.[^=]+)?\.program|gpg\.ssh\.defaultkeycommand|pager\.[^[:space:]=]+|uploadpack\.packobjectshook|remote\.[^=]+\.(uploadpack|receivepack|vcs)|protocol(\.[^=]+)?\.allow|interactive\.difffilter|web\.browser|(browser|man|mergetool|difftool)\.[^=]+\.(cmd|path)|includeif\.[^=]+\.path|alias\.[^[:space:]=]+|sendemail\.[^[:space:]=]+)'
_cfgread='^[[:space:]]*git([[:space:]]+(-C[[:space:]]*[^[:space:]]+|--no-pager|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+))*[[:space:]]+config([[:space:]]+(--type[=[:space:]][^[:space:]]+|--default[=[:space:]][^[:space:]]+|--global|--local|--system|--worktree|--file[=[:space:]][^[:space:]]+|-f[[:space:]]+[^[:space:]]+|--includes|--no-includes|--null|-z|--name-only))*[[:space:]]+((--get|--get-all|--get-regexp|-l|--list|--show-origin|--show-scope|get|list)([[:space:]]|$)|[^-[:space:]][^[:space:]]*[[:space:]]*$)'
if has '[Cc][Oo][Nn][Ff][Ii][Gg]|-c'; then
  set -f
  IFS=';' read -r -a _cfgsegs <<< "$(split_segs "$cmd")"
  for seg in ${_cfgsegs[@]+"${_cfgsegs[@]}"}; do
    if printf '%s' "$seg" | grep -Eiq "git[[:space:]]+([^|;&]*[[:space:]])?(-c[[:space:]]*|--config-env[=[:space:]]+)$_cmdkey(=|[[:space:]]|$)"; then
      block 'git config keys that run a command (core.pager/editor/fsmonitor/sshCommand, diff textconv/external, filters, credential helpers, gpg.program, protocol allow, ...) may not be set via -c, --config-env or git config. Use --no-pager / GIT_EDITOR=true instead of -c.'
    fi
    if printf '%s' "$seg" | grep -Eiq "git[[:space:]]+([^|;&]*[[:space:]])?config[[:space:]]([^|;&]*[[:space:]])?$_cmdkey([[:space:]=]|$)" \
       && ! printf '%s' "$seg" | grep -Eq "$_cfgread"; then
      block 'git config keys that run a command (core.pager/editor/fsmonitor/sshCommand, diff textconv/external, filters, credential helpers, gpg.program, protocol allow, ...) may only be read (git config --get). Use --no-pager / GIT_EDITOR=true instead.'
    fi
  done
  set +f
fi
# 2. core.hooksPath: only pure reads of git config are allowed
if has '[Hh][Oo][Oo][Kk][Ss]\.?[Pp][Aa][Tt][Hh]'; then
  has '^[[:space:]]*(git[[:space:]]+config[[:space:]]+(--get|--get-all|-l|--list|--show-origin)|(grep|rg|cat|less|head|tail|bat)[[:space:]])[^|;&>]*$' || block 'core.hooksPath may only be read (git config --get core.hooksPath, grep); changing it is not allowed.'
  # S8: the same read test per segment (newlines included), so one read line cannot vouch for another line.
  set -f
  IFS=';' read -r -a _hpsegs <<< "$(split_segs "$cmd")"
  for seg in ${_hpsegs[@]+"${_hpsegs[@]}"}; do
    printf '%s' "$seg" | grep -Eq '[Hh][Oo][Oo][Kk][Ss]\.?[Pp][Aa][Tt][Hh]' || continue
    printf '%s' "$seg" | grep -Eq '^[[:space:]]*(git[[:space:]]+config[[:space:]]+(--get|--get-all|-l|--list|--show-origin)|(grep|rg|cat|less|head|tail|bat)[[:space:]])[^|;&>]*$' \
      || block 'core.hooksPath may only be read (git config --get core.hooksPath, grep); changing it is not allowed.'
  done
  set +f
fi
# 3. the hook files (scripts/git-hooks, .git/hooks, protected-hooks): EVERY segment that names them must be a
#    plain read with no redirect; git subcommands that write files (checkout/restore/switch/reset/add --chmod/
#    update-index/rm/mv/stash/apply) on the hook DIR are blocked
if has 'scripts/git-hooks|\.git/|protected-hooks'; then
  set -f
  IFS=';' read -r -a _hsegs <<< "$(printf '%s' "$cmd" | sed -E 's/(\|\||&&|[|;&])/;/g')"
  for seg in ${_hsegs[@]+"${_hsegs[@]}"}; do
    printf '%s' "$seg" | grep -Eq 'scripts/git-hooks|\.git/|protected-hooks' || continue
    printf '%s' "$seg" | grep -Eq '>' && block 'redirecting into or next to the pre-push hook is not allowed.'
    printf '%s' "$seg" | grep -Eq '^[[:space:]]*((uv[[:space:]]+run[[:space:]]+)?(cat|less|head|tail|grep|rg|bat|ls|wc|file|stat|diff)|bash[[:space:]]+-n|sh[[:space:]]+-n|git[[:space:]]+(diff|show|log|status|ls-files|blame))([[:space:]]|$)' \
      || block 'the pre-push hook (scripts/git-hooks, protected-hooks) may only be read by an agent; writing, moving, chmod-ing, checking out or restoring it is not allowed.'
  done
  set +f
fi
# 4. spawn requests start a worker as the human, outside every guard: only the orchestrator (Cowork) writes them.
#    Every segment that names .claude/bridge/spawn or spawn-log must be a plain read with no redirect.
if has 'bridge/spawn(-log)?([/[:space:]]|$)'; then
  set -f
  IFS=';' read -r -a _ssegs <<< "$(split_segs "$cmd")"
  for seg in ${_ssegs[@]+"${_ssegs[@]}"}; do
    printf '%s' "$seg" | grep -Eq 'bridge/spawn(-log)?([/[:space:]]|$)' || continue
    printf '%s' "$seg" | grep -Eq '>' && block 'writing spawn requests is the orchestrator'"'"'s job, not a worker'"'"'s.'
    printf '%s' "$seg" | grep -Eq '^[[:space:]]*(cat|less|head|tail|grep|rg|ls|wc|file|stat)([[:space:]]|$)' \
      || block 'writing spawn requests is the orchestrator'"'"'s job, not a worker'"'"'s (.claude/bridge/spawn may only be read).'
  done
  set +f
fi
# --- destructive git / fs ---
if has 'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-z]*f|branch[[:space:]]+-D)'; then
  block 'destructive git command. Stash or ask instead.'
fi
if has '(^|[[:space:];&|])rm[[:space:]]+-[a-zA-Z]*r'; then
  block 'recursive rm. Move to _to_delete/ and report instead.'
fi
# --- schema + deps ---
if has 'supabase[[:space:]]+db[[:space:]]+(push|reset)'; then
  block 'applying a schema migration is a human decision. Write the migration proposal and return status=blocked.'
fi
if has 'uv[[:space:]]+(lock[[:space:]]+--upgrade|sync[[:space:]]+--upgrade|add[[:space:]][^|;&]*--upgrade|remove)'; then
  block 'upgrading/removing pinned dependencies is not allowed. Only "uv add <pkg>" for a dependency the task explicitly approves.'
fi
# Node package managers: same rule (add an approved package by name; never update, upgrade or remove).
if has '(npm|pnpm|yarn|bun)[[:space:]]+(update|upgrade|up|outdated[[:space:]]+--fix|uninstall|remove|rm|un|dedupe|audit[[:space:]]+fix)([[:space:]]|$)' || has '(npx[[:space:]]+)?(npm-check-updates|ncu)([[:space:]]|$)' || has '(npm|pnpm|yarn|bun)[[:space:]]+(install|i|add)[^|;&]*@(latest|next)([[:space:]]|$)'; then
  block 'upgrading/removing pinned dependencies is not allowed. Only "npm install <pkg>" (or the pnpm/yarn equivalent) for a dependency the task explicitly approves.'
fi
# --- writes onto protected files (read-only access is fine: sed -n, cat, grep, python …) ---
# S6b: '.env' directly followed by a command separator (tee .env; echo / > .env&& …) is the same file; the
# origin/dev set ([./[:space:]"']|$) let those through. Union: the set only grows.
protected='(pyproject\.toml|uv\.lock|package\.json|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|\.env([./[:space:]"'"'"';&|)]|$)|supabase/migrations/|@@MIGRATIONS_RE@@/|\.github/workflows/|\.claude/settings(\.local)?\.json|\.claude/hooks/|\.claude/orchestration\.conf)'
# for cp/mv/ln the protected path must be the DESTINATION (last argument), so `cp -p .env /tmp/x` stays a read
dest_protected='(pyproject\.toml|uv\.lock|package\.json|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|\.claude/orchestration\.conf|\.env([.][^[:space:]"'"'"']*)?|supabase/migrations/[^[:space:]"'"'"']*|@@MIGRATIONS_RE@@/[^[:space:]"'"'"']*|\.github/workflows/[^[:space:]"'"'"']*|\.claude/settings(\.local)?\.json|\.claude/hooks/[^[:space:]"'"'"']*)["'"'"']?[[:space:]]*([0-9]?>[>|]?[[:space:]]*(&[0-9-]|[^[:space:];&|]+)[[:space:]]*|&>>?[[:space:]]*[^[:space:];&|]+[[:space:]]*)*(#[^;&|]*)?($|[;&|])'
if has "(^|[;&|][[:space:]]*)((uv[[:space:]]+run|env|sudo|nice|time|command|exec|xargs|timeout)([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+([0-9]+[smh]?[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*(sed[[:space:]]([^|;&]*[[:space:]])?(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i|tee([[:space:]]+-a)?)[^|;&]*$protected" \
   || has ">[>|]?[[:space:]]*\"?'?[^[:space:];&|]*$protected" \
   || has "(^|[;&|][[:space:]]*)((uv[[:space:]]+run|env|sudo|nice|time|command|exec|xargs|timeout)([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+([0-9]+[smh]?[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*sed[[:space:]][^|;&]*[0-9$/;,{}!gpIM[:space:]][wW][[:space:]]*[^[:space:];&|]*$protected" \
   || has "-exec(dir)?[[:space:]]+([^[:space:]]*/)?(cp|mv|ln|tee|sed|perl|install|rsync|sh|bash)[[:space:]][^;]*$protected" \
   || has "(^|[;&|][[:space:]]*)((uv[[:space:]]+run|env|sudo|nice|time|command|exec|xargs|timeout)([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+([0-9]+[smh]?[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*find[[:space:]][^|;&]*$protected[^|;&]*-(exec|execdir|ok|okdir)[[:space:]]+([^[:space:]]*/)?(cp|mv|ln|tee|sed|perl|install|rsync|sh|bash)([[:space:]]|$)" \
   || has "[-](fprint0?|fprintf|fls)[[:space:]]+[^[:space:]]*$protected" \
   || has "(^|[;&|][[:space:]]*)((uv[[:space:]]+run|env|sudo|nice|time|command|exec|xargs|timeout)([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+([0-9]+[smh]?[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*(cp|mv|ln|install|rsync)[[:space:]][^|;&]*[[:space:]][\"']?([^[:space:];&|]*/)?$dest_protected" \
   || has "(^|[;&|][[:space:]]*)((uv[[:space:]]+run|env|sudo|nice|time|command|exec|xargs|timeout)([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+([0-9]+[smh]?[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*(cp|mv|rsync)([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+[\"']?([^[:space:];&|\"']*/)?\.env([.][^[:space:]\"']*)?[\"']?[[:space:]]+(\.|\./|[^/[:space:];&|][^[:space:];&|]*/|[\"']?[$](PWD|CLAUDE_PROJECT_DIR)[\"']?)[[:space:]]*($|[;&|])"; then
  block 'writing a protected file through the shell. Dependency manifests and lockfiles change only via the package manager (uv add / npm install <pkg>) for an approved dependency; .env/migrations/CI/settings/hooks/orchestration.conf are human-owned.'
fi
}

# Pass 1: line by line (grep semantics) on the normalized command.
cmd=$raw_cmd; normalize; run_checks
# Pass 2: from the RAW command. When the quote tracker can model the command (no $'…', no heredoc,
# no unquoted #, balanced quotes) a newline outside quotes becomes ';' and inside quotes ' ', so a
# newline smuggled into a quoted argument cannot split a match while multi-line commands keep their
# structure. Otherwise it falls back to every newline → space (the stricter origin/dev behaviour).
# S7: a '$(' or backtick inside double quotes opens a nested quoting context the tracker does not model:
# it still prints its output but exits 4, and BOTH the tracker output and the fallback are checked (union).
p2rc=0
p2=$(printf '%s' "$raw_cmd" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{if(s.includes("$\x27")||/<<-?[\x27"]?[A-Za-z_]/.test(s))process.exit(3);let o="",q=null,esc=false,ws=true,sub=false;for(const c of s){if(esc){o+=c;esc=false;ws=false;continue;}if(c==="\\"&&q!=="\x27"){o+=c;esc=true;ws=false;continue;}if(q){if(q==="\""&&(c==="`"||(c==="("&&o.endsWith("$"))))sub=true;if(c===q)q=null;o+=(c==="\n"||c==="\r")?" ":c;ws=false;continue;}if(c==="#"&&ws)process.exit(3);if(c==="\x27"||c==="\""){q=c;o+=c;ws=false;continue;}if(c==="\n"||c==="\r"){o+=";";ws=true;continue;}o+=c;ws=(c===" "||c==="\t"||c===";"||c==="&"||c==="|"||c==="(");}if(q)process.exit(3);process.stdout.write(o);if(sub)process.exitCode=4})') || p2rc=$?
if [ "$p2rc" = 0 ] || [ "$p2rc" = 4 ]; then
  cmd=$p2; normalize; run_checks
fi
if [ "$p2rc" != 0 ]; then
  cmd=$(printf '%s' "$raw_cmd" | tr '\n\r' '  '); normalize; run_checks
fi
# Passes 3 + 4 (S3, S4, S6b): a comment-aware quote tracker. A '#' at word start outside quotes skips to the
# end of the line (pass 2 gives up on it), an unquoted newline becomes ';'. $'…' is modelled as a quoted string
# whose backslash escapes are honoured (\' does not close it). It gives up (exit 3, both passes skipped) on a
# heredoc, unbalanced quotes, or '$(' / a backtick inside double quotes.
#   pass 3: quoted text kept verbatim (a newline inside quotes → space), as pass 2 does; $'…' keeps its '$';
#   pass 4: every quoted string holding whitespace (incl. $'…') collapsed to the single token Q, so a quoted
#           value cannot pose as the push subcommand or as a refspec (git -c a=" push x y" push → git -c a=Q push).
_split='@@GUARD_PASS_SPLIT@@'
p34=$(printf '%s' "$raw_cmd" | node -e '
const SPLIT = process.argv[1];
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  if (s.includes(SPLIT) || /<<-?[\x27"]?[A-Za-z_]/.test(s)) process.exit(3);
  // v = pass 3 text, k = pass 4 text. q: null | "\x27" | "\"" | "A" (ANSI-C $\x27…\x27, closed by \x27).
  let v = "", k = "", q = null, buf = "", esc = false, ws = true, com = false, dol = false;
  for (const c of s) {
    if (com) { if (c === "\n" || c === "\r") com = false; else continue; }
    if (esc) { if (q) buf += c; else { v += c; k += c; } esc = false; ws = false; dol = false; continue; }
    if (c === "\\" && q !== "\x27") { if (q) buf += c; else { v += c; k += c; } esc = true; ws = false; dol = false; continue; }
    if (q) {
      if (c === (q === "A" ? "\x27" : q)) {
        const flat = buf.replace(/[\n\r]/g, " "), quote = q === "A" ? "\x27" : q;
        v += quote + flat + quote;   // for $\x27…\x27 the "$" is already in v
        if (/\s/.test(buf)) k = (q === "A" ? k.slice(0, -1) : k) + "Q";
        else k += quote + buf + quote;
        q = null; buf = ""; continue;
      }
      if (q === "\"" && (c === "`" || (c === "(" && buf.endsWith("$")))) process.exit(3);
      buf += c; continue;
    }
    if (c === "#" && ws) { com = true; continue; }
    if (c === "\x27" || c === "\"") { q = (c === "\x27" && dol) ? "A" : c; ws = false; dol = false; continue; }
    if (c === "\n" || c === "\r") { v += ";"; k += ";"; ws = true; dol = false; continue; }
    v += c; k += c;
    ws = (c === " " || c === "\t" || c === ";" || c === "&" || c === "|" || c === "(");
    dol = (c === "$");
  }
  if (q) process.exit(3);
  process.stdout.write(v + SPLIT + k);
})' "$_split") && {
  cmd=${p34%%"$_split"*}; normalize; run_checks
  cmd=${p34#*"$_split"}; normalize; run_checks
}
exit 0
