#!/usr/bin/env bash
# Closes an agent's terminal workspace (through term.sh). The worktree directory stays unless --remove-worktree is given,
# so work awaiting approval is never deleted by accident.
# Usage: stop-agent.sh <agent> <worktree_path> [--remove-worktree] [--delete-branch] [--expect-branch <name>] [--no-sim]
#   --no-sim: do not look for or delete a simulator (for projects that have none).
#   --delete-branch (only together with --remove-worktree) also deletes the agent's branch, but only when git considers it
#     fully merged (a fresh branch with no commits of its own); a branch with work on it is kept and a WARNING is printed.
#   --expect-branch <name>: refuse (exit 3, nothing changed) unless the worktree is on that branch, so a path that now
#     belongs to another agent is never touched.
# Exit: 0 done; 1 something could not be done (the cleanup that was possible has still been done); 2 usage; 3 branch mismatch;
#   4 the terminal no longer knew the workspace but everything else was removed (callers treat it as success).
set -u
[ $# -ge 2 ] || { echo "usage: stop-agent.sh <agent> <worktree_path> [--remove-worktree] [--delete-branch] [--expect-branch <name>]" >&2; exit 2; }
agent=$1; wpath=$2; shift 2
[ -n "$agent" ] && [ -n "$wpath" ] || { echo "ERROR: <agent> and <worktree_path> must not be empty" >&2; exit 2; }
remove=""; delete_branch=""; expect=""; nosim=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-worktree) remove=1 ;;
    --delete-branch) delete_branch=1 ;;
    --no-sim) nosim=1 ;;
    --expect-branch) [ $# -ge 2 ] || { echo "ERROR: --expect-branch needs a branch name" >&2; exit 2; }; [ -n "$2" ] || { echo "ERROR: --expect-branch needs a branch name" >&2; exit 2; }; expect=$2; shift ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
HERE="$(cd "$(dirname "$0")" && pwd)"; SIM=${AGENT_PANEL_SIM_SCRIPT:-$HERE/sim-for-agent.sh}

# Remember the branch and the repository before the worktree disappears.
branch=""; repo=""
if [ -d "$wpath" ]; then
  # Only the root of a linked worktree qualifies: not the main checkout, not a subfolder, not a plain folder.
  top=$(git -C "$wpath" rev-parse --show-toplevel 2>/dev/null)
  gd=$(git -C "$wpath" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  gc=$(git -C "$wpath" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  here=$(cd -P "$wpath" && pwd -P)
  # A plain stop (terminal close only) may point at any folder, e.g. the PM's main checkout.
  if [ -n "$remove$delete_branch$expect" ] && { [ -z "$top" ] || [ "$(cd -P "$top" && pwd -P)" != "$here" ] || [ "$gd" = "$gc" ]; }; then
    echo "ERROR: $wpath is not an agent worktree; nothing was changed" >&2
    exit 3
  fi
  branch=$(git -C "$wpath" rev-parse --abbrev-ref HEAD 2>/dev/null)
  common=$(git -C "$wpath" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common" in */.git) repo=$(dirname "$common") ;; esac
  if [ -n "$expect" ] && [ "$branch" != "$expect" ]; then
    echo "ERROR: worktree $wpath is on branch '$branch', expected $expect; nothing was changed" >&2
    exit 3
  fi
fi

rc=0; nows=""
list=$(bash "$HERE/term.sh" list-workspaces 2>&1)
# The workspace was opened with the agent's name as its label; the folder it runs in is the fallback.
ws=$(printf '%s' "$list" | jq -r --arg a "$agent" --arg p "$wpath" '[.result.workspaces[]? | select(.label == $a)] + [.result.workspaces[]? | select(.cwd == $p)] | .[0].id // empty' 2>/dev/null)
if [ -z "$ws" ]; then
  echo "ERROR: no terminal workspace for worktree $wpath (agent $agent)" >&2
  nows=1
else
  out=$(bash "$HERE/term.sh" close "$ws" 2>&1)
  printf '%s' "$out" | jq -e 'has("error") | not' >/dev/null 2>&1 || { echo "ERROR: $(printf '%s' "$out" | jq -r '.error.message // "unknown"' 2>/dev/null)" >&2; rc=1; }
fi

if [ -n "$remove" ]; then
  # a sleeping agent's marker (N261) goes with its worktree; the plain stop that Sleep itself uses keeps it
  rm -f "${AGENT_PANEL_CACHE:-$HOME/.cache/agent-panel}/sleeping/$agent.json"
  # The worktree is removed with git (the terminal never owns it), then the rest of the cleanup.
  if [ -d "$wpath" ] && [ -n "$repo" ]; then
    git -C "$repo" worktree remove --force "$wpath" >/dev/null 2>&1 || { echo "ERROR: could not remove worktree $wpath" >&2; rc=1; }
  fi
  # --no-sim: the project has no simulator, and an agent of another project may have the same name and a simulator of its own.
  if [ -z "$nosim" ]; then bash "$SIM" --remove "$agent" >/dev/null 2>&1; fi
  if [ -n "$delete_branch" ] && [ -n "$branch" ] && [ -n "$repo" ] && [ "$branch" != "HEAD" ]; then
    if [ "$branch" = "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" ]; then
      echo "WARNING: branch $branch kept (it is checked out in the main checkout)" >&2
    else git -C "$repo" branch -d "$branch" >/dev/null 2>&1 || echo "WARNING: branch $branch kept (it has commits that are not merged)" >&2
    fi
  fi
fi
[ "$rc" -eq 0 ] && [ -n "$nows" ] && rc=4
exit "$rc"
