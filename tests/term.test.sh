#!/usr/bin/env bash
# term.sh: dispatch to the one terminal script, a test double through AGENT_PANEL_TERM_SCRIPT, the errors. (term-tentacl.sh itself is
# covered against the built tentacld in term-tentacl.test.sh.)
source "$(dirname "$0")/lib.sh"
TM="$ROOT/scripts/term.sh"
T=$(mktemp -d /tmp/agent-panel-term.XXXXXX); trap 'rm -rf "$T"' EXIT
export FAKE_TERM_STATE="$T/term" AGENT_PANEL_TERM_SCRIPT="$ROOT/tests/fixtures/fake-term/term-fake.sh"
calls() { cat "$FAKE_TERM_STATE/calls.log" 2>/dev/null; }
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
# check <name> <jq-filter> <command...>: the one-line answer satisfies the filter
check() { local n=$1 f=$2; shift 2; local o; o=$("$@" 2>&1); printf '%s' "$o" | jq -e "$f" >/dev/null 2>&1 && ok "$n" || no "$n" "$o"; }

check ping_goes_to_the_script '.result.backend == "fake"' bash "$TM" ping
check open_result '.result.workspace.workspace_id == "agent-x" and .result.root_pane.pane_id == "agent-x"' bash "$TM" open agent-x /some/folder
check list_agents_result '.result.agents[0] | .pane_id == "agent-x" and .name == "agent-x"' bash "$TM" list-agents
check list_workspaces_result '.result.workspaces[0] | .id == "agent-x" and .label == "agent-x" and .cwd == "/some/folder"' bash "$TM" list-workspaces
check close_result 'has("result")' bash "$TM" close agent-x
calls | grep -q "^open agent-x /some/folder" && ok open_passes_name_and_cwd || no open_passes_name_and_cwd "$(calls)"
check start_keeps_each_flag_one_argument 'has("result")' bash "$TM" start my-agent my-agent codex -- -m gpt "two words"
calls | grep -qFx "ARG:two words" && calls | grep -qFx "ARG:-m" && ok start_arguments_arrive_intact || no start_arguments_arrive_intact "$(calls)"
check errors_come_through '.error.code == "agent_not_ready"' env FAKE_START=fail bash "$TM" start my-agent my-agent claude --
expect error_exits_1 1 "agent_not_ready" env FAKE_START=fail bash "$TM" start my-agent my-agent claude --

# the old backend switch is gone: the daemon script answers whatever AGENT_PANEL_BACKEND says
expect backend_variable_is_ignored 1 '"code":"unreachable"' env -u AGENT_PANEL_TERM_SCRIPT AGENT_PANEL_BACKEND=other TENTACL_SOCKET="$T/none.sock" TENTACLD="$T/none" bash "$TM" ping

# misuse is a JSON error with exit 2
expect no_command_exit_2 2 '"code":"usage"' bash "$TM"
expect unknown_command_exit_2 2 "unknown command" bash "$TM" frobnicate
expect missing_script_is_an_error 2 '"code":"unreachable"' env AGENT_PANEL_TERM_SCRIPT="$T/nope.sh" bash "$TM" ping

# the daemon does not answer and cannot be started: an error, not a crash
expect unreachable_daemon_exits_1 1 '"code":"unreachable"' env -u AGENT_PANEL_TERM_SCRIPT TENTACL_SOCKET="$T/none.sock" TENTACLD="$T/none" bash "$TM" ping
check unreachable_daemon_lists_nothing '.result.agents == []' env -u AGENT_PANEL_TERM_SCRIPT TENTACL_SOCKET="$T/none.sock" TENTACLD="$T/none" bash "$TM" list-agents
finish
