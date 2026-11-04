#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
R="$ROOT/scripts/review-packet.sh"; F="$ROOT/tests/fixtures/config"
T=$(mktemp -d /tmp/agent-panel-rp.XXXXXX); trap 'rm -rf "$T"' EXIT

# Throwaway repo with a branch that has one extra commit (so there is a diff to summarise).
WT="$T/wt"; git init -q -b main "$WT"; git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WT" checkout -q -b feature; echo hi > "$WT/a.txt"; git -C "$WT" add a.txt; git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m "add a"

AWT="$T/awt"; git -C "$WT" worktree add -q --detach "$AWT" main   # analysis tasks sit on main: no commits of their own
mkproject() { # <build-command> -> project.json path
  jq --arg d "$T/data" --arg r "$WT" --arg b "$1" '.dataDir=$d | .repoPath=$r | .buildCommand=$b' "$F/valid_project.json" > "$T/project.json"; echo "$T/project.json"
}
mkcard() { # <status> -> card path
  mkdir -p "$T/data/tasks"; printf -- '---\nid: T7\nproject: demo\nstatus: %s\nfiles:\n  - a.txt\n---\n# T7\n\n## Goal\nx\n\n## Review packet\n\n## Decision\n' "$1" > "$T/data/tasks/T7.md"; echo "$T/data/tasks/T7.md"
}
status_of() { sed -n 's/^status: //p' "$1" | head -1; }
export AGENT_PANEL_SCREENSHOT_CMD='echo png > "$FILE"'
export AGENT_PANEL_BUILD_ROOT="$T/build"   # the build tree lives here, never in the data folder

card=$(mkcard doing); proj=$(mkproject 'true')
expect build_ok_screenshot_review_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
if [ "$(status_of "$card")" = "review" ] && grep -q "a.txt" "$card" && grep -q "shots/" "$card"; then echo "PASS  card_has_review_status_diff_and_shots"; PASS=$((PASS+1)); else echo "FAIL  card_has_review_status_diff_and_shots: status=$(status_of "$card")"; FAIL=$((FAIL+1)); fi

card=$(mkcard doing); proj=$(mkproject 'false'); rm -rf "$T/data/tasks/T7"
expect build_broken_stays_doing_1 1 "EVIDENCE MISSING: build" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  broken_build_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  broken_build_status_unchanged: $(status_of "$card")"; FAIL=$((FAIL+1)); }

card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
expect no_screenshot_stays_doing_1 1 "EVIDENCE MISSING: screenshot" env AGENT_PANEL_SCREENSHOT_CMD='true' bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  no_screenshot_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  no_screenshot_status_unchanged: $(status_of "$card")"; FAIL=$((FAIL+1)); }

card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1; bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
n=$(grep -c '^## Review packet' "$card")
[ "$n" -eq 1 ] && { echo "PASS  section_not_duplicated_on_rerun_0"; PASS=$((PASS+1)); } || { echo "FAIL  section_not_duplicated_on_rerun_0: $n headings"; FAIL=$((FAIL+1)); }
grep -q '^## Decision' "$card" && { echo "PASS  neighbouring_sections_kept"; PASS=$((PASS+1)); } || { echo "FAIL  neighbouring_sections_kept"; FAIL=$((FAIL+1)); }

# --- $UDID in the build command is replaced by the agent's simulator (I-1) ---
card=$(mkcard doing); proj=$(mkproject "test 'id=\$UDID' = 'id=FAKE-UDID'"); rm -rf "$T/data/tasks/T7"
expect udid_substituted_in_build_command_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"

# --- a screenshot from an earlier round is not evidence (C-2) ---
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
sed -i '' 's/^status: .*/status: needs-fix/' "$card"; sleep 1
expect stale_screenshot_is_not_evidence_1 1 "EVIDENCE MISSING: screenshot" env AGENT_PANEL_SCREENSHOT_CMD='false' bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "needs-fix" ] && { echo "PASS  stale_round_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  stale_round_status_unchanged: $(status_of "$card")"; FAIL=$((FAIL+1)); }
echo png > "$T/data/tasks/T7/shots/after-fix.png"
expect fresh_agent_shot_counts_0 0 "" env AGENT_PANEL_SCREENSHOT_CMD='false' bash "$R" "$card" "$WT" FAKE-UDID "$proj"

# --- a card without the section still gets its packet (I-2) ---
printf -- '---\nid: T7\nproject: demo\nstatus: doing\nfiles:\n  - a.txt\n---\n# T7\n\n## Goal\nx\n' > "$T/data/tasks/T7.md"; rm -rf "$T/data/tasks/T7"
expect card_without_section_0 0 "" bash "$R" "$T/data/tasks/T7.md" "$WT" FAKE-UDID "$proj"
n=$(grep -c '^## Review packet' "$T/data/tasks/T7.md")
[ "$n" -eq 1 ] && grep -q "shots/" "$T/data/tasks/T7.md" && [ "$(status_of "$T/data/tasks/T7.md")" = "review" ] && { echo "PASS  section_appended_with_content"; PASS=$((PASS+1)); } || { echo "FAIL  section_appended_with_content: headings=$n status=$(status_of "$T/data/tasks/T7.md")"; FAIL=$((FAIL+1)); }

# --- a failed build names the failing tests, not the last passed ones (N94) ---
card=$(mkcard doing); rm -rf "$T/data/tasks/T7"
cat > "$T/sample-build.sh" <<'EOS'
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do printf '\tExecuted %s tests, with 0 failures\n' "$i"; done
printf '%s\n' "passed  AgentPanelTests.ZTests.testLast" "failed  AgentPanelTests.PMNoticeTests.testTwoConcurrentRefreshesSendOnce" "Foo.swift:9: error: XCTAssertEqual failed" "Executed 10 tests, with 1 failure" "** TEST FAILED **" "FAIL  some_shell_case: exit 1"
for i in 1 2 3 4 5 6; do echo "passed  AgentPanelTests.WorkspaceOpenerTests.test$i"; done
exit 1
EOS
proj=$(mkproject "bash $T/sample-build.sh")
out=$(bash "$R" "$card" "$WT" FAKE-UDID "$proj" 2>&1)
for needle in "PMNoticeTests.testTwoConcurrentRefreshesSendOnce" "error: XCTAssertEqual" "Executed 10 tests" "TEST FAILED" "FAIL  some_shell_case"; do
  printf '%s' "$out" | grep -qF -- "$needle" && { echo "PASS  failed_build_names: $needle"; PASS=$((PASS+1)); } || { echo "FAIL  failed_build_names: lacks '$needle'"; FAIL=$((FAIL+1)); }
done
printf '%s' "$out" | grep -q "WorkspaceOpenerTests.test" && { echo "FAIL  failed_build_skips_passed_tests"; FAIL=$((FAIL+1)); } || { echo "PASS  failed_build_skips_passed_tests"; PASS=$((PASS+1)); }
# no recognisable line: fall back to the tail
proj=$(mkproject "bash -c 'seq 1 20; exit 1'"); rm -rf "$T/data/tasks/T7"
expect failed_build_without_markers_falls_back_to_tail_1 1 "20" bash "$R" "$card" "$WT" FAKE-UDID "$proj"

# --- identical screenshots are not two pieces of evidence (pilot finding) ---
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"; mkdir -p "$T/data/tasks/T7/shots"
echo same > "$T/data/tasks/T7/shots/widgets.png"; echo same > "$T/data/tasks/T7/shots/lockscreen.png"
expect identical_screenshots_rejected_1 1 "identical" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  identical_screenshots_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  identical_screenshots_status_unchanged"; FAIL=$((FAIL+1)); }
echo different > "$T/data/tasks/T7/shots/lockscreen.png"
expect distinct_screenshots_accepted_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"

# --- analysis tasks: the report is the evidence; nothing may have changed in the worktree ---
mkacard() { mkdir -p "$T/data/tasks"; printf -- '---\nid: T7\nproject: demo\nstatus: doing\nkind: analysis\nfiles:\n  - a.txt\n---\n# T7\n\n## Report\n%s\n\n## Review packet\n\n## Decision\n' "$1" > "$T/data/tasks/T7.md"; }
proj=$(mkproject 'false'); rm -rf "$T/data/tasks/T7"   # a failing build command proves the build is skipped
mkacard "Findings: all good."
expect analysis_with_report_review_0 0 "" bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$proj"
[ "$(status_of "$T/data/tasks/T7.md")" = "review" ] && { echo "PASS  analysis_status_review"; PASS=$((PASS+1)); } || { echo "FAIL  analysis_status_review: $(status_of "$T/data/tasks/T7.md")"; FAIL=$((FAIL+1)); }
mkacard ""
expect analysis_without_report_1 1 "EVIDENCE MISSING: report" bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$proj"
mkacard "Findings."; echo dirty > "$AWT/untracked-change.txt"
expect analysis_that_changed_files_1 1 "EVIDENCE MISSING: analysis task changed" bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$proj"; rm -f "$AWT/untracked-change.txt"
# --- the packet records the branch tip it was built from (Head), so a later commit makes it stale ---
head=$(git -C "$WT" rev-parse HEAD)
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
grep -qx "Head: $head" "$card" && { echo "PASS  packet_records_head"; PASS=$((PASS+1)); } || { echo "FAIL  packet_records_head: $(grep '^Head:' "$card")"; FAIL=$((FAIL+1)); }
proj=$(mkproject 'false'); rm -rf "$T/data/tasks/T7"; mkacard "Findings."
bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$proj" >/dev/null 2>&1
grep -qx "Head: $(git -C "$AWT" rev-parse HEAD)" "$T/data/tasks/T7.md" && { echo "PASS  analysis_packet_records_head"; PASS=$((PASS+1)); } || { echo "FAIL  analysis_packet_records_head"; FAIL=$((FAIL+1)); }

# --- the packet must describe one fixed state of the branch (review finding) ---
reset_wt() { git -C "$WT" reset -q --hard HEAD; git -C "$WT" clean -fdq; }
# uncommitted work in the worktree: the build would test code that the merge will not contain
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"; echo wip > "$WT/wip.txt"
expect uncommitted_work_refused_1 1 "EVIDENCE MISSING: uncommitted" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  uncommitted_work_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  uncommitted_work_status_unchanged"; FAIL=$((FAIL+1)); }
out=$(bash "$R" "$card" "$WT" FAKE-UDID "$proj" 2>&1)
printf '%s' "$out" | grep -q "commit first" && printf '%s' "$out" | grep -q "?? wip.txt" && { echo "PASS  dirty_refusal_lists_files"; PASS=$((PASS+1)); } || { echo "FAIL  dirty_refusal_lists_files: $out"; FAIL=$((FAIL+1)); }
reset_wt
# only project.pbxproj dirty: its own line; with another file: the old line
mkdir -p "$WT/app/X.xcodeproj"; echo a > "$WT/app/X.xcodeproj/project.pbxproj"; git -C "$WT" add -A; git -C "$WT" -c user.name=t -c user.email=t@t commit -qm pbx
echo b > "$WT/app/X.xcodeproj/project.pbxproj"
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
expect pbxproj_only_named_1 1 "EVIDENCE MISSING: project.pbxproj changed but not committed" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
echo wip > "$WT/wip.txt"
card=$(mkcard doing); rm -rf "$T/data/tasks/T7"
expect pbxproj_plus_file_old_line_1 1 "EVIDENCE MISSING: uncommitted work" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
reset_wt
card=$(mkcard doing); rm -rf "$T/data/tasks/T7"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" 2>&1 | grep -q "EVIDENCE MISSING: \(project\|uncommitted\)" && { echo "FAIL  clean_passes_dirty_step"; FAIL=$((FAIL+1)); } || { echo "PASS  clean_passes_dirty_step"; PASS=$((PASS+1)); }
# the card's Report names another Head than the one tested: the packet says so; the same Head: no note
card=$(mkcard doing); rm -rf "$T/data/tasks/T7"; sed -i '' 's/^## Review packet/## Report\nHead: deadbee\n\n## Review packet/' "$card"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
grep -q "NOTE: the card's Report names Head deadbee" "$card" && { echo "PASS  report_head_differs_noted"; PASS=$((PASS+1)); } || { echo "FAIL  report_head_differs_noted"; FAIL=$((FAIL+1)); }
card=$(mkcard doing); rm -rf "$T/data/tasks/T7"; sed -i '' "s/^## Review packet/## Report\nHead: $(git -C "$WT" rev-parse --short HEAD)\n\n## Review packet/" "$card"
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
grep -q "NOTE: the card's Report" "$card" && { echo "FAIL  report_head_same_no_note"; FAIL=$((FAIL+1)); } || { echo "PASS  report_head_same_no_note"; PASS=$((PASS+1)); }
# the agent commits while the build runs: the screenshot cannot belong to the new tip
card=$(mkcard doing); proj=$(mkproject "cd '$WT' && echo y > during.txt && git add during.txt && git -c user.name=t -c user.email=t@t commit -qm during"); rm -rf "$T/data/tasks/T7"
expect commit_during_build_refused_1 1 "EVIDENCE MISSING: the branch changed" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  commit_during_build_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  commit_during_build_status_unchanged"; FAIL=$((FAIL+1)); }
# the build rewrites a tracked file (Xcode does this to Localizable.xcstrings): the packet puts it back so the worktree stays clean
card=$(mkcard doing); proj=$(mkproject 'echo changed-by-build >> a.txt'); rm -rf "$T/data/tasks/T7"
expect build_side_effects_allowed_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ -z "$(git -C "$WT" status --porcelain)" ] && { echo "PASS  build_side_effects_undone"; PASS=$((PASS+1)); } || { echo "FAIL  build_side_effects_undone: $(git -C "$WT" status --porcelain)"; FAIL=$((FAIL+1)); }

# --- a project without a build command or with screenshots off ---
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
jq 'del(.buildCommand) | .screenshots=false | del(.simulator)' "$F/valid_project.json" | jq --arg d "$T/data" --arg r "$WT" '.dataDir=$d | .repoPath=$r' > "$T/bare.json"
expect no_build_no_shots_review_0 0 "" env AGENT_PANEL_SCREENSHOT_CMD='false' bash "$R" "$card" "$WT" "" "$T/bare.json"
[ "$(status_of "$card")" = "review" ] && grep -q "^Build: none" "$card" && grep -q "^Screenshots: not used" "$card" && ! grep -q "shots/" "$card" && { echo "PASS  bare_packet_says_none"; PASS=$((PASS+1)); } || { echo "FAIL  bare_packet_says_none"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
jq '.screenshots=false' "$T/project.json" > "$T/noshots.json"   # build command kept, screenshots off
expect build_kept_shots_off_0 0 "" env AGENT_PANEL_SCREENSHOT_CMD='false' bash "$R" "$card" "$WT" FAKE-UDID "$T/noshots.json"
grep -q "^Build: passed" "$card" && grep -q "^Screenshots: not used" "$card" && { echo "PASS  build_runs_when_shots_off"; PASS=$((PASS+1)); } || { echo "FAIL  build_runs_when_shots_off"; FAIL=$((FAIL+1)); }
# --- N51: the agent's tree is never touched, one base branch, one card format ---
# an edit the agent makes while the build runs survives (the build runs in a throw-away worktree)
card=$(mkcard doing); proj=$(mkproject "echo agent-edit >> '$WT/a.txt'"); rm -rf "$T/data/tasks/T7"
expect build_runs_beside_the_agent_tree_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
grep -qx agent-edit "$WT/a.txt" && { echo "PASS  agent_edit_survives_packet"; PASS=$((PASS+1)); } || { echo "FAIL  agent_edit_survives_packet"; FAIL=$((FAIL+1)); }
reset_wt
! git -C "$WT" worktree list | grep -q build-tree && { echo "PASS  throwaway_worktree_removed"; PASS=$((PASS+1)); } || { echo "FAIL  throwaway_worktree_removed: $(git -C "$WT" worktree list)"; FAIL=$((FAIL+1)); }
# the build sees the reviewed commit, not the agent's working directory
card=$(mkcard doing); proj=$(mkproject "test -f a.txt && test \"\$(git rev-parse HEAD)\" = $(git -C "$WT" rev-parse HEAD)"); rm -rf "$T/data/tasks/T7"
expect build_sees_the_reviewed_commit_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
# a card that changed while the packet was built is not overwritten
card=$(mkcard doing); proj=$(mkproject "echo 'agent wrote this' >> '$card'"); rm -rf "$T/data/tasks/T7"
expect card_changed_during_packet_refused_1 1 "the card changed" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
grep -q 'agent wrote this' "$card" && [ "$(status_of "$card")" = "doing" ] && { echo "PASS  concurrent_card_edit_kept"; PASS=$((PASS+1)); } || { echo "FAIL  concurrent_card_edit_kept"; FAIL=$((FAIL+1)); }
[ -z "$(ls "$T/data/tasks" | grep -v '^T7')" ] && { echo "PASS  no_temp_file_left_in_card_folder"; PASS=$((PASS+1)); } || { echo "FAIL  no_temp_file_left_in_card_folder: $(ls "$T/data/tasks")"; FAIL=$((FAIL+1)); }
# the repository sits on another branch: the diff still covers only the agent's commits against mainBranch
git -C "$WT" checkout -q main; git -C "$WT" checkout -q -b other; echo o > "$WT/o.txt"; git -C "$WT" add o.txt; git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m other
git -C "$WT" worktree add -q -b agent "$T/agentwt" main; echo x > "$T/agentwt/x.txt"; git -C "$T/agentwt" add x.txt; git -C "$T/agentwt" -c user.name=t -c user.email=t@t commit -q -m x
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"
expect diff_against_main_while_repo_on_another_branch_0 0 "" bash "$R" "$card" "$T/agentwt" FAKE-UDID "$proj"
grep -q 'x.txt' "$card" && ! grep -q 'o.txt' "$card" && { echo "PASS  diff_covers_only_agent_commits"; PASS=$((PASS+1)); } || { echo "FAIL  diff_covers_only_agent_commits"; FAIL=$((FAIL+1)); }
# mainBranch from the project is the base
git -C "$WT" branch -q trunk main
jq '.mainBranch="trunk"' "$proj" > "$T/p-trunk.json"; rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
expect main_branch_setting_is_the_base_0 0 "" bash "$R" "$card" "$T/agentwt" FAKE-UDID "$T/p-trunk.json"
# analysis check also uses mainBranch, not the repository's current branch
proj=$(mkproject 'false')
rm -rf "$T/data/tasks/T7"; mkacard "Findings."
expect analysis_ignores_repo_current_branch_0 0 "" bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$proj"
git -C "$WT" checkout -q feature
# `kind: analysis` in the body is not the task kind; CRLF cards parse
card=$(mkcard doing); proj=$(mkproject 'true'); rm -rf "$T/data/tasks/T7"; printf 'kind: analysis\n' >> "$card"
expect body_kind_line_ignored_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
grep -q '^Build: passed' "$card" && { echo "PASS  body_kind_does_not_skip_build"; PASS=$((PASS+1)); } || { echo "FAIL  body_kind_does_not_skip_build"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; mkacard "Findings."; sed -i '' 's/$/\r/' "$T/data/tasks/T7.md"
expect crlf_analysis_card_0 0 "" bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$(mkproject false)"
grep -q 'Analysis task' "$T/data/tasks/T7.md" && { echo "PASS  crlf_kind_analysis_read"; PASS=$((PASS+1)); } || { echo "FAIL  crlf_kind_analysis_read"; FAIL=$((FAIL+1)); }
# --- N168: testCommand runs after the build command ---
mkproject_t() { # <build> <test> -> project.json path
  jq --arg t "$2" '.testCommand=$t' "$(mkproject "$1")" > "$T/project-t.json"; echo "$T/project-t.json"
}
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject_t 'echo built > "$PWD/../order.txt"' 'echo tested >> "$PWD/../order.txt"; cat "$PWD/../order.txt"')
expect test_command_passes_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
grep -q '^Build: passed, tests passed' "$card" && grep -q '^Build: passed' "$card" && { echo "PASS  build_line_says_tests_passed"; PASS=$((PASS+1)); } || { echo "FAIL  build_line_says_tests_passed: $(grep '^Build:' "$card")"; FAIL=$((FAIL+1)); }
[ "$(grep -c . "$T/build/wt/order.txt" 2>/dev/null)" = "2" ] && [ "$(head -1 "$T/build/wt/order.txt")" = "built" ] && { echo "PASS  tests_run_after_build"; PASS=$((PASS+1)); } || { echo "FAIL  tests_run_after_build: $(cat "$T/build/wt/order.txt" 2>&1)"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject_t 'true' 'echo "FAILED: 1 test"; false')
expect test_command_fails_1 1 "EVIDENCE MISSING: tests failed" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && { echo "PASS  failed_tests_status_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  failed_tests_status_unchanged: $(status_of "$card")"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject_t 'false' 'touch "$PWD/../ran-tests"')
expect broken_build_skips_tests_1 1 "EVIDENCE MISSING: build" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ ! -e "$T/build/wt/ran-tests" ] && { echo "PASS  tests_not_run_after_failed_build"; PASS=$((PASS+1)); } || { echo "FAIL  tests_not_run_after_failed_build"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'true')
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
grep -q '^Build: passed' "$card" && ! grep -q 'tests passed' "$card" && { echo "PASS  no_test_command_keeps_old_line"; PASS=$((PASS+1)); } || { echo "FAIL  no_test_command_keeps_old_line"; FAIL=$((FAIL+1)); }
# --- N62: one packet per card at a time, built outside the data folder ---
BT="$T/build/wt"   # <build root>/<repo folder name>
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'sleep 2')
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1 & first=$!
sleep 0.7
expect second_run_same_card_refused_1 1 "already being prepared" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
wait $first && { echo "PASS  first_run_unaffected_by_second"; PASS=$((PASS+1)); } || { echo "FAIL  first_run_unaffected_by_second"; FAIL=$((FAIL+1)); }
[ ! -e "$BT/T7.lock" ] && { echo "PASS  lock_released_after_run"; PASS=$((PASS+1)); } || { echo "FAIL  lock_released_after_run"; FAIL=$((FAIL+1)); }
# N264: the app counts its run limit from PACKET RUN STARTED, printed once the build slot is taken (or when there is nothing to wait for)
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'true')
expect run_started_marker_printed_0 0 "PACKET RUN STARTED" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
# a packet waiting behind a busy slot has not started: no marker until the slot is taken
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
mkdir -p "$T/build/.build-slot"; sleep 30 & holder=$!; echo $holder > "$T/build/.build-slot/pid"
out=$(AGENT_PANEL_SLOT_TIMEOUT=2 AGENT_PANEL_SLOT_POLL=1 bash "$R" "$card" "$WT" FAKE-UDID "$proj" 2>&1)
case "$out" in *"PACKET RUN STARTED"*) echo "FAIL  no_marker_while_waiting_for_slot"; FAIL=$((FAIL+1)) ;; *"waited"*) echo "PASS  no_marker_while_waiting_for_slot"; PASS=$((PASS+1)) ;; *) echo "FAIL  no_marker_while_waiting_for_slot: $out"; FAIL=$((FAIL+1)) ;; esac
kill $holder 2>/dev/null; rm -rf "$T/build/.build-slot"
# the second run for the same card (the lock) names the owner's pid, also when it lost the take-over race: the app waits for that result
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'sleep 2')
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1 & first=$!
sleep 0.7
expect second_run_names_owner_pid_1 1 "already being prepared (pid " bash "$R" "$card" "$WT" FAKE-UDID "$proj"
wait $first
# a lock left by a dead process is taken over
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'true')
( exit 0 ) & dead=$!; wait $dead; mkdir -p "$BT/T7.lock"; echo "$dead" > "$BT/T7.lock/pid"
expect stale_lock_taken_over_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
# another card is not blocked by this card's lock
mkdir -p "$BT/T8.lock"; echo $$ > "$BT/T8.lock/pid"
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
expect other_cards_lock_irrelevant_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"; rm -rf "$BT/T8.lock"
# the build runs outside the data folder, which gets only the card, build.log and shots
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject "case \"\$PWD\" in '$T/data'*|'$(cd "$T" && pwd -P)/data'*) exit 1;; esac")
expect build_runs_outside_data_folder_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
extra=$(cd "$T/data" && find . -mindepth 1 | grep -v -e '^\./tasks$' -e '^\./tasks/T7\.md$' -e '^\./tasks/T7$' -e '^\./tasks/T7/build\.log$' -e '^\./tasks/T7/shots' )
[ -z "$extra" ] && { echo "PASS  data_folder_has_only_card_log_shots"; PASS=$((PASS+1)); } || { echo "FAIL  data_folder_has_only_card_log_shots: $extra"; FAIL=$((FAIL+1)); }
# the build tree is gone after success and after failure
[ ! -e "$BT/T7" ] && { echo "PASS  build_tree_gone_after_success"; PASS=$((PASS+1)); } || { echo "FAIL  build_tree_gone_after_success"; FAIL=$((FAIL+1)); }
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'false')
bash "$R" "$card" "$WT" FAKE-UDID "$proj" >/dev/null 2>&1
[ ! -e "$BT/T7" ] && [ ! -e "$BT/T7.lock" ] && ! git -C "$WT" worktree list | grep -q T7 && { echo "PASS  build_tree_gone_after_failure"; PASS=$((PASS+1)); } || { echo "FAIL  build_tree_gone_after_failure"; FAIL=$((FAIL+1)); }
# every test that runs the real review-packet.sh points the build tree at its own temporary folder
for f in tests/review-packet.test.sh app/AgentPanelTests/ReviewIntegrationTests.swift; do
  grep -q 'AGENT_PANEL_BUILD_ROOT' "$ROOT/$f" && { echo "PASS  build_root_set_in_$(basename "$f")"; PASS=$((PASS+1)); } || { echo "FAIL  build_root_set_in_$(basename "$f")"; FAIL=$((FAIL+1)); }
done
# --- N116: one packet build at a time on the machine (a second card waits for the build slot) ---
SLOT="$T/build/.build-slot"
mkcard2() { printf -- '---\nid: T8\nproject: demo\nstatus: doing\nfiles:\n  - a.txt\n---\n# T8\n\n## Goal\nx\n\n## Review packet\n\n## Decision\n' > "$T/data/tasks/T8.md"; echo "$T/data/tasks/T8.md"; }
rm -rf "$T/data/tasks/T7" "$T/data/tasks/T8" "$T/order"; card=$(mkcard doing); card2=$(mkcard2)
projb=$(mkproject 'echo start >> "'$T'/order"; sleep 2; echo end >> "'$T'/order"')
bash "$R" "$card" "$WT" FAKE-UDID "$projb" > "$T/out1" 2>&1 & p1=$!
bash "$R" "$card2" "$WT" FAKE-UDID "$projb" > "$T/out2" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
[ "$r1$r2" = "00" ] && [ "$(tr '\n' ' ' < "$T/order")" = "start end start end " ] && { echo "PASS  two_packets_build_one_after_the_other"; PASS=$((PASS+1)); } || { echo "FAIL  two_packets_build_one_after_the_other: rc=$r1$r2 order=$(tr '\n' ' ' < "$T/order")"; FAIL=$((FAIL+1)); }
cat "$T/out1" "$T/out2" | grep -q "waiting for another packet to finish" && { echo "PASS  waiting_line_printed"; PASS=$((PASS+1)); } || { echo "FAIL  waiting_line_printed"; FAIL=$((FAIL+1)); }
[ ! -e "$SLOT" ] && { echo "PASS  build_slot_released_after_run"; PASS=$((PASS+1)); } || { echo "FAIL  build_slot_released_after_run"; FAIL=$((FAIL+1)); }
# a slot held by a live process that never finishes: the wait ends with a clear message at the timeout
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing); proj=$(mkproject 'true')
mkdir -p "$SLOT"; echo $$ > "$SLOT/pid"
expect build_slot_wait_times_out_1 1 "waited" env AGENT_PANEL_SLOT_TIMEOUT=2 AGENT_PANEL_SLOT_POLL=1 bash "$R" "$card" "$WT" FAKE-UDID "$proj"
[ "$(status_of "$card")" = "doing" ] && [ -e "$SLOT" ] && { echo "PASS  timeout_leaves_card_and_foreign_slot"; PASS=$((PASS+1)); } || { echo "FAIL  timeout_leaves_card_and_foreign_slot"; FAIL=$((FAIL+1)); }
rm -rf "$SLOT"
# a slot left by a dead process is taken over
( exit 0 ) & dead=$!; wait $dead; mkdir -p "$SLOT"; echo "$dead" > "$SLOT/pid"
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
expect stale_build_slot_taken_over_0 0 "" bash "$R" "$card" "$WT" FAKE-UDID "$proj"
# analysis tasks build nothing and never wait for the slot
mkdir -p "$SLOT"; echo $$ > "$SLOT/pid"; rm -rf "$T/data/tasks/T7"; mkacard "Findings."
expect analysis_ignores_build_slot_0 0 "" env AGENT_PANEL_SLOT_TIMEOUT=2 bash "$R" "$T/data/tasks/T7.md" "$AWT" FAKE-UDID "$(mkproject false)"
rm -rf "$SLOT"
# --- N122: the packet's own app-test.sh run uses the slot the packet holds (no deadlock on itself) ---
mkdir -p "$T/pk/scripts" "$T/pk/app" "$T/pk/bin"; cp "$ROOT/scripts/app-test.sh" "$T/pk/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$T/pk/bin/xcodegen"
printf '#!/bin/sh\necho "** TEST SUCCEEDED **"\n' > "$T/pk/bin/xcodebuild"; chmod +x "$T/pk/bin/xcodegen" "$T/pk/bin/xcodebuild"
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
projc=$(mkproject "PATH='$T/pk/bin':\$PATH bash '$T/pk/scripts/app-test.sh'")
expect packet_with_inner_app_test_no_deadlock_0 0 "" env AGENT_PANEL_SLOT_TIMEOUT=3 AGENT_PANEL_SLOT_POLL=1 bash "$R" "$card" "$WT" FAKE-UDID "$projc"
[ "$(status_of "$card")" = "review" ] && { echo "PASS  packet_with_inner_app_test_reaches_review"; PASS=$((PASS+1)); } || { echo "FAIL  packet_with_inner_app_test_reaches_review: $(status_of "$card")"; FAIL=$((FAIL+1)); }
# the owner is named for whoever waits
rm -rf "$T/data/tasks/T7"; card=$(mkcard doing)
projd=$(mkproject 'cat "'$SLOT'/what" > "'$T'/what"')
bash "$R" "$card" "$WT" FAKE-UDID "$projd" >/dev/null 2>&1
grep -q "review packet" "$T/what" && { echo "PASS  packet_names_itself_in_slot"; PASS=$((PASS+1)); } || { echo "FAIL  packet_names_itself_in_slot"; FAIL=$((FAIL+1)); }
finish
