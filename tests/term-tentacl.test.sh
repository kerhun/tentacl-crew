#!/usr/bin/env bash
# term.sh with the tentacl backend against the built tentacld on a temp socket (never the real term.sock), a fake claude on PATH, and
# spawn-agent.sh / wait-agent.sh / stop-agent.sh end to end with AGENT_PANEL_BACKEND=tentacl.
# The helper is found via TENTACLD, else in the app's build folders (scripts/app-test.sh builds it); without one the test is skipped.
source "$(dirname "$0")/lib.sh"
TM="$ROOT/scripts/term.sh"
H=${TENTACLD:-}
if [ -z "$H" ]; then
  for c in "$ROOT"/app/build/Build/Products/Debug/tentacld "$ROOT"/app/build/review/Build/Products/Debug/tentacld "$ROOT"/app/build/*/Build/Products/Debug/tentacld; do
    [ -x "$c" ] && { H=$c; break; }
  done
fi
if [ -z "$H" ] || [ ! -x "$H" ]; then echo "SKIP  no tentacld helper built (run scripts/app-test.sh first, or set TENTACLD)"; exit 0; fi
T=$(mktemp -d /tmp/agent-panel-tt.XXXXXX)
cleanup() { pkill -f "tentacld --socket $T/" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
check() { local n=$1 f=$2; shift 2; local o; o=$("$@" 2>&1); printf '%s' "$o" | jq -e "$f" >/dev/null 2>&1 && ok "$n" || no "$n" "$o"; }
waitread() { local n=$1 want=$2 i o; for i in $(seq 1 50); do o=$(bash "$TM" read "$n" 40 2>&1); printf '%s' "$o" | jq -e --arg w "$want" '.result.text | contains($w)' >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "$o"; return 1; }

# a fake claude: reports SessionStart like the hook does, then answers every line it is typed
mkdir -p "$T/bin" "$T/cache" "$T/wt"
cat > "$T/bin/claude" <<'FAKE'
#!/bin/sh
d="$AGENT_PANEL_CACHE/$AGENT_PANEL_AGENT"; mkdir -p "$d"
[ -e "$AGENT_PANEL_CACHE/nostart" ] || echo '{"v":1,"status":"idle","seq":1,"completion_seq":0,"session_id":"s1"}' > "$d/state.json"
echo "fake claude ready: $*"
while IFS= read -r l; do printf 'got:[%s]\n' "$(printf '%s' "$l" | tr -d '\033' )"; done
FAKE
chmod +x "$T/bin/claude"
export TENTACL_SOCKET="$T/s.sock" TENTACLD="$H" AGENT_PANEL_CACHE="$T/cache" AGENT_PANEL_BACKEND=tentacl SHELL=/bin/sh PATH="$T/bin:$PATH"

# nothing answers on the socket: list is empty without starting anything, a verb with no helper is "unreachable"
check list_agents_empty_without_daemon '.result.agents == []' bash "$TM" list-agents
check list_workspaces_empty_without_daemon '.result.workspaces == []' bash "$TM" list-workspaces
[ ! -S "$T/s.sock" ] && ok list_does_not_start_the_daemon || no list_does_not_start_the_daemon "socket exists"
expect unreachable_without_helper 1 '"code":"unreachable"' env TENTACLD="$T/none" HOME="$T/nohome" bash "$TM" ping

# ping starts the helper once and answers
check ping_starts_daemon '.result.backend == "tentacl"' bash "$TM" ping
check ping_again '.result.backend == "tentacl"' bash "$TM" ping

check open_result '.result.workspace.workspace_id == "dev-a" and .result.root_pane.pane_id == "dev-a"' bash "$TM" open dev-a "$T/wt"
expect open_twice_is_an_error 1 '"code":"tentacl_error"' bash "$TM" open dev-a "$T/wt"
expect open_bad_name_exit_2 2 '"code":"usage"' bash "$TM" open "bad name" /x
expect open_missing_folder 1 'no such folder' bash "$TM" open dev-z "$T/nowhere"
check list_workspaces_has_id_label_cwd '.result.workspaces[0] | .id == "dev-a" and .workspace_id == "dev-a" and .label == "dev-a" and (.cwd | endswith("/wt"))' bash "$TM" list-workspaces
check list_agents_unknown_before_state '.result.agents[0] | .name == "dev-a" and .pane_id == "dev-a" and .agent_status == "unknown" and .alive == true and .exit == null' bash "$TM" list-agents

# start: the launch line goes in, the state file ends the wait; claude gets the hook in its --settings file
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$T/settings.json"
check start_claude_waits_for_state '.result.type == "agent_started"' env AGENT_PANEL_START_TIMEOUT_MS=8000 bash "$TM" start dev-a dev-a claude -- --model opus --settings "$T/settings.json" "two words"
jq -e '(.hooks | keys | length == 8) and (.hooks.Stop | length == 2) and (.hooks.SessionStart[0].hooks[0].command | test("agent-state-hook.sh"))' "$T/settings.json" >/dev/null && ok start_adds_hooks_to_settings_and_keeps_own || no start_adds_hooks_to_settings_and_keeps_own "$(cat "$T/settings.json")"
o=$(waitread dev-a "fake claude ready: --model opus --settings $T/settings.json two words") && ok start_passes_each_flag_whole || no start_passes_each_flag_whole "$o"
check list_agents_takes_state_from_file '.result.agents[0] | .agent_status == "idle" and .session_id == "s1" and .state_change_seq == 1 and .alive == true' bash "$TM" list-agents
echo '{"v":1,"status":"done","seq":5,"completion_seq":2,"session_id":"s1"}' > "$T/cache/dev-a/state.json"
check list_agents_done_and_seqs '.result.agents[0] | .agent_status == "done" and .completion_seq == 2 and .state_change_seq == 5' bash "$TM" list-agents

# read, prompt, keys, text
check read_has_text_key '.result.text | type == "string"' bash "$TM" read dev-a 40
expect read_bad_lines_exit_2 2 'lines must be a number' bash "$TM" read dev-a x
check prompt_result '.result.type == "agent_prompted"' bash "$TM" prompt dev-a 'hello "there" çğı'
o=$(waitread dev-a 'got:[[200~hello "there" çğı[201~]') && ok prompt_is_pasted_whole_then_enter || no prompt_is_pasted_whole_then_enter "$o"
check keys_result 'has("result")' bash "$TM" keys dev-a 1 2 enter
o=$(waitread dev-a 'got:[12]') && ok keys_digits_and_enter || no keys_digits_and_enter "$o"
check text_result 'has("result")' bash "$TM" text dev-a 'typed'
bash "$TM" keys dev-a enter >/dev/null
o=$(waitread dev-a 'got:[typed]') && ok text_types_without_enter || no text_types_without_enter "$o"
expect keys_unknown_exit_2 2 'unknown key' bash "$TM" keys dev-a f5
expect read_unknown_session 1 '"code":"tentacl_error"' bash "$TM" read nobody 10

# codex is started without settings handling
bash "$TM" open dev-b "$T/wt" >/dev/null
cp "$T/bin/claude" "$T/bin/codex"
check start_codex '.result.type == "agent_started"' env AGENT_PANEL_START_TIMEOUT_MS=8000 bash "$TM" start dev-b dev-b codex -- -m gpt-5.5
o=$(waitread dev-b "fake claude ready: -m gpt-5.5") && ok start_codex_flags || no start_codex_flags "$o"
bash "$TM" open dev-c "$T/wt" >/dev/null
touch "$T/cache/nostart"
expect start_timeout_without_state 1 '"code":"agent_not_ready"' env AGENT_PANEL_START_TIMEOUT_MS=1500 bash "$TM" start dev-c dev-c codex --
rm -f "$T/cache/nostart"
expect start_unknown_tool_exit_2 2 "unknown tool" bash "$TM" start dev-c dev-c gemini --

# agent state from OSC 7501: a plain shell prints the records the way an agent does (the daemon keeps the last one per session);
# the hook state file is only used when no live record exists
osc() { bash "$TM" text dev-o "printf '\\033]7501;$1\\007'" >/dev/null; bash "$TM" keys dev-o enter >/dev/null; }
oscwait() { local f=$1 i o; for i in $(seq 1 50); do o=$(bash "$TM" list-agents 2>&1); printf '%s' "$o" | jq -e "$f" >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "$o"; return 1; }
oscok() { local n=$1 f=$2 o; o=$(oscwait ".result.agents[] | select(.name == \"dev-o\") | $f") && ok "$n" || no "$n" "$o"; }
bash "$TM" open dev-o "$T/wt" >/dev/null
oscok osc_no_record_no_hook_is_unknown '.agent_status == "unknown"'
mkdir -p "$T/cache/dev-o"; echo '{"v":1,"status":"idle","seq":9,"completion_seq":4,"session_id":"h1"}' > "$T/cache/dev-o/state.json"
oscok osc_no_record_uses_hook_file '.agent_status == "idle" and .completion_seq == 4 and .state_change_seq == 9'
osc 'state=working:app=fake'
oscok osc_working_beats_hook_file '.agent_status == "working" and .completion_seq == 0 and .state_change_seq >= 1'
osc 'state=blocked:app=fake:kind=permission:msg=YXBwcm92ZQ=='
oscok osc_blocked_permission '.agent_status == "blocked"'
osc 'state=working:app=fake'
oscok osc_working_again '.agent_status == "working"'
AGENT_PANEL_POLL_S=1 bash "$ROOT/scripts/wait-agent.sh" dev-o 20 > "$T/wait2.out" 2>&1 & wp=$!
sleep 2.5; osc 'state=done:app=fake'
wait $wp; rc=$?; out=$(head -c 300 "$T/wait2.out")
[ "$rc" -eq 0 ] && ok wait_agent_returns_on_osc_done || no wait_agent_returns_on_osc_done "rc=$rc out=$out"
oscok osc_done_bumps_completion_seq '.agent_status == "done" and .completion_seq == 1'
osc 'state=error:app=fake'
oscok osc_error_reads_as_blocked '.agent_status == "blocked"'
osc 'state=working:app=fake'; osc 'state=idle:app=fake'
oscok osc_idle_after_working_is_a_finished_turn '.agent_status == "idle" and .completion_seq == 2'
osc 'state=clear'
oscok osc_clear_falls_back_to_hook_file '.agent_status == "idle" and .completion_seq == 4 and .state_change_seq == 9'
echo '{"v":1,"status":"working","seq":10,"completion_seq":4,"session_id":"h1"}' > "$T/cache/dev-o/state.json"
oscok osc_hook_fallback_follows_the_file '.agent_status == "working" and .state_change_seq == 10'
# start counts the first 7501 record as ready (no SessionStart state file)
bash "$TM" open dev-p "$T/wt" >/dev/null
cat > "$T/bin/codex" <<'FAKE'
#!/bin/sh
printf '\033]7501;?\007'; sleep 0.3; printf '\033]7501;state=idle:app=fake\007'
while IFS= read -r l; do :; done
FAKE
chmod +x "$T/bin/codex"
check start_ready_on_first_osc_record '.result.type == "agent_started"' env AGENT_PANEL_START_TIMEOUT_MS=8000 bash "$TM" start dev-p dev-p codex --
[ ! -e "$T/cache/dev-p/state.json" ] && ok start_without_state_file || no start_without_state_file "state file exists"

expect focus_activates_tentacl 0 '"type":"ok"' env AGENT_PANEL_OPEN=true bash "$TM" focus dev-a
expect focus_failure 1 '"code":"focus_failed"' env AGENT_PANEL_OPEN=false bash "$TM" focus dev-a

# close ends a live session and removes it and its state
check close_result '.result.type == "ok"' bash "$TM" close dev-a
check closed_session_is_gone '[.result.agents[] | select(.name == "dev-a")] | length == 0' bash "$TM" list-agents
[ ! -e "$T/cache/dev-a" ] && ok close_removes_state_dir || no close_removes_state_dir "still there"
check close_other_still_listed '[.result.agents[] | select(.name == "dev-b")] | length == 1' bash "$TM" list-agents
expect close_unknown_session 1 '"code":"tentacl_error"' bash "$TM" close dev-a

# spawn-agent.sh / wait-agent.sh / stop-agent.sh through the normal scripts
S="$ROOT/scripts/spawn-agent.sh"; X="$ROOT/scripts/stop-agent.sh"; F="$ROOT/tests/fixtures/config"
export FAKE_TERM_STATE="$T/term" AGENT_PANEL_STATE="$T/state" AGENT_PANEL_CLAUDE_HOME="$ROOT/tests/fixtures/claude-home" AGENT_PANEL_SIM_SCRIPT="$ROOT/tests/fixtures/fake-sim.sh"
mkdir -p "$T/repo"; git init -q -b main "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
jq --arg r "$T/repo" '.repoPath=$r' "$F/valid_project.json" > "$T/project.json"
out=$(AGENT_PANEL_START_TIMEOUT_MS=15000 bash "$S" "$T/project.json" "$F/valid_role.json" t1 test/t1 2>&1); rc=$?
last=$(printf '%s' "$out" | tail -n1); agent=$(printf '%s' "$last" | jq -r '.agent // empty' 2>/dev/null)
[ "$rc" -eq 0 ] && [ -n "$agent" ] && printf '%s' "$last" | jq -e '.pane_id == .agent and (.worktree_path | endswith(".agent-worktrees/test-t1"))' >/dev/null 2>&1 && ok spawn_agent_runs_through_tentacl || no spawn_agent_runs_through_tentacl "rc=$rc out=$out"
if [ -n "$agent" ]; then
  o=$(waitread "$agent" "fake claude ready") && ok spawned_agent_is_running_fake_claude || no spawned_agent_is_running_fake_claude "$o"
  check spawned_agent_listed '[.result.agents[] | select(.name == "'"$agent"'" and .agent_status == "idle")] | length == 1' bash "$TM" list-agents
  bash "$TM" prompt "$agent" "do it" >/dev/null
  o=$(waitread "$agent" 'got:[[200~do it[201~]') && ok spawned_agent_takes_a_prompt || no spawned_agent_takes_a_prompt "$o"
  wt=$(printf '%s' "$last" | jq -r .worktree_path)
  AGENT_PANEL_POLL_S=1 bash "$ROOT/scripts/wait-agent.sh" "$agent" 20 > "$T/wait.out" 2>&1 & wp=$!
  sleep 2.5; echo '{"v":1,"status":"done","seq":3,"completion_seq":1,"session_id":"s1"}' > "$T/cache/$agent/state.json"
  wait $wp; rc=$?; out=$(head -c 300 "$T/wait.out")
  [ "$rc" -eq 0 ] && ok wait_agent_sees_the_finished_run || no wait_agent_sees_the_finished_run "rc=$rc out=$out"
  out=$(bash "$X" "$agent" "$wt" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok stop_agent_through_tentacl || no stop_agent_through_tentacl "rc=$rc out=$out"
  check stopped_agent_gone '[.result.agents[] | select(.name == "'"$agent"'")] | length == 0' bash "$TM" list-agents
  # N261: a sleeping agent (marker the app wrote, worktree kept) shows as sleeping; a prompt wakes it in the same session first
  mkdir -p "$T/cache/sleeping"
  jq -nc --arg a "$agent" --arg p "$T/project.json" --arg r "$F/valid_role.json" '{agent:$a, project:"t", card:"t1", cardPath:"/x/t1.md", branch:"test/t1", session:"s1", source:$p, role:$r, since:"2026-01-01T00:00:00Z"}' > "$T/cache/sleeping/$agent.json"
  check sleeping_agent_listed '[.result.agents[] | select(.name == "'"$agent"'" and .agent_status == "sleeping" and .alive == false and .session_id == "s1")] | length == 1' bash "$TM" list-agents
  out=$(AGENT_PANEL_START_TIMEOUT_MS=15000 bash "$TM" prompt "$agent" "wake up" 2>&1)
  printf '%s' "$out" | jq -e '.result.type == "agent_prompted"' >/dev/null 2>&1 && ok prompt_wakes_a_sleeping_agent || no prompt_wakes_a_sleeping_agent "$out"
  o=$(waitread "$agent" '--resume s1') && ok woken_agent_resumes_the_session || no woken_agent_resumes_the_session "$o"
  o=$(waitread "$agent" 'got:[[200~wake up[201~]') && ok woken_agent_gets_the_prompt || no woken_agent_gets_the_prompt "$o"
  [ ! -e "$T/cache/sleeping/$agent.json" ] && ok wake_removes_the_marker || no wake_removes_the_marker "marker still there"
  check woken_agent_listed_once '[.result.agents[] | select(.name == "'"$agent"'" and .alive == true and .agent_status != "sleeping")] | length == 1' bash "$TM" list-agents
  bash "$X" "$agent" "$wt" >/dev/null 2>&1
  # stale markers: the plain stop (what Sleep uses) keeps the marker, removing the worktree takes it along
  mk() { jq -nc --arg a "$1" --arg w "$2" --arg p "$T/project.json" --arg r "$F/valid_role.json" '{agent:$a, project:"t", card:"t1", cardPath:"/x/t1.md", branch:"test/t1", session:"s1", source:$p, role:$r, since:"x", worktree:$w}' > "$T/cache/sleeping/$1.json"; }
  mk "$agent" "$wt"; bash "$X" "$agent" "$wt" >/dev/null 2>&1
  [ -e "$T/cache/sleeping/$agent.json" ] && ok plain_stop_keeps_the_sleep_marker || no plain_stop_keeps_the_sleep_marker "marker gone"
  bash "$X" "$agent" "$wt" --remove-worktree >/dev/null 2>&1
  [ ! -e "$T/cache/sleeping/$agent.json" ] && ok removing_the_worktree_removes_the_sleep_marker || no removing_the_worktree_removes_the_sleep_marker "marker still there"
  mk ghost "$T/nowhere"
  check list_agents_skips_a_marker_whose_worktree_is_gone '[.result.agents[] | select(.name == "ghost")] | length == 0' bash "$TM" list-agents
  [ ! -e "$T/cache/sleeping/ghost.json" ] && ok list_agents_deletes_that_marker || no list_agents_deletes_that_marker "marker still there"
  mk ghost2 "$T/nowhere"
  expect prompt_to_a_ghost_does_not_wake 1 '"code":"wake_failed"' bash "$TM" prompt ghost2 "hi"
  [ ! -e "$T/cache/sleeping/ghost2.json" ] && ok prompt_deletes_the_ghost_marker || no prompt_deletes_the_ghost_marker "marker still there"
fi
finish
