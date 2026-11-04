#!/usr/bin/env bash
# Creates a brand-new project: a git repository and the folders Tentacl needs, then checks the result with validate-config.sh.
# Usage: create-project.sh [--existing [--branch <name>] [--init-git --files <list-file> | --no-git]] [--build-command <cmd>] [--test-command <cmd>] <repoDir> <dataDir> <id> <name> <other|ios> [xcodeName] [simulatorDevice]
#   --existing: the repository is already there (a git repository with its own history); it is not touched, only the data folder is
#     created. --branch records its main branch in project.json when it is not "main".
#   --init-git (with --existing): the folder is not a git repository yet. Runs git init, adds ".agent-worktrees/" to .gitignore (an
#     existing one is kept, the line is appended) and commits only the files named in <list-file> (one relative path per line) plus
#     .gitignore. If a step fails, the .git folder and the .gitignore change are undone.
#   --init-git --list-files <repoDir>: a dry run, writes nothing; prints the number of files that would be added, then their paths
#     (respecting .gitignore), for the confirmation sheet.
#   --no-git (with --existing): the folder is not a git repository and stays that way (nothing in it is written); the panel offers
#     "Initialize git" afterwards. Refused for a repository or a folder inside one.
#   --build-command <cmd>: recorded as buildCommand in a new project.json (for ios it replaces the xcodebuild template).
#   --test-command <cmd>: recorded as testCommand in a new project.json.
# Never touches anything that exists: a repo folder or data folder that is already there is refused (exit 1, nothing written).
# If a step fails, only what this run created is removed.
# Exit: 0 created; 1 refused or failed; 2 usage.
# Env: TENTACL_ROLES_DIR (shared roles, default ~/.config/tentacl/roles) decides which roles the default team chart uses.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
existing=""; branch="main"; init_git=""; no_git=""; list_files=""; files_list=""; test_cmd=""; have_test_cmd=""; build_cmd=""; have_build_cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --existing) existing=1; shift ;;
    --branch) [ $# -ge 2 ] || { echo "ERROR: --branch needs a name" >&2; exit 2; }; branch=$2; shift 2 ;;
    --init-git) init_git=1; shift ;;
    --no-git) no_git=1; shift ;;
    --list-files) list_files=1; shift ;;
    --files) [ $# -ge 2 ] || { echo "ERROR: --files needs a list file" >&2; exit 2; }; files_list=$2; shift 2 ;;
    --build-command) [ $# -ge 2 ] || { echo "ERROR: --build-command needs a command" >&2; exit 2; }; build_cmd=$2; have_build_cmd=1; shift 2 ;;
    --test-command) [ $# -ge 2 ] || { echo "ERROR: --test-command needs a command" >&2; exit 2; }; test_cmd=$2; have_test_cmd=1; shift 2 ;;
    --*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
usage() { echo "usage: create-project.sh [--existing [--branch <name>] [--init-git --files <list-file> | --no-git]] [--build-command <cmd>] [--test-command <cmd>] <repoDir> <dataDir> <id> <name> <other|ios> [xcodeName] [simulatorDevice]" >&2; exit 2; }
[ -z "$init_git" ] || [ -n "$existing" ] || { echo "ERROR: --init-git needs --existing" >&2; exit 2; }
[ -z "$no_git" ] || [ -n "$existing" ] || { echo "ERROR: --no-git needs --existing" >&2; exit 2; }
[ -z "$no_git" ] || [ -z "$init_git" ] || { echo "ERROR: --no-git and --init-git cannot go together" >&2; exit 2; }
[ -z "$list_files" ] || [ -n "$init_git" ] || { echo "ERROR: --list-files needs --init-git" >&2; exit 2; }
if [ -n "$list_files" ]; then
  [ $# -eq 1 ] || usage
  case "$1" in /*) ;; *) echo "ERROR: the repository folder must be an absolute path" >&2; exit 2 ;; esac
  [ -d "$1" ] || { echo "ERROR: $1 is not a folder" >&2; exit 1; }
  # A throwaway repository (outside the folder) applies .gitignore the way the real commit will.
  gd=$(mktemp -d) || exit 1; trap 'rm -rf "$gd"' EXIT
  export GIT_DIR="$gd" GIT_WORK_TREE="$1"
  git init -q >/dev/null 2>&1 || { echo "ERROR: git init failed" >&2; exit 1; }
  mkdir -p "$gd/info"; printf '.agent-worktrees/\n' > "$gd/info/exclude"
  list=$( { git ls-files -o --exclude-standard; [ -e "$1/.gitignore" ] || echo .gitignore; } | sort -u)
  printf '%s\n' "$(printf '%s\n' "$list" | grep -c .)"; printf '%s\n' "$list" | grep .
  exit 0
fi
if [ -n "$init_git" ]; then
  [ -n "$files_list" ] || { echo "ERROR: --init-git needs --files <list-file>" >&2; exit 2; }
  [ -f "$files_list" ] || { echo "ERROR: the file list $files_list is not a file" >&2; exit 2; }
fi
[ $# -ge 5 ] && [ $# -le 7 ] || usage
repo=$1; data=$2; id=$3; name=$4; preset=$5; xname=${6:-}; sim=${7:-iPhone 17 Pro}

# Every value is matched as a whole (a newline would otherwise let a second line past a line-by-line grep).
nl=$'\n'
for v in "$repo" "$data" "$id" "$name" "$xname" "$sim" "$branch" "$test_cmd" "$build_cmd"; do
  case "$v" in *"$nl"*|*$'\r'*) echo "ERROR: a value contains a line break" >&2; exit 2 ;; esac
done
[ -z "$have_test_cmd" ] || [ -n "$test_cmd" ] || { echo "ERROR: the test command is empty" >&2; exit 2; }
[ -z "$have_build_cmd" ] || [ -n "$build_cmd" ] || { echo "ERROR: the build command is empty" >&2; exit 2; }
case "$repo" in /*) ;; *) echo "ERROR: the repository folder must be an absolute path" >&2; exit 2 ;; esac
case "$data" in /*) ;; *) echo "ERROR: the data folder must be an absolute path" >&2; exit 2 ;; esac
[[ $id =~ ^[a-z][a-z0-9-]{1,39}$ ]] || { echo "ERROR: the id must be 2-40 lowercase letters, digits or dashes, starting with a letter" >&2; exit 2; }
[ -n "$name" ] || { echo "ERROR: the name is empty" >&2; exit 2; }
case "$preset" in other|ios) ;; *) echo "ERROR: preset must be other or ios" >&2; exit 2 ;; esac
if [ "$preset" = ios ]; then
  # Letters, digits, spaces, dots, dashes and underscores (an existing project may be called "My App"); it is quoted in the build command.
  [[ $xname =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,59}$ ]] || { echo "ERROR: the Xcode name must start with a letter or digit and have only letters, digits, spaces, dots, dashes or underscores" >&2; exit 2; }
fi

[[ $branch =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$ ]] && [[ ! $branch =~ (\.\.|//|\.lock$) ]] || { echo "ERROR: the main branch is not a plain branch name" >&2; exit 2; }
if [ -n "$init_git" ] || [ -n "$no_git" ]; then
  [ -d "$repo" ] || { echo "ERROR: $repo is not a folder" >&2; exit 1; }
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ "$(cd "$repo" && pwd -P)" = "$(cd "$(git -C "$repo" rev-parse --show-toplevel)" && pwd -P)" ]; then echo "ERROR: $repo is already a git repository" >&2; else echo "ERROR: $repo is inside another git repository" >&2; fi
    exit 1
  fi
fi
if [ -n "$init_git" ]; then
  # The list must hold plain relative paths of files that are there (checked before anything is written).
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    case "$f" in /*|../*|*/../*|*/..|..|.git|.git/*|*/.git/*|./*) echo "ERROR: the file list has a path that is not allowed: $f" >&2; exit 2 ;; esac
    [ -f "$repo/$f" ] || { echo "ERROR: the file list names a file that is not there: $f" >&2; exit 2; }
  done < "$files_list"
elif [ -n "$no_git" ]; then :
elif [ -n "$existing" ]; then
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$(cd "$repo" && pwd -P)" = "$(cd "$(git -C "$repo" rev-parse --show-toplevel)" && pwd -P)" ] \
    || { echo "ERROR: $repo is not a git repository (its top folder)" >&2; exit 1; }
else
  [ ! -e "$repo" ] || { echo "ERROR: $repo already exists; nothing was written" >&2; exit 1; }
fi
# An existing project may already have a data folder (its notes live in the wiki): it is used and only what is missing is added.
if [ -n "$existing" ]; then
  [ ! -e "$data" ] || [ -d "$data" ] || { echo "ERROR: $data exists and is not a folder" >&2; exit 1; }
else
  [ ! -e "$data" ] || { echo "ERROR: $data already exists; nothing was written" >&2; exit 1; }
fi
# The data folder must not be, or lie inside, the repository (resolved paths, so symlinks and ".." do not hide it).
canon() { local d b; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1; b=$(basename "$1"); [ -e "$1" ] && { (cd "$1" 2>/dev/null && pwd -P) && return 0; }; echo "$d/$b"; }
repo_real=$(canon "$repo") || repo_real=""; data_real=$(canon "$data") || data_real=""
if [ -n "$repo_real" ] && [ -n "$data_real" ]; then
  if [ "$repo_real" = "$data_real" ]; then echo "ERROR: the repository and the data folder are the same folder" >&2; exit 1; fi
  case "$data_real/" in "$repo_real"/*) echo "ERROR: the data folder would be inside the repository" >&2; exit 1 ;; esac
fi
[ -n "$existing" ] || [ -d "$(dirname "$repo")" ] || { echo "ERROR: the parent folder of $repo does not exist" >&2; exit 1; }
[ -d "$(dirname "$data")" ] || { echo "ERROR: the parent folder of $data does not exist" >&2; exit 1; }

made_repo=""; made_data=""; child=""; made_paths=(); made_git=""; gi_backup=""; gi_made=""
fail() {
  echo "ERROR: $*" >&2; [ -n "$child" ] && kill "$child" 2>/dev/null
  [ -n "$made_git" ] && rm -rf "$repo/.git"
  [ -n "$gi_made" ] && rm -f "$repo/.gitignore"
  [ -n "$gi_backup" ] && { cp "$gi_backup" "$repo/.gitignore"; rm -f "$gi_backup"; }
  [ -n "$made_repo" ] && rm -rf "$repo"; [ -n "$made_data" ] && rm -rf "$data"
  for p in ${made_paths[@]+"${made_paths[@]}"}; do rm -rf "$p"; done   # parts added to a data folder that was already there
  [ -n "${errfile:-}" ] && rm -f "$errfile"; exit 1
}
# A stopped run (timeout, quit) removes what it made too.
trap 'fail "interrupted"' TERM INT HUP

# 1. The repository (an existing one is left exactly as it is).
if [ -z "$existing" ]; then
mkdir "$repo" || fail "could not create $repo"; made_repo=1
git -C "$repo" init -q -b main || fail "git init failed"
printf '.agent-worktrees/\nbuild/\nxcuserdata/\n.DS_Store\n' > "$repo/.gitignore" || fail "could not write .gitignore"
printf '# %s\n' "$name" > "$repo/README.md" || fail "could not write README.md"
ident=()
if [ -z "$(git -C "$repo" config user.name 2>/dev/null)" ] || [ -z "$(git -C "$repo" config user.email 2>/dev/null)" ]; then ident=(-c user.name=Tentacl -c user.email=tentacl@localhost); fi
git -C "$repo" add .gitignore README.md || fail "git add failed"
# The commit ignores a global signing setup and hooks (a GPG prompt would hang it) and runs in the background so a stop can interrupt it.
git -C "$repo" ${ident[@]+"${ident[@]}"} -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "chore: initial commit" </dev/null &
child=$!
wait "$child" || fail "the initial commit failed"
child=""
fi

if [ -n "$init_git" ]; then
git -C "$repo" init -q -b "$branch" || fail "git init failed"; made_git=1
if [ -e "$repo/.gitignore" ]; then
  gi_backup=$(mktemp) && cp "$repo/.gitignore" "$gi_backup" || fail "could not back up .gitignore"
  { [ ! -s "$repo/.gitignore" ] || [ -z "$(tail -c1 "$repo/.gitignore")" ] || echo; echo '.agent-worktrees/'; } >> "$repo/.gitignore" || fail "could not update .gitignore"
else
  gi_made=1; printf '.agent-worktrees/\n' > "$repo/.gitignore" || fail "could not write .gitignore"
fi
ident=()
if [ -z "$(git -C "$repo" config user.name 2>/dev/null)" ] || [ -z "$(git -C "$repo" config user.email 2>/dev/null)" ]; then ident=(-c user.name=Tentacl -c user.email=tentacl@localhost); fi
git -C "$repo" add -- .gitignore || fail "git add failed"
# Only the confirmed files (literal paths, not patterns).
[ ! -s "$files_list" ] || GIT_LITERAL_PATHSPECS=1 git -C "$repo" add --pathspec-from-file="$files_list" || fail "git add failed"
git -C "$repo" ${ident[@]+"${ident[@]}"} -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "chore: initial commit" </dev/null &
child=$!
wait "$child" || fail "the initial commit failed"
child=""
fi

# 2. The data folder: tasks, project.json, team.json.
if [ -d "$data" ]; then
  for d in tasks agent-panel; do [ -d "$data/$d" ] || { mkdir "$data/$d" || fail "could not create $data/$d"; made_paths+=("$data/$d"); }; done
else
  mkdir "$data" || fail "could not create $data"; made_data=1
  mkdir -p "$data/tasks" "$data/agent-panel" || fail "could not create the project folders"
fi
keep_settings=""; [ -f "$data/agent-panel/project.json" ] && keep_settings=1   # settings that are already there are used as they are
[ -n "$keep_settings" ] || made_paths+=("$data/agent-panel/project.json")
if [ -n "$keep_settings" ]; then :
elif [ "$preset" = ios ]; then
  jq -n --arg id "$id" --arg name "$name" --arg repo "$repo" --arg data "$data" --arg x "$xname" --arg sim "$sim" \
    '{id:$id, name:$name, repoPath:$repo, dataDir:$data, maxParallel:2,
      buildCommand:("xcodebuild -project '"'"'" + $x + ".xcodeproj'"'"' -scheme '"'"'" + $x + "'"'"' -destination '"'"'id=$UDID'"'"' -derivedDataPath build/dd build"),
      xcodeProject:($x + ".xcodeproj"), simulator:{baseDevice:$sim}, sharedFiles:[], openWith:"Xcode", screenshots:false}' > "$data/agent-panel/project.json"
else
  jq -n --arg id "$id" --arg name "$name" --arg repo "$repo" --arg data "$data" \
    '{id:$id, name:$name, repoPath:$repo, dataDir:$data, maxParallel:2, sharedFiles:[], screenshots:false}' > "$data/agent-panel/project.json"
fi || fail "could not write project.json"

if [ -z "$keep_settings" ] && [ "$branch" != main ]; then
  jq --arg b "$branch" '.mainBranch=$b' "$data/agent-panel/project.json" > "$data/agent-panel/project.json.new" && mv "$data/agent-panel/project.json.new" "$data/agent-panel/project.json" || fail "could not record the main branch"
fi

if [ -z "$keep_settings" ] && [ -n "$have_build_cmd" ]; then
  jq --arg c "$build_cmd" '.buildCommand=$c' "$data/agent-panel/project.json" > "$data/agent-panel/project.json.new" && mv "$data/agent-panel/project.json.new" "$data/agent-panel/project.json" || fail "could not record the build command"
fi

if [ -z "$keep_settings" ] && [ -n "$have_test_cmd" ]; then
  jq --arg t "$test_cmd" '.testCommand=$t' "$data/agent-panel/project.json" > "$data/agent-panel/project.json.new" && mv "$data/agent-panel/project.json.new" "$data/agent-panel/project.json" || fail "could not record the test command"
fi

# The default team chart: pm > reviewer > dev and ui_dev, using only the shared roles that exist (a missing one is skipped).
roles=${TENTACL_ROLES_DIR:-$HOME/.config/tentacl/roles}
have() { [ -f "$roles/$1.json" ]; }
members=""
add() { members="${members:+$members,}$(jq -nc --arg r "$1" --arg b "${2:-}" '{role:$r, reportsTo:(if $b == "" then null else $b end)}')"; }
have pm && add pm
have reviewer && add reviewer "$(have pm && echo pm)"
for r in dev ui_dev; do
  if have "$r"; then boss=""; if have reviewer; then boss=reviewer; elif have pm; then boss=pm; fi; add "$r" "$boss"; fi
done
if [ ! -f "$data/agent-panel/team.json" ]; then
  made_paths+=("$data/agent-panel/team.json")
  printf '{"members":[%s]}\n' "$members" | jq . > "$data/agent-panel/team.json" || fail "could not write team.json"
fi

# 3. The result must pass the same checks the scripts use.
errfile=$(mktemp)
bash "$HERE/validate-config.sh" "$data/agent-panel/project.json" >/dev/null 2>"$errfile" || { msg=$(cat "$errfile"); fail "the project.json is not valid: $msg"; }
bash "$HERE/validate-config.sh" "$data/agent-panel/team.json" >/dev/null 2>"$errfile" || { msg=$(cat "$errfile"); fail "the team.json is not valid: $msg"; }
rm -f "$errfile"; [ -z "$gi_backup" ] || rm -f "$gi_backup"
echo "$data/agent-panel/project.json"
