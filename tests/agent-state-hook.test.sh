#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
H="$ROOT/scripts/agent-state-hook.sh"; FX="$ROOT/tests/fixtures/hooks"
C=$(mktemp -d); export AGENT_PANEL_CACHE="$C"; trap 'rm -rf "$C"' EXIT
S="$C/dev-1/state.json"
# fire <fixture> [tool]: feeds a fixture to the hook as agent dev-1
fire() { AGENT_PANEL_AGENT=dev-1 AGENT_PANEL_TOOL="${2:-claude}" bash "$H" < "$FX/$1.json"; }
field() { jq -r ".$1" "$S"; }

# no agent variable: nothing happens, exit 0
expect no_agent_exit_0   0 "" env -u AGENT_PANEL_AGENT bash "$H" < "$FX/claude-stop.json"
[ -z "$(ls "$C")" ] && { echo "PASS  no_agent_writes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  no_agent_writes_nothing: $(ls "$C")"; FAIL=$((FAIL+1)); }

# Claude lifecycle
expect session_start_0   0 "" fire claude-session-start
expect start_idle        0 "idle"  field status
expect start_session     0 "c-1"   field session_id
expect start_agent       0 "dev-1" field agent
expect start_tool        0 "claude" field tool
expect start_v           0 "1"     field v
expect start_completion  0 "0"     field completion_seq
expect start_updated_at  0 "true"  jq -r '(.updated_at | type) == "string"' "$S"
fire claude-user-prompt;  expect prompt_working   0 "working" field status
fire claude-pre-tool;     expect pre_working      0 "working" field status
fire claude-permission;   expect permission_blocked 0 "blocked" field status
fire claude-post-tool;    expect post_working     0 "working" field status
fire claude-notify-permission; expect notify_perm_blocked 0 "blocked" field status
fire claude-post-tool
fire claude-notify-elicitation; expect notify_elic_blocked 0 "blocked" field status
fire claude-post-tool
fire claude-notify-idle;  expect notify_idle_ignored 0 "working" field status
fire claude-stop;         expect stop_done        0 "done" field status
expect stop_completion_1  0 "1" field completion_seq
fire claude-user-prompt; fire claude-stop
expect second_stop_completion_2 0 "2" field completion_seq
expect session_kept       0 "c-1" field session_id
expect seq_counts_events  0 "true" jq -r '.seq > 10' "$S"
before=$(field seq); fire claude-pre-tool
expect seq_increases      0 "true" jq -r --argjson b "$before" '.seq > $b' "$S"
[ -z "$(ls "$C/dev-1" | grep -v '^state.json$')" ] && { echo "PASS  no_temp_file_left"; PASS=$((PASS+1)); } || { echo "FAIL  no_temp_file_left: $(ls -a "$C/dev-1")"; FAIL=$((FAIL+1)); }
fire claude-session-end
[ ! -e "$S" ] && { echo "PASS  session_end_removes_file"; PASS=$((PASS+1)); } || { echo "FAIL  session_end_removes_file"; FAIL=$((FAIL+1)); }
expect session_end_twice_0 0 "" fire claude-session-end

# Codex: same events, tool recorded
fire codex-session-start codex; expect codex_start_idle 0 "idle" field status
expect codex_tool 0 "codex" field tool
expect codex_session 0 "x-1" field session_id
fire codex-user-prompt codex;  expect codex_prompt_working 0 "working" field status
fire codex-permission codex;   expect codex_permission_blocked 0 "blocked" field status
fire codex-post-tool codex;    expect codex_post_working 0 "working" field status
fire codex-stop codex;         expect codex_stop_done 0 "done" field status
expect codex_completion_1 0 "1" field completion_seq

# an event before SessionStart still creates the file; unknown events and bad input never fail or change it
rm -f "$S"; fire claude-pre-tool; expect no_start_file_working 0 "working" field status
expect no_start_session 0 "c-1" field session_id
cp "$S" "$C/before"
expect unknown_event_0 0 "" bash -c "echo '{\"hook_event_name\":\"PreCompact\",\"session_id\":\"c-1\"}' | AGENT_PANEL_AGENT=dev-1 bash '$H'"
cmp -s "$S" "$C/before" && { echo "PASS  unknown_event_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  unknown_event_unchanged"; FAIL=$((FAIL+1)); }
expect garbage_0 0 "" bash -c "echo 'not json' | AGENT_PANEL_AGENT=dev-1 bash '$H'"
expect empty_0   0 "" bash -c "AGENT_PANEL_AGENT=dev-1 bash '$H' < /dev/null"
cmp -s "$S" "$C/before" && { echo "PASS  garbage_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  garbage_unchanged"; FAIL=$((FAIL+1)); }
# a corrupt state file is replaced, not fatal
echo 'broken' > "$S"; fire claude-stop; expect corrupt_state_replaced 0 "done" field status

# odd agent names never write outside the cache root
expect odd_agent_0 0 "" bash -c "AGENT_PANEL_AGENT='../evil' bash '$H' < '$FX/claude-stop.json'"
[ ! -e "$C/../evil" ] && [ -z "$(ls "$C" | grep -Ev "^(dev-1|before)\$")" ] && { echo "PASS  odd_agent_ignored"; PASS=$((PASS+1)); } || { echo "FAIL  odd_agent_ignored: $(ls "$C")"; FAIL=$((FAIL+1)); }
# an unwritable cache root still exits 0
expect unwritable_root_0 0 "" bash -c "AGENT_PANEL_CACHE=/dev/null/x AGENT_PANEL_AGENT=dev-1 bash '$H' < '$FX/claude-stop.json'"
finish
