#!/usr/bin/env bash
# Fast-forwards a task's branch into the project's main branch, after the checks that keep the user's work safe.
# Usage: merge-task.sh --inspect <project.json> <branch> <worktree>
#          Prints one JSON line {"head","base","repoBranch","ahead","behind","dirtyOverlap":[...],"worktreeDirty"}; changes nothing.
#        merge-task.sh <project.json> <branch> <worktree> --expect-head <sha>
#          Merges with `git merge --ff-only`; prints {"merged":"<new tip>"} (or {"merged":null} when the branch has no commits of its own).
#        merge-task.sh --rebase <project.json> <branch> <worktree>
#          When the branch is behind main and its worktree is clean, runs `git rebase <main>` in the worktree and prints {"rebased":"<new head>"}
#          ({"rebased":null} when there was nothing to rebase). On a conflict it runs `git rebase --abort`, changes nothing, prints the
#          conflicting files and exits 9. The panel only calls it when the agent is not working.
# Exit: 0 merged / nothing to merge; 2 usage or bad branch; 3 the repo is not on the main branch; 4 not a fast-forward (main moved);
#       5 unsaved changes in the repo are in the way (file names on stdout); 6 unsaved work in the agent's worktree (names on stdout);
#       7 the branch tip is not the one the user looked at (--expect-head); 8 git itself refused the merge or the rebase (its message is on stderr);
#       9 --rebase only: the rebase conflicts (file names on stdout; the branch is as it was).
# Nothing is changed unless every check passes. The main branch is `mainBranch` in project.json (default "main").
set -u
die() { echo "ERROR: $*" >&2; exit 2; }
usage() { echo "usage: merge-task.sh --inspect <project.json> <branch> <worktree>" >&2; echo "       merge-task.sh --rebase <project.json> <branch> <worktree>" >&2; echo "       merge-task.sh <project.json> <branch> <worktree> --expect-head <sha>" >&2; exit 2; }

inspect=""; rebase=""
[ "${1:-}" = "--inspect" ] && { inspect=1; shift; }
[ "${1:-}" = "--rebase" ] && { rebase=1; shift; }
[ $# -ge 3 ] || usage
project=$1; branch=$2; wt=$3; shift 3
expect=""
if [ -z "$inspect$rebase" ]; then
  [ "${1:-}" = "--expect-head" ] && [ -n "${2:-}" ] || die "--expect-head <sha> is required"
  expect=$2
  printf '%s' "$expect" | grep -Eq '^[0-9a-f]{40}$' || die "--expect-head must be the full 40-character commit id"
elif [ $# -ne 0 ]; then usage
fi
[ -f "$project" ] || die "project file not found: $project"
[ -d "$wt" ] || die "worktree not found: $wt"

# The branch name comes from a task card (written by an agent): check it before git ever sees it.
case "$branch" in
  -*|*..*|*//*|*.lock|*/|"") die "branch name not allowed: $branch" ;;
esac
printf '%s' "$branch" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$' || die "branch name not allowed: $branch"

repo=$(jq -r '.repoPath // empty' "$project"); base=$(jq -r '.mainBranch // "main"' "$project")
[ -d "$repo" ] || die "repoPath is not a folder: $repo"
git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null || die "no such branch: $branch"
wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$wt_branch" = "$branch" ] || die "worktree $wt is on '$wt_branch', not on $branch"

head=$(git -C "$repo" rev-parse "refs/heads/$branch")
repo_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
ahead=$(git -C "$repo" rev-list --count "$base..$branch" 2>/dev/null || echo 0)
behind=$(git -C "$repo" rev-list --count "$branch..$base" 2>/dev/null || echo 0)

# Files the branch changes against where it started, and the user's unsaved files in the repo.
# (--no-renames lists both the old and the new name of a rename; core.quotePath=false keeps non-ASCII names readable.)
g() { git -c core.quotePath=false -C "$repo" "$@"; }
changed=$(g diff --no-renames --name-only "$base...$branch" 2>/dev/null)
unsaved=$( { g diff --name-only; g diff --cached --name-only; g ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
overlap=$(comm -12 <(printf '%s\n' "$changed" | sort -u) <(printf '%s\n' "$unsaved") | sed '/^$/d')
# A file of yours that git does not track (also one that is git-ignored) with the name of a file the branch has would be overwritten.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if { [ -e "$repo/$p" ] || [ -L "$repo/$p" ]; } && ! g ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then overlap=$(printf '%s\n%s\n' "$overlap" "$p"); fi
done <<< "$changed"
overlap=$(printf '%s\n' "$overlap" | sed '/^$/d' | sort -u)
wt_dirty=$(git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//')

if [ -n "$inspect" ]; then
  jq -nc --arg head "$head" --arg base "$base" --arg rb "$repo_branch" --argjson ahead "$ahead" --argjson behind "$behind" \
        --arg overlap "$overlap" --arg dirty "$wt_dirty" \
    '{head:$head, base:$base, repoBranch:$rb, ahead:$ahead, behind:$behind,
      dirtyOverlap:($overlap | split("\n") | map(select(. != ""))), worktreeDirty:($dirty != "")}'
  exit 0
fi

if [ -n "$rebase" ]; then
  if [ -n "$wt_dirty" ]; then echo "ERROR: the agent's worktree has unsaved work; nothing was changed" >&2; printf '%s\n' "$wt_dirty"; exit 6; fi
  if [ "$ahead" -eq 0 ] || [ "$behind" -eq 0 ]; then echo '{"rebased":null}'; exit 0; fi
  if ! rb_out=$(git -C "$wt" -c core.quotePath=false rebase "$base" 2>&1); then
    conflicts=$(git -C "$wt" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null)
    git -C "$wt" rebase --abort >/dev/null 2>&1
    if [ -n "$conflicts" ]; then echo "ERROR: rebasing onto $base conflicts; the rebase was aborted and nothing was changed" >&2; printf '%s\n' "$conflicts"; exit 9; fi
    echo "ERROR: git could not rebase onto $base: $(printf '%s' "$rb_out" | tr '\n' ' ')" >&2; exit 8
  fi
  jq -nc --arg h "$(git -C "$wt" rev-parse HEAD)" '{rebased:$h}'
  exit 0
fi

[ "$repo_branch" = "$base" ] || { echo "ERROR: the repository is on '$repo_branch', not on $base; nothing was changed" >&2; exit 3; }
if [ -n "$wt_dirty" ]; then
  echo "ERROR: the agent's worktree has unsaved work; nothing was changed" >&2; printf '%s\n' "$wt_dirty"; exit 6
fi
[ "$head" = "$expect" ] || { echo "ERROR: the branch is at $head but you looked at $expect (expected); nothing was changed" >&2; exit 7; }
if [ "$ahead" -eq 0 ]; then echo '{"merged":null}'; exit 0; fi
if [ "$behind" -ne 0 ]; then
  echo "ERROR: $base has $behind newer commit(s); this is not a fast-forward, the branch needs a rebase; nothing was changed" >&2; exit 4
fi
if [ -n "$overlap" ]; then
  echo "ERROR: unsaved changes in the repository are in the way; nothing was changed" >&2; printf '%s\n' "$overlap"; exit 5
fi

# The reviewed commit is merged, not wherever the branch is a moment later.
merge_out=$(git -C "$repo" merge --ff-only -q "$expect" 2>&1) || { echo "ERROR: git could not fast-forward $base to the reviewed commit: $(printf '%s' "$merge_out" | tr '\n' ' ')" >&2; exit 8; }
new_head=$(git -C "$repo" rev-parse HEAD)
# Tell the panel's action log (the round timeline reads it); the merge is done, so a log that cannot be written is ignored.
(
  # Under XCTest the real log is never the default: a test must name its own log (N221).
  [ -n "${TENTACL_ACTION_LOG:-}" ] || [ -z "${XCTestConfigurationFilePath:-}" ] || exit 0
  log=${TENTACL_ACTION_LOG:-$HOME/Library/Application Support/Tentacl/actions.log}
  pid=$(jq -r '.id // empty' "$project"); data=$(jq -r '.dataDir // empty' "$project")
  card=""
  [ -d "$data/tasks" ] && card=$(grep -lx "branch: $branch" "$data"/tasks/*.md 2>/dev/null | head -1 | xargs -I{} basename {} .md)
  mkdir -p "$(dirname "$log")" && printf '%s [%s] merged %s %s (script)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${pid// /_}" "${card:-$branch}" "$new_head" >> "$log"
) >/dev/null 2>&1 || true
jq -nc --arg m "$new_head" '{merged:$m}'
