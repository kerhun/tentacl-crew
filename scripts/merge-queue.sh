#!/usr/bin/env bash
# Merges one task card into the project's main branch, start to finish: wait for its packet, rebase if behind, prepare the packet when it is
# not current, fast-forward, tag stable-N, mark the card done, log, close the agent, optionally ask the panel to start the next cards.
# One merge at a time on the machine (a lock folder next to the build tree), so two callers never merge together.
# Usage: merge-queue.sh [--agent NAME] [--decision TEXT] [--start "ID ID"] [--key KEY] <project.json> <card id>
#   --agent     the agent to close (default: `agent:` of the card)
#   --decision  one line for the card's "## Decision" section
#   --start     card ids to ask the panel to start afterwards (request-start.sh; --key is the PM's session key)
# Result: the last stdout line is "<ID> merged <sha7> stable-N" on success, else "<ID> <reason>".
# Exit: 0 merged; 2 usage / bad input; 10 the card needs a fix (or is not in review/doing); 11 the rebase conflicts; 12 the packet could not be
#       made; 13 merge-task.sh refused (its reason is on the result line); 14 the merge lock was not free in time.
# Env: MERGE_QUEUE_PACKET / MERGE_QUEUE_STOP / MERGE_QUEUE_START override review-packet.sh / stop-agent.sh / request-start.sh (tests);
#      MERGE_QUEUE_LOCK_TIMEOUT (seconds, default 1800) and MERGE_QUEUE_POLL (seconds, default 5): how long to wait for the lock;
#      AGENT_PANEL_BUILD_ROOT: where the lock lives (default ~/.cache/agent-panel/build); TENTACL_ACTION_LOG as in merge-task.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
agent=""; decision=""; start=""; key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) [ $# -ge 2 ] || { echo "ERROR: --agent needs a name" >&2; exit 2; }; agent=$2; shift 2 ;;
    --decision) [ $# -ge 2 ] || { echo "ERROR: --decision needs text" >&2; exit 2; }; decision=$2; shift 2 ;;
    --start) [ $# -ge 2 ] || { echo "ERROR: --start needs card ids" >&2; exit 2; }; start=$2; shift 2 ;;
    --key) [ $# -ge 2 ] || { echo "ERROR: --key needs the session key" >&2; exit 2; }; key=$2; shift 2 ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { echo "usage: merge-queue.sh [--agent NAME] [--decision TEXT] [--start \"ID ID\"] [--key KEY] <project.json> <card id>" >&2; exit 2; }
project=$1; ID=$2
[ -f "$project" ] || { echo "ERROR: project file not found: $project" >&2; exit 2; }
printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' || { echo "ERROR: \"$ID\" is not a plain card id" >&2; exit 2; }
[ -z "$start" ] || printf '%s' "$start" | grep -Eq '^[A-Za-z0-9._ -]+$' || { echo "ERROR: --start takes plain card ids" >&2; exit 2; }

repo=$(jq -r '.repoPath // empty' "$project"); data=$(jq -r '.dataDir // empty' "$project"); base=$(jq -r '.mainBranch // "main"' "$project")
[ -d "$repo" ] && [ -d "$data" ] || { echo "ERROR: repoPath or dataDir of $project is not a folder" >&2; exit 2; }
card="$data/tasks/$ID.md"
[ -f "$card" ] || { echo "ERROR: no card $card" >&2; exit 2; }

# fm_get <key>: first value of a front-matter key.
fm_get() { tr -d '\r' < "$card" | awk -v k="$1" 'NR == 1 && $0 == "---" { infm = 1; next } infm && $0 == "---" { exit } infm && index($0, k ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'; }
# set_status <old-regex> <new>: rewrites only the status line inside the front matter, through a temporary file and a rename.
set_status() {
  local tmp; tmp=$(mktemp "$card.tmp.XXXXXX") || return 1
  awk -v re="$1" -v new="$2" 'NR == 1 && $0 == "---" { infm = 1; print; next } infm && $0 == "---" { infm = 0 }
    infm && !done && $0 ~ "^status:[[:space:]]*(" re ")[[:space:]]*$" { print "status: " new; done = 1; next } { print }' "$card" > "$tmp" \
    && cat "$tmp" > "$card"; local rc=$?; rm -f "$tmp"; return $rc
}
fail() { echo "$ID $1"; exit "$2"; }

branch=$(fm_get branch); [ -n "$branch" ] || branch="task/$(printf '%s' "$ID" | tr 'A-Z' 'a-z')"
printf '%s' "$branch" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$' && case "$branch" in *..*|*//*|*.lock|*/) false ;; esac || { echo "ERROR: branch name not allowed: $branch" >&2; exit 2; }
[ -n "$agent" ] || agent=$(fm_get agent)
wt="$repo/.agent-worktrees/${branch//\//-}"
[ -d "$wt" ] || { echo "ERROR: no worktree $wt" >&2; exit 2; }

# One merge at a time: lock folder with the pid; a lock whose process is gone is taken over (the rename lets only one taker win).
broot="${AGENT_PANEL_BUILD_ROOT:-$HOME/.cache/agent-panel/build}"; lock="$broot/.merge-queue.lock"
mkdir -p "$broot" || { echo "ERROR: could not create $broot" >&2; exit 2; }
waited=0; limit=${MERGE_QUEUE_LOCK_TIMEOUT:-1800}; poll=${MERGE_QUEUE_POLL:-5}
until mkdir "$lock" 2>/dev/null; do
  owner=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then mv "$lock" "$lock.stale.$$" 2>/dev/null && rm -rf "$lock.stale.$$"; continue; fi
  [ "$waited" -lt "$limit" ] || fail "another merge is running (pid ${owner:-?}); waited ${limit}s" 14
  sleep "$poll"; waited=$((waited + poll))
done
echo $$ > "$lock/pid"; trap 'rm -rf "$lock"' EXIT

status=$(fm_get status)
# The panel sets needs-fix with a "commits behind main" note when main moved; the rebase below handles that, so it is not a real fix.
last_note=$(awk '/^## Fix notes/{f=1} f && /^> /{l=$0} END{print l}' "$card")
case "$status" in
  review|doing) ;;
  needs-fix) case "$last_note" in *"behind main"*) ;; *) fail "needs a fix; not merged" 10 ;; esac ;;
  *) fail "is '$status', not in review; not merged" 10 ;;
esac

# Rebase when behind main (the panel's own rebase: clean worktree only, conflict aborts and changes nothing).
inspect=$(bash "$HERE/merge-task.sh" --inspect "$project" "$branch" "$wt" 2>&1) || fail "cannot inspect the branch: $(printf '%s' "$inspect" | tail -1)" 13
if [ "$(printf '%s' "$inspect" | jq -r '(.ahead > 0 and .behind > 0)' 2>/dev/null)" = "true" ]; then
  rb=$(bash "$HERE/merge-task.sh" --rebase "$project" "$branch" "$wt" 2>&1); rc=$?
  case $rc in
    0) ;;
    9) fail "rebase conflict in: $(printf '%s' "$rb" | grep -v '^ERROR' | tr '\n' ' ')" 11 ;;
    *) fail "rebase failed: $(printf '%s' "$rb" | tail -1)" 13 ;;
  esac
fi

# The packet must be for the branch's current head and say Build: passed.
packet_ok() {
  local h; h=$(git -C "$wt" rev-parse HEAD)
  [ "$(grep -E '^Head:' "$card" | tail -1 | sed 's/^Head:[[:space:]]*//' | cut -c1-40)" = "$h" ] && grep -E '^Build:' "$card" | tail -1 | grep -Eq '^Build: (passed|none)'
}
PACKET=${MERGE_QUEUE_PACKET:-$HERE/review-packet.sh}
try=0; why=""
while ! packet_ok && [ $try -lt 3 ]; do
  try=$((try + 1))
  # The panel may have set needs-fix because main moved; the rebase above dealt with that, so the packet starts from review.
  set_status "needs-fix" "review"
  why=$(bash "$PACKET" "$card" "$wt" none "$project" 2>&1 | grep -m1 'EVIDENCE MISSING')
done
packet_ok || fail "packet failed: ${why:-$(grep -E '^Build:' "$card" | tail -1)}" 12

H=$(git -C "$wt" rev-parse HEAD)
mo=$(bash "$HERE/merge-task.sh" "$project" "$branch" "$wt" --expect-head "$H" 2>&1) || fail "merge refused: $(printf '%s\n' "$mo" | grep -v '^[[:space:]]*$' | tail -1)" 13

last=$(git -C "$repo" tag -l 'stable-*' | sed 's/^stable-//' | grep -E '^[0-9]+$' | sort -n | tail -1)
TAG="stable-$(( ${last:-0} + 1 ))"
git -C "$repo" tag "$TAG" "$H" 2>/dev/null || fail "merged ${H:0:7} but could not tag $TAG" 13

set_status "doing|review|needs-fix" "done"
printf '\n## Decision\nMerged %s by PM (%s, %s). %s\n' "$(date +%F)" "${H:0:7}" "$TAG" "$decision" >> "$card"
echo "$(date '+%Y-%m-%d %H:%M') [$(jq -r '.id // "project"' "$project")] done $ID ${H:0:7} (PM)" >> "$data/actions.log"

nosim=(); [ "$(jq -r '.simulator // empty' "$project")" != "" ] || nosim=(--no-sim)
if [ -n "$agent" ]; then
  bash "${MERGE_QUEUE_STOP:-$HERE/stop-agent.sh}" "$agent" "$wt" --remove-worktree --delete-branch --expect-branch "$branch" ${nosim[@]+"${nosim[@]}"} >/dev/null 2>&1 || echo "WARNING: $agent could not be closed completely" >&2
fi

if [ -n "$start" ]; then
  keyargs=(); [ -z "$key" ] || keyargs=(--key "$key")
  # shellcheck disable=SC2086
  bash "${MERGE_QUEUE_START:-$HERE/request-start.sh}" ${keyargs[@]+"${keyargs[@]}"} "$data" "" $start 2>&1 | tail -1
fi
echo "$ID merged ${H:0:7} $TAG"
