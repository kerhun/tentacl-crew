#!/usr/bin/env bash
# Waits until an agent has finished the work it was just given.
# Usage: wait-agent.sh <pane_id | agent_name> [timeout_seconds=1800]
# Why not the terminal's own `agent wait`: right after a prompt it can match the status from BEFORE the prompt (a stale "done") and
# return at once. This script waits until it has seen the agent "working", then until it is no longer working on two polls in a row.
# A run shorter than one poll is never seen "working"; its completion counter (`completion_seq`) still goes up, which also counts as a run.
# Prints the final status. Exit: 0 finished, 2 timed out, 3 never started working (within the start grace period).
# Env: AGENT_PANEL_POLL_S (default 5), AGENT_PANEL_START_GRACE_S (default 60).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ $# -ge 1 ] || { echo "usage: wait-agent.sh <pane_id> [timeout_seconds]" >&2; exit 2; }
pane=$1; timeout=${2:-1800}
poll=${AGENT_PANEL_POLL_S:-5}; grace=${AGENT_PANEL_START_GRACE_S:-60}
start=$(date +%s); saw_working=0; quiet=0; base_seq=""

# Prints "<status> <completion_seq>" of the agent whose pane id or name is $pane.
status() { bash "$HERE/term.sh" list-agents 2>/dev/null | jq -r --arg p "$pane" '.result.agents[]? | select(.pane_id == $p or .name == $p) | "\(.agent_status) \(.completion_seq // 0)"' | head -1; }

while :; do
  line=$(status); s=${line%% *}; seq=${line#* }; [ "$line" = "$s" ] && seq=""
  now=$(date +%s); elapsed=$((now - start))
  [ -n "$seq" ] && [ -z "$base_seq" ] && base_seq=$seq
  if [ -n "$seq" ] && [ "$seq" -gt "${base_seq:-0}" ] 2>/dev/null; then saw_working=1; fi
  if [ "$s" = "working" ]; then saw_working=1; quiet=0
  elif [ "$saw_working" -eq 1 ]; then
    quiet=$((quiet + 1))
    [ "$quiet" -ge 2 ] && { echo "$s"; exit 0; }
  elif [ "$elapsed" -ge "$grace" ]; then
    echo "agent never started working (last status: ${s:-unknown})"; exit 3
  fi
  [ "$elapsed" -ge "$timeout" ] && { echo "timed out after ${timeout}s (last status: ${s:-unknown})"; exit 2; }
  [ "$poll" -gt 0 ] && sleep "$poll"
done
