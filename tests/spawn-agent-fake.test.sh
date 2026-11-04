#!/usr/bin/env bash
# spawn-agent / stop-agent against a fake terminal: deterministic, no real agents or simulators.
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/spawn-agent.sh"; X="$ROOT/scripts/stop-agent.sh"; F="$ROOT/tests/fixtures/config"
T=$(mktemp -d /tmp/agent-panel-fake.XXXXXX); trap 'rm -rf "$T"' EXIT
export FAKE_TERM_STATE="$T/term" AGENT_PANEL_STATE="$T/state" AGENT_PANEL_CLAUDE_HOME="$ROOT/tests/fixtures/claude-home"
export AGENT_PANEL_SIM_SCRIPT="$ROOT/tests/fixtures/fake-sim.sh" AGENT_PANEL_TERM_SCRIPT="$ROOT/tests/fixtures/fake-term/term-fake.sh"
calls() { cat "$FAKE_TERM_STATE/calls.log" 2>/dev/null; }
reset() { rm -rf "$FAKE_TERM_STATE" "$T/repo"; mkdir -p "$T/repo"; git init -q -b main "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  jq --arg r "$T/repo" '.repoPath=$r' "$F/valid_project.json" > "$T/project.json"; }
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }

# --- rollback after a failed start (I-6, I-7, C-1) ---
reset
out=$(FAKE_START=fail bash "$S" "$T/project.json" "$F/valid_role.json" t1 test/t1 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "agent start failed" && ok failed_start_reports_rollback || no failed_start_reports_rollback "rc=$rc out=$out"
[ ! -d "$T/repo/.agent-worktrees/test-t1" ] && ok failed_start_removes_worktree_dir || no failed_start_removes_worktree_dir "dir still there"
[ -z "$(git -C "$T/repo" branch --list test/t1)" ] && ok failed_start_removes_new_branch || no failed_start_removes_new_branch "branch still there"
calls | grep -q "^CLOSED:dev-t1-demo" && ok rollback_closes_agent_workspace || no rollback_closes_agent_workspace "$(calls | grep CLOSED)"
[ -z "$(git -C "$T/repo" worktree list --porcelain | grep agent-worktrees)" ] && ok rollback_prunes_git_worktree || no rollback_prunes_git_worktree "$(git -C "$T/repo" worktree list)"
calls | grep -q "^CLOSED:other" && no rollback_leaves_existing_workspaces "another workspace was closed" || ok rollback_leaves_existing_workspaces

# --- an existing branch is never touched (C-1) ---
reset
git -C "$T/repo" checkout -q -b feat/keep; echo work > "$T/repo/keep.txt"; git -C "$T/repo" add keep.txt; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q -m "valuable work"; git -C "$T/repo" checkout -q main
sha=$(git -C "$T/repo" rev-parse feat/keep)
out=$(FAKE_START=fail bash "$S" "$T/project.json" "$F/valid_role.json" t2 feat/keep 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "already exists" && ok existing_branch_refused || no existing_branch_refused "rc=$rc out=$out"
[ "$(git -C "$T/repo" rev-parse feat/keep 2>/dev/null)" = "$sha" ] && ok existing_branch_commits_preserved || no existing_branch_commits_preserved "branch moved or deleted"
calls | grep -q "^open " && no existing_branch_no_workspace "a workspace was opened" || ok existing_branch_no_workspace

# --- success: JSON, simulator wiring, argument boundaries (I-3, I-4) ---
reset
jq '.allowedTools=["Bash(git diff:*)","Read"]' "$F/valid_role.json" > "$T/role.json"; cp "$F/dev.md" "$T/dev.md"
out=$(bash "$S" "$T/project.json" "$T/role.json" t3 test/t3 2>&1); rc=$?
last=$(printf '%s' "$out" | tail -n1)
[ "$rc" -eq 0 ] && printf '%s' "$last" | jq -e '.agent == "dev-t3-demo" and .pane_id == "dev-t3-demo" and .udid == "FAKE-UDID-123" and (.worktree_path | endswith(".agent-worktrees/test-t3"))' >/dev/null 2>&1 && ok success_returns_json_with_udid || no success_returns_json_with_udid "rc=$rc out=$out"
calls | grep -qFx "ARG:Bash(git diff:*)" && ok tool_rule_with_space_is_one_argument || no tool_rule_with_space_is_one_argument "$(calls | grep ARG)"
grep -q "FAKE-UDID-123" "$AGENT_PANEL_STATE/dev-t3-demo/instructions.md" && grep -qi 'never.*booted' "$AGENT_PANEL_STATE/dev-t3-demo/instructions.md" && ok agent_told_its_simulator || no agent_told_its_simulator "instructions: $(cat "$AGENT_PANEL_STATE/dev-t3-demo/instructions.md" 2>&1 | tail -3)"

# --- stop with --remove-worktree also removes the simulator ---
wp=$(printf '%s' "$last" | jq -r .worktree_path)
bash "$X" dev-t3-demo "$wp" --remove-worktree >/dev/null 2>&1
calls | grep -q "^sim --remove dev-t3-demo" && ok stop_removes_agent_simulator || no stop_removes_agent_simulator "$(calls | grep '^sim')"

# --- a path with spaces survives (I-4) ---
reset; mkdir -p "$T/with space"; cp "$F/valid_role.json" "$T/with space/role.json"; cp "$F/dev.md" "$T/with space/dev.md"
bash "$S" "$T/project.json" "$T/with space/role.json" t4 test/t4 >/dev/null 2>&1
grep -q "Test fixture instruction file" "$AGENT_PANEL_STATE/dev-t4-demo/instructions.md" 2>/dev/null && ok instruction_path_with_space_kept || no instruction_path_with_space_kept "instructions: $(cat "$AGENT_PANEL_STATE/dev-t4-demo/instructions.md" 2>&1 | head -2)"
# --- a project without a simulator: no device is created, none is mentioned to the agent ---
reset
jq 'del(.simulator)' "$T/project.json" > "$T/p2.json"; 
out=$(bash "$S" "$T/p2.json" "$F/valid_role.json" t5 test/t5 2>&1); rc=$?
last=$(printf '%s' "$out" | tail -n1)
[ "$rc" -eq 0 ] && printf '%s' "$last" | jq -e '.agent == "dev-t5-demo" and .udid == ""' >/dev/null 2>&1 && ok no_simulator_start_returns_empty_udid || no no_simulator_start_returns_empty_udid "rc=$rc out=$out"
calls | grep -q "^sim " && no no_simulator_none_created "$(calls | grep '^sim')" || ok no_simulator_none_created
grep -qi 'simulator' "$AGENT_PANEL_STATE/dev-t5-demo/instructions.md" && no no_simulator_not_in_instructions "mentioned" || ok no_simulator_not_in_instructions

# --- I6: stopping an agent of a project without a simulator never touches a simulator (another project's agent may share the name) ---
reset
out=$(bash "$S" "$T/p2.json" "$F/valid_role.json" t6 test/t6 2>&1); wp=$(printf '%s' "$out" | tail -n1 | jq -r .worktree_path)
: > "$FAKE_TERM_STATE/calls.log"
bash "$X" dev-t6 "$wp" --remove-worktree --no-sim >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ! calls | grep -q "^sim " && ok stop_no_sim_leaves_simulators_alone || no stop_no_sim_leaves_simulators_alone "rc=$rc $(calls | grep '^sim')"

# --- a long project id is cut to 12 characters (no trailing dash), the role stays first ---
reset
jq '.id="a-very-long-project-id"' "$T/project.json" > "$T/p3.json"
out=$(bash "$S" "$T/p3.json" "$F/valid_role.json" t7 test/t7 2>&1); last=$(printf '%s' "$out" | tail -n1)
printf '%s' "$last" | jq -e '.agent == "dev-t7-a-very-long"' >/dev/null 2>&1 && ok long_project_id_is_cut || no long_project_id_is_cut "$out"

# --- copyFiles: untracked local files (signing settings, .env) are copied into the new worktree ---
reset
mkdir -p "$T/repo/app"; echo "CODE_SIGN_IDENTITY = X" > "$T/repo/app/Signing.local.xcconfig"; echo "KEY=1" > "$T/repo/.env"
jq '.copyFiles=["app/Signing.local.xcconfig",".env","missing.txt"]' "$T/project.json" > "$T/p4.json"
out=$(bash "$S" "$T/p4.json" "$F/valid_role.json" t8 test/t8 2>&1); rc=$?; wp=$(printf '%s' "$out" | tail -n1 | jq -r .worktree_path)
[ "$rc" -eq 0 ] && [ "$(cat "$wp/app/Signing.local.xcconfig" 2>/dev/null)" = "CODE_SIGN_IDENTITY = X" ] && [ "$(cat "$wp/.env" 2>/dev/null)" = "KEY=1" ] && ok copy_files_reach_the_worktree || no copy_files_reach_the_worktree "rc=$rc $out"
printf '%s' "$out" | grep -q "missing.txt" && ok missing_copy_file_is_mentioned || no missing_copy_file_is_mentioned "$out"
# a hostile entry that got past the validator is still never followed outside the repository
reset
echo secret > "$T/outside.txt"; jq '.copyFiles=["../outside.txt"]' "$T/project.json" > "$T/p5.json"
out=$(bash "$S" "$T/p5.json" "$F/valid_role.json" t9 test/t9 2>&1); rc=$?
# the validator refuses the entry before any worktree exists; nothing outside the repository may have been copied anywhere
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "relative file paths inside the repository" && ! find "$T" -name outside.txt -path "*t9*" | grep -q . && ok traversal_entry_not_copied || no traversal_entry_not_copied "rc=$rc $out"
# --- N51: the base is the project's main branch, not the branch the repository happens to be on ---
reset
git -C "$T/repo" checkout -q -b feature-x; echo fx > "$T/repo/fx.txt"; git -C "$T/repo" add fx.txt; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q -m fx
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" b1 test/b1 2>&1); rc=$?; wp=$(printf '%s' "$out" | tail -n1 | jq -r .worktree_path)
[ "$(git -C "$T/repo" rev-parse test/b1)" = "$(git -C "$T/repo" rev-parse main)" ] && ok base_is_main_not_current_branch || no base_is_main_not_current_branch "test/b1 is not on main"
[ ! -e "$wp/fx.txt" ] && ok agent_branch_starts_from_main_commits || no agent_branch_starts_from_main_commits "fx.txt present"
jq '.mainBranch="trunk"' "$T/project.json" > "$T/p6.json"; git -C "$T/repo" branch -q trunk feature-x   # trunk differs from main, so the base can be told apart
out=$(bash "$S" "$T/p6.json" "$F/valid_role.json" b2 test/b2 2>&1)
[ "$(git -C "$T/repo" rev-parse test/b2)" = "$(git -C "$T/repo" rev-parse trunk)" ] && ok base_follows_mainBranch_setting || no base_follows_mainBranch_setting "test/b2 is not on trunk"

# --- N51: a start that dies after the simulator was made removes the simulator and the state folder ---
reset
cp "$F/valid_project.json" "$T/pteam.json"; jq --arg r "$T/repo" '.repoPath=$r' "$F/valid_project.json" > "$T/cfg-p.json"
mkdir -p "$T/badteam"; jq --arg r "$T/repo" '.repoPath=$r' "$F/valid_project.json" > "$T/badteam/project.json"; echo '{"members":[{"role":"dev","reportsTo":"ghost"}]}' > "$T/badteam/team.json"
out=$(bash "$S" "$T/badteam/project.json" "$F/valid_role.json" l1 test/l1 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok bad_team_chart_refused || no bad_team_chart_refused "rc=$rc $out"
calls | grep -q "^sim --remove dev-l1-demo" && ok failed_spawn_removes_simulator || no failed_spawn_removes_simulator "$(calls | grep '^sim')"
[ ! -d "$AGENT_PANEL_STATE/dev-l1-demo" ] && ok failed_spawn_removes_state_folder || no failed_spawn_removes_state_folder "$(ls "$AGENT_PANEL_STATE")"

# --- --no-card: a session in the project folder (the PM): no branch, worktree or simulator ---
reset
out=$(bash "$S" --no-card "$T/project.json" "$F/valid_role.json" 2>&1); rc=$?
last=$(printf '%s' "$out" | tail -n1)
[ "$rc" -eq 0 ] && printf '%s' "$last" | jq -e --arg r "$T/repo" '.agent == "dev-demo" and .pane_id == "dev-demo" and .worktree_path == $r and .udid == ""' >/dev/null 2>&1 && ok nocard_returns_json || no nocard_returns_json "rc=$rc out=$out"
calls | grep -q "^open dev-demo $T/repo" && ok nocard_workspace_in_project_folder || no nocard_workspace_in_project_folder "$(calls | grep workspace)"
calls | grep -q "^sim " && no nocard_no_worktree_or_simulator "$(calls)" || ok nocard_no_worktree_or_simulator
[ -z "$(git -C "$T/repo" branch --list 'task/*')" ] && [ ! -d "$T/repo/.agent-worktrees" ] && ok nocard_creates_no_branch_or_folder || no nocard_creates_no_branch_or_folder "branch or folder made"
reset
out=$(FAKE_START=fail bash "$S" --no-card "$T/project.json" "$F/valid_role.json" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "agent start failed" && calls | grep -q "^CLOSED:dev-demo" && [ ! -d "$AGENT_PANEL_STATE/dev-demo" ] && ok nocard_failed_start_closes_workspace || no nocard_failed_start_closes_workspace "rc=$rc out=$out"
# N280: the PM's key reaches claude through the settings env, only for a session on no card
reset; TENTACL_PM_KEY=k280 bash "$S" --no-card "$T/project.json" "$F/valid_role.json" >/dev/null 2>&1
jq -e '.env.TENTACL_PM_KEY == "k280"' "$AGENT_PANEL_STATE/dev-demo/settings.json" >/dev/null 2>&1 && ok pm_key_in_settings_env || no pm_key_in_settings_env ""
reset; bash "$S" --no-card "$T/project.json" "$F/valid_role.json" >/dev/null 2>&1
grep -q TENTACL_PM_KEY "$AGENT_PANEL_STATE/dev-demo/settings.json" && no no_key_without_env "" || ok no_key_without_env
reset; TENTACL_PM_KEY=k280 bash "$S" "$T/project.json" "$F/valid_role.json" k1 test/k1 >/dev/null 2>&1
grep -rq k280 "$AGENT_PANEL_STATE" && no card_agent_gets_no_key "" || ok card_agent_gets_no_key
# --no-card follows the pm role's tool (N365): a codex pm starts on codex
reset; cp "$F/dev.md" "$T/pm.md"; jq '.model="sonnet" | .effort="medium" | .permissionMode="acceptEdits"' "$F/role_codex_pm.json" > "$T/pm.json"
out=$(bash "$S" --no-card "$T/project.json" "$T/pm.json" 2>&1); rc=$?
[ "$rc" -eq 0 ] && calls | grep -q "^start pm.* codex --" && ok nocard_codex_pm_starts_on_codex || no nocard_codex_pm_starts_on_codex "rc=$rc out=$out calls=$(calls)"
# Codex hooks review screen (N169): a clear error and a rollback, also when start itself times out; a Claude role is never read
cp "$F/dev.md" "$T/cx.md"; jq '.name="cx"' "$F/role_codex_ignored.json" | jq 'del(.advanced)' > "$T/cx.json"
for mode in fail ok; do
  reset; cp "$ROOT/tests/fixtures/agent-screens/codex-hooks-review.txt" "$FAKE_TERM_STATE/screen" 2>/dev/null || { mkdir -p "$FAKE_TERM_STATE"; cp "$ROOT/tests/fixtures/agent-screens/codex-hooks-review.txt" "$FAKE_TERM_STATE/screen"; }
  out=$(FAKE_START=$mode bash "$S" "$T/project.json" "$T/cx.json" h1 test/h1 2>&1); rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Codex asks to review its hooks: open Codex once and trust them" && [ ! -d "$T/repo/.agent-worktrees/test-h1" ] && calls | grep -q "^CLOSED:" && ok codex_hooks_screen_start_$mode || no codex_hooks_screen_start_$mode "rc=$rc out=$out"
done
reset; mkdir -p "$FAKE_TERM_STATE"; cp "$ROOT/tests/fixtures/agent-screens/codex-idle.txt" "$FAKE_TERM_STATE/screen"
out=$(bash "$S" "$T/project.json" "$T/cx.json" h2 test/h2 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok codex_idle_screen_starts || no codex_idle_screen_starts "rc=$rc out=$out"
# N253: a codex role starts with the top-level --no-daemon (the shared app-server daemon may answer "no account"); --print-flags shows it too
calls | sed -n '/^start-args:/,$p' | grep -q '^ARG:--no-daemon$' && ok codex_start_has_no_daemon || no codex_start_has_no_daemon "$(calls)"
[ "$(bash "$S" --print-flags "$T/cx.json" 2>/dev/null | awk '{print $1}')" = "--no-daemon" ] && ok codex_print_flags_has_no_daemon || no codex_print_flags_has_no_daemon "$(bash "$S" --print-flags "$T/cx.json" 2>&1 | head -c 200)"
bash "$S" --print-flags "$F/valid_role.json" 2>&1 | grep -q -- "--no-daemon" && no claude_flags_have_no_no_daemon || ok claude_flags_have_no_no_daemon
reset; mkdir -p "$FAKE_TERM_STATE"; cp "$ROOT/tests/fixtures/agent-screens/codex-hooks-review.txt" "$FAKE_TERM_STATE/screen"
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" h3 test/h3 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! calls | grep -q "^read " && ok claude_role_screen_not_read || no claude_role_screen_not_read "rc=$rc"
out=$(bash "$S" --no-card "$T/project.json" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q usage && ok nocard_needs_project_and_role || no nocard_needs_project_and_role "rc=$rc out=$out"

# --- N154: the worktree is plain git ---
reset
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" g1 test/g1 2>&1); wp=$(printf '%s' "$out" | tail -n1 | jq -r .worktree_path)
git -C "$T/repo" worktree list --porcelain | grep -q "test-g1" && ok worktree_is_a_git_worktree || no worktree_is_a_git_worktree "$(git -C "$T/repo" worktree list)"
calls | grep -q "^open dev-g1-demo $wp" && ok workspace_opened_in_the_worktree || no workspace_opened_in_the_worktree "$(calls | grep 'workspace create')"
bash "$X" dev-g1-demo "$wp" --remove-worktree >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -d "$wp" ] && calls | grep -q "^CLOSED:dev-g1-demo" && ok stop_closes_workspace_and_git_removes_worktree || no stop_closes_workspace_and_git_removes_worktree "rc=$rc"

# --- N250: --resume continues the conversation in the same worktree and branch ---
first_arg() { calls | sed -n '/^start-args:/,$p' | grep '^ARG:' | head -${1:-1} | tr '\n' ' '; }
reset; cp "$F/dev.md" "$T/dev.md"
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" r1 test/r1 2>&1); wp=$(printf '%s' "$out" | tail -n1 | jq -r .worktree_path)
echo keep > "$wp/work.txt"; git -C "$wp" add work.txt; git -C "$wp" -c user.name=t -c user.email=t@t commit -q -m "agent work"; head=$(git -C "$wp" rev-parse HEAD)
echo dirty > "$wp/uncommitted.txt"
bash "$X" dev-r1-demo "$wp" --no-sim >/dev/null 2>&1   # the session ends; the worktree stays (no --remove-worktree)
: > "$FAKE_TERM_STATE/calls.log"
out=$(bash "$S" --resume abc-123 "$T/project.json" "$F/valid_role.json" r1 test/r1 2>&1); rc=$?; last=$(printf '%s' "$out" | tail -n1)
[ "$rc" -eq 0 ] && printf '%s' "$last" | jq -e --arg w "$wp" '.agent == "dev-r1-demo" and .worktree_path == $w' >/dev/null 2>&1 && ok resume_claude_returns_same_agent_and_worktree || no resume_claude_returns_same_agent_and_worktree "rc=$rc out=$out"
[ "$(first_arg 2)" = "ARG:--resume ARG:abc-123 " ] && ok resume_claude_argv_starts_with_resume_id || no resume_claude_argv_starts_with_resume_id "$(first_arg 3)"
calls | grep -qFx "ARG:--permission-mode" && ok resume_claude_keeps_role_flags || no resume_claude_keeps_role_flags "$(calls | grep ARG)"
[ "$(git -C "$wp" rev-parse HEAD)" = "$head" ] && [ -f "$wp/uncommitted.txt" ] && [ -f "$wp/work.txt" ] && ok resume_keeps_worktree_untouched || no resume_keeps_worktree_untouched "head moved or files gone"
calls | grep -q "^open dev-r1-demo $wp" && ok resume_opens_workspace_in_existing_worktree || no resume_opens_workspace_in_existing_worktree "$(calls | grep '^open')"
bash "$X" dev-r1-demo "$wp" --no-sim >/dev/null 2>&1
# a failed resume closes only its workspace: worktree, branch and commits stay
: > "$FAKE_TERM_STATE/calls.log"
out=$(FAKE_START=fail bash "$S" --resume abc-123 "$T/project.json" "$F/valid_role.json" r1 test/r1 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ -d "$wp" ] && [ "$(git -C "$wp" rev-parse HEAD)" = "$head" ] && [ -n "$(git -C "$T/repo" branch --list test/r1)" ] && ok failed_resume_keeps_worktree_and_branch || no failed_resume_keeps_worktree_and_branch "rc=$rc out=$out"
calls | grep -q "^CLOSED:dev-r1-demo" && ok failed_resume_closes_its_workspace || no failed_resume_closes_its_workspace "$(calls | grep CLOSED)"
# nothing to resume into: a missing branch or worktree is refused, and nothing is created
reset
out=$(bash "$S" --resume abc-123 "$T/project.json" "$F/valid_role.json" r2 test/r2 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "cannot resume" && [ ! -d "$T/repo/.agent-worktrees/test-r2" ] && [ -z "$(git -C "$T/repo" branch --list test/r2)" ] && ok resume_without_branch_refused_creates_nothing || no resume_without_branch_refused_creates_nothing "rc=$rc out=$out"
git -C "$T/repo" branch test/r3
out=$(bash "$S" --resume abc-123 "$T/project.json" "$F/valid_role.json" r3 test/r3 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "worktree .* is gone" && [ ! -d "$T/repo/.agent-worktrees/test-r3" ] && ok resume_without_worktree_refused_creates_nothing || no resume_without_worktree_refused_creates_nothing "rc=$rc out=$out"
# a bad session id never reaches the terminal
out=$(bash "$S" --resume '--bad id' "$T/project.json" "$F/valid_role.json" r3 test/r3 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "not a session id" && ok resume_rejects_odd_session_id || no resume_rejects_odd_session_id "rc=$rc out=$out"
# an agent that is still running is not started twice
reset
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" r4 test/r4 2>&1)
out=$(bash "$S" --resume abc-123 "$T/project.json" "$F/valid_role.json" r4 test/r4 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "already running" && ok resume_refuses_a_running_agent || no resume_refuses_a_running_agent "rc=$rc out=$out"
# Codex: `codex --no-daemon resume <id>` comes first (the option is ignored after resume), then the role's flags
reset; CXR=$(mktemp -d); cp "$F/dev.md" "$CXR/dev.md"; jq 'del(.advanced)' "$F/role_codex_ignored.json" > "$CXR/dev.json"
bash "$S" "$T/project.json" "$CXR/dev.json" r5 test/r5 >/dev/null 2>&1; bash "$X" dev-r5-demo "$T/repo/.agent-worktrees/test-r5" --no-sim >/dev/null 2>&1
: > "$FAKE_TERM_STATE/calls.log"
out=$(bash "$S" --resume 019aaa-bbb "$T/project.json" "$CXR/dev.json" r5 test/r5 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(first_arg 3)" = "ARG:--no-daemon ARG:resume ARG:019aaa-bbb " ] && ok resume_codex_argv_is_no_daemon_resume_then_flags || no resume_codex_argv_is_no_daemon_resume_then_flags "rc=$rc $(first_arg 3) $out"
rm -rf "$CXR"
# the PM (no card): resumed in the project folder
reset; cp "$F/dev.md" "$T/dev.md"; jq '.name="pm"' "$F/valid_role.json" > "$T/pm.json"; cp "$F/dev.md" "$T/pm.md"
: > "$FAKE_TERM_STATE/calls.log"
out=$(bash "$S" --resume pm-sess-9 --no-card "$T/project.json" "$T/pm.json" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(first_arg 2)" = "ARG:--resume ARG:pm-sess-9 " ] && calls | grep -q "^open pm-demo $T/repo" && ok resume_pm_no_card_in_project_folder || no resume_pm_no_card_in_project_folder "rc=$rc $(first_arg 2) $out"
# without --resume nothing changes
reset; : > "$FAKE_TERM_STATE/calls.log"
bash "$S" "$T/project.json" "$F/valid_role.json" r6 test/r6 >/dev/null 2>&1
[ "$(first_arg 1)" = "ARG:--model " ] && ok no_resume_argv_unchanged || no no_resume_argv_unchanged "$(first_arg 2)"

# --- N257: setupCommand runs once in a new worktree, before the agent starts ---
reset
out=$(bash "$S" "$T/project.json" "$F/valid_role.json" s1 test/s1 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$AGENT_PANEL_STATE/dev-s1-demo/setup.log" ] && ok setup_none_changes_nothing || no setup_none_changes_nothing "rc=$rc out=$out"
reset
jq '.setupCommand="pwd > setup-ran.txt; echo hello-setup"' "$T/project.json" > "$T/ps.json"
out=$(bash "$S" "$T/ps.json" "$F/valid_role.json" s2 test/s2 2>&1); rc=$?
wt="$T/repo/.agent-worktrees/test-s2"
[ "$rc" -eq 0 ] && [ -f "$wt/setup-ran.txt" ] && [ "$(cd "$(cat "$wt/setup-ran.txt")" && pwd -P)" = "$(cd "$wt" && pwd -P)" ] && grep -q hello-setup "$AGENT_PANEL_STATE/dev-s2-demo/setup.log" && ok setup_success_runs_in_worktree_and_logs || no setup_success_runs_in_worktree_and_logs "rc=$rc out=$out"
rm -f "$wt/setup-ran.txt"; bash "$X" dev-s2-demo "$wt" --no-sim >/dev/null 2>&1
out=$(bash "$S" --resume abc-123 "$T/ps.json" "$F/valid_role.json" s2 test/s2 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$wt/setup-ran.txt" ] && ok setup_skipped_on_resume || no setup_skipped_on_resume "rc=$rc out=$out"
reset
jq '.setupCommand="echo boom-line; exit 3"' "$T/project.json" > "$T/pf.json"
out=$(bash "$S" "$T/pf.json" "$F/valid_role.json" s3 test/s3 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "Setup failed" && printf '%s' "$out" | grep -q "boom-line" && ok setup_failure_reports_log_tail || no setup_failure_reports_log_tail "rc=$rc out=$out"
[ ! -d "$T/repo/.agent-worktrees/test-s3" ] && [ -z "$(git -C "$T/repo" branch --list test/s3)" ] && [ ! -d "$AGENT_PANEL_STATE/dev-s3-demo" ] && ok setup_failure_cleans_up || no setup_failure_cleans_up "left behind"
calls | grep -q "^open " && no setup_failure_opens_no_workspace "opened" || ok setup_failure_opens_no_workspace
reset
jq '.setupCommand="sleep 30"' "$T/project.json" > "$T/pt.json"
start=$SECONDS; out=$(AGENT_PANEL_SETUP_TIMEOUT=1 bash "$S" "$T/pt.json" "$F/valid_role.json" s4 test/s4 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "timed out" && [ $((SECONDS-start)) -lt 15 ] && [ ! -d "$T/repo/.agent-worktrees/test-s4" ] && ok setup_timeout_fails_and_cleans_up || no setup_timeout_fails_and_cleans_up "rc=$rc t=$((SECONDS-start)) out=$out"

finish
