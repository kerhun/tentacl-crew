#!/usr/bin/env bash
# stop-agent --delete-branch against a fake terminal: a fresh branch goes with its worktree, a branch with commits stays.
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/spawn-agent.sh"; X="$ROOT/scripts/stop-agent.sh"; F="$ROOT/tests/fixtures/config"
T=$(mktemp -d /tmp/agent-panel-stop.XXXXXX); trap 'rm -rf "$T"' EXIT
export FAKE_TERM_STATE="$T/term" AGENT_PANEL_STATE="$T/state" AGENT_PANEL_CLAUDE_HOME="$ROOT/tests/fixtures/claude-home"
export AGENT_PANEL_SIM_SCRIPT="$ROOT/tests/fixtures/fake-sim.sh" AGENT_PANEL_TERM_SCRIPT="$ROOT/tests/fixtures/fake-term/term-fake.sh"
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }

spawn() { # <task> <branch> -> prints the worktree path
  rm -rf "$FAKE_TERM_STATE" "$T/repo"; mkdir -p "$T/repo"; git init -q -b main "$T/repo"; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  jq --arg r "$T/repo" '.repoPath=$r' "$F/valid_project.json" > "$T/project.json"
  bash "$S" "$T/project.json" "$F/valid_role.json" "$1" "$2" 2>/dev/null | tail -n1 | jq -r .worktree_path
}

wp=$(spawn t1 test/t1)
expect delete_branch_with_worktree_exits_0 0 "" bash "$X" dev-t1 "$wp" --remove-worktree --delete-branch
[ -z "$(git -C "$T/repo" branch --list test/t1)" ] && ok fresh_branch_is_deleted || no fresh_branch_is_deleted "branch test/t1 still exists"
[ ! -d "$wp" ] && ok worktree_is_removed || no worktree_is_removed "dir still there"

wp=$(spawn t2 test/t2)
echo work > "$wp/work.txt"; git -C "$wp" add work.txt; git -C "$wp" -c user.name=t -c user.email=t@t commit -q -m "valuable work"
out=$(bash "$X" dev-t2 "$wp" --remove-worktree --delete-branch 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "WARNING: branch test/t2 kept" && ok branch_with_commits_is_kept_with_warning || no branch_with_commits_is_kept_with_warning "rc=$rc out=$out"
[ -n "$(git -C "$T/repo" branch --list test/t2)" ] && ok commits_survive || no commits_survive "branch deleted"

wp=$(spawn t3 test/t3)
bash "$X" dev-t3 "$wp" --delete-branch >/dev/null 2>&1
[ -n "$(git -C "$T/repo" branch --list test/t3)" ] && [ -d "$wp" ] && ok delete_branch_alone_does_nothing || no delete_branch_alone_does_nothing "branch or worktree vanished"

wp=$(spawn t4 test/t4)
expect flag_order_does_not_matter 0 "" bash "$X" dev-t4 "$wp" --delete-branch --remove-worktree
[ -z "$(git -C "$T/repo" branch --list test/t4)" ] && ok flags_in_any_order || no flags_in_any_order "branch still exists"

# --- I3: never touch a worktree that is on another branch than the one the caller expects ---
wp=$(spawn t5 test/t5)
out=$(bash "$X" dev-t5 "$wp" --remove-worktree --delete-branch --expect-branch some/other-branch 2>&1); rc=$?
[ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "expected some/other-branch" && ok expect_branch_mismatch_refused || no expect_branch_mismatch_refused "rc=$rc out=$out"
[ -d "$wp" ] && [ -n "$(git -C "$T/repo" branch --list test/t5)" ] && ok mismatch_changes_nothing || no mismatch_changes_nothing "worktree or branch vanished"
expect expect_branch_match_proceeds 0 "" bash "$X" dev-t5 "$wp" --remove-worktree --delete-branch --expect-branch test/t5
[ ! -d "$wp" ] && [ -z "$(git -C "$T/repo" branch --list test/t5)" ] && ok match_removes_both || no match_removes_both "left something behind"

# --- I1/N52: the terminal no longer knows the workspace; the cleanup still happens and exit 4 says "everything else was removed" ---
wp=$(spawn t6 test/t6)
rm -f "$FAKE_TERM_STATE/sessions"
: > "$FAKE_TERM_STATE/calls.log"
out=$(bash "$X" dev-t6 "$wp" --remove-worktree --delete-branch --expect-branch test/t6 2>&1); rc=$?
[ "$rc" -eq 4 ] && printf '%s' "$out" | grep -q "no terminal workspace" && ok missing_workspace_exits_4_when_the_rest_is_done || no missing_workspace_exits_4_when_the_rest_is_done "rc=$rc out=$out"
[ ! -d "$wp" ] && ok missing_workspace_still_removes_worktree || no missing_workspace_still_removes_worktree "dir still there"
[ -z "$(git -C "$T/repo" branch --list test/t6)" ] && ok missing_workspace_still_deletes_fresh_branch || no missing_workspace_still_deletes_fresh_branch "branch still there"
grep -q "^sim --remove dev-t6" "$FAKE_TERM_STATE/calls.log" && ok missing_workspace_still_removes_simulator || no missing_workspace_still_removes_simulator "$(cat "$FAKE_TERM_STATE/calls.log")"

# --- N154: stop finds the workspace by its label (the agent name) ---
wp=$(spawn t7 test/t7)
bash "$ROOT/scripts/term.sh" list-workspaces | jq -e '.result.workspaces[] | select(.label == "dev-t7-demo") | .id == "dev-t7-demo"' >/dev/null 2>&1 && ok plain_workspace_has_the_agent_label || no plain_workspace_has_the_agent_label "$(bash "$ROOT/scripts/term.sh" list-workspaces)"
: > "$FAKE_TERM_STATE/calls.log"
bash "$X" dev-t7-demo "$wp" --remove-worktree >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "CLOSED:dev-t7-demo" "$FAKE_TERM_STATE/calls.log" && ok stop_finds_workspace_by_label || no stop_finds_workspace_by_label "rc=$rc $(cat "$FAKE_TERM_STATE/calls.log")"
# a different agent name falls back on the folder the workspace runs in
wp=$(spawn t8 test/t8)
: > "$FAKE_TERM_STATE/calls.log"
bash "$X" some-other-name "$wp" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "CLOSED:dev-t8-demo" "$FAKE_TERM_STATE/calls.log" && ok stop_falls_back_on_cwd || no stop_falls_back_on_cwd "rc=$rc $(cat "$FAKE_TERM_STATE/calls.log")"
# --- N295: refuse a wrong path or an empty value before anything is touched ---
wp=$(spawn t9 test/t9)
: > "$FAKE_TERM_STATE/calls.log"
bash "$X" dev-t9 "$wp" --remove-worktree --delete-branch --expect-branch "" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ -d "$wp" ] && [ -n "$(git -C "$T/repo" branch --list test/t9)" ] && ! grep -q CLOSED "$FAKE_TERM_STATE/calls.log" && ok empty_expect_branch_refused || no empty_expect_branch_refused "rc=$rc"
bash "$X" "" "$wp" >/dev/null 2>&1; [ $? -eq 2 ] && ok empty_agent_refused || no empty_agent_refused "rc!=2"
mkdir -p "$T/repo/.agent-worktrees/x" "$wp/sub"
for p in "$T/repo/.agent-worktrees/x" "$T/repo" "$wp/sub" "$T/repo/.agent-worktrees/"; do
  : > "$FAKE_TERM_STATE/calls.log"
  out=$(bash "$X" dev-t9 "$p" --remove-worktree --delete-branch --expect-branch test/t9 2>&1); rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "is not an agent worktree" && [ -d "$wp" ] && [ -d "$T/repo/.git" ] && ! grep -q CLOSED "$FAKE_TERM_STATE/calls.log" && ok "wrong_path_refused_${p##*/}" || no "wrong_path_refused_${p##*/}" "rc=$rc out=$out"
done
: > "$FAKE_TERM_STATE/calls.log"
bash "$X" dev-t9-demo "$T/repo" --no-sim >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; } && grep -q CLOSED "$FAKE_TERM_STATE/calls.log" && [ -d "$T/repo/.git" ] && ok plain_stop_on_main_checkout_closes_terminal || no plain_stop_on_main_checkout_closes_terminal "rc=$rc"
[ -n "$(git -C "$T/repo" branch --list main)" ] && ok main_branch_survives || no main_branch_survives "gone"
bash "$X" dev-t9 "$wp" --remove-worktree --delete-branch --expect-branch test/t9 >/dev/null 2>&1; [ $? -eq 4 ] && [ ! -d "$wp" ] && ok linked_worktree_still_removed || no linked_worktree_still_removed "not removed"
bash "$X" dev-gone "$T/nonexistent" >/dev/null 2>&1; [ $? -eq 4 ] && ok missing_path_unchanged || no missing_path_unchanged "rc!=4"

finish
