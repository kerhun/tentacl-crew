#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
W="$ROOT/scripts/wait-agent.sh"
T=$(mktemp -d /tmp/agent-panel-wait.XXXXXX); trap 'rm -rf "$T"' EXIT
export FAKE_TERM_STATE="$T" AGENT_PANEL_TERM_SCRIPT="$ROOT/tests/fixtures/fake-term/term-fake.sh" AGENT_PANEL_POLL_S=0 AGENT_PANEL_START_GRACE_S=0
printf 'dev-t1\t/wt\n' > "$T/sessions"
seq() { printf '%s\n' "$@" > "$T/agent_seq"; : > "$T/calls.log"; }

# A stale "done" from before the prompt must not end the wait.
seq done working working done done
expect stale_done_is_ignored_0        0 "done"   env AGENT_PANEL_START_GRACE_S=5 bash "$W" "dev-t1" 30
polls=$(grep -c "^list-agents" "$T/calls.log")
[ "$polls" -ge 5 ] && { echo "PASS  waited_for_the_whole_run"; PASS=$((PASS+1)); } || { echo "FAIL  waited_for_the_whole_run: only $polls polls"; FAIL=$((FAIL+1)); }

seq idle idle idle
expect never_working_exit_3           3 "never started" bash "$W" "dev-t1" 30
seq working
expect still_working_times_out_2      2 "timed out"     env AGENT_PANEL_POLL_S=1 bash "$W" "dev-t1" 2
# A run shorter than one poll is never seen "working", but its completion counter went up: that counts as a finished run.
seq idle idle idle idle idle; printf '%s\n' 5 5 6 6 6 > "$T/cseq"
expect fast_run_seen_by_completion_counter_0 0 "idle" env AGENT_PANEL_START_GRACE_S=5 bash "$W" "dev-t1" 30
rm -f "$T/cseq"
expect usage_error_2                  2 "usage"         bash "$W"
finish
