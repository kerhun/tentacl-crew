#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
M="$ROOT/scripts/merge-task.sh"; F="$ROOT/tests/fixtures/config"
T=$(mktemp -d /tmp/agent-panel-mt.XXXXXX); trap 'rm -rf "$T"' EXIT
export TENTACL_ACTION_LOG="$T/actions.log"   # a merge here must never write the real action log
G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

# fresh <name>: repo with main (a.txt b.txt) and worktree on branch feat/x that adds c.txt and edits a.txt
fresh() {
  R="$T/$1/repo"; W="$T/$1/wt"; mkdir -p "$T/$1"
  git init -q -b main "$R"; echo a > "$R/a.txt"; echo b > "$R/b.txt"; G "$R" add .; G "$R" commit -qm init
  G "$R" worktree add -q -b feat/x "$W"; echo c > "$W/c.txt"; echo a2 >> "$W/a.txt"; G "$W" add .; G "$W" commit -qm "feat"
  jq --arg r "$R" --arg d "$T/$1/data" '.repoPath=$r | .dataDir=$d' "$F/valid_project.json" > "$T/$1/project.json"; P="$T/$1/project.json"
  HEAD_SHA=$(G "$W" rev-parse HEAD)
}
snap() { echo "$(G "$R" rev-parse HEAD) $(G "$R" status --porcelain) $(G "$W" rev-parse HEAD) $(G "$W" status --porcelain)"; }

# --- clean fast-forward ---
fresh ok
expect merges_fast_forward_0 0 "\"merged\":\"$HEAD_SHA\"" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(G "$R" rev-parse HEAD)" = "$HEAD_SHA" ] && [ -f "$R/c.txt" ] && { echo "PASS  main_advanced_to_branch_tip"; PASS=$((PASS+1)); } || { echo "FAIL  main_advanced_to_branch_tip"; FAIL=$((FAIL+1)); }

# --- inspect changes nothing and reports the state ---
fresh insp; before=$(snap)
out=$(bash "$M" --inspect "$P" feat/x "$W")
[ "$(snap)" = "$before" ] && { echo "PASS  inspect_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  inspect_changes_nothing"; FAIL=$((FAIL+1)); }
[ "$(printf '%s' "$out" | jq -r '[.head, .base, (.ahead|tostring), (.behind|tostring), (.worktreeDirty|tostring), (.dirtyOverlap|length|tostring)] | join(" ")')" = "$HEAD_SHA main 1 0 false 0" ] \
  && { echo "PASS  inspect_reports_state"; PASS=$((PASS+1)); } || { echo "FAIL  inspect_reports_state: $out"; FAIL=$((FAIL+1)); }

# --- main moved on: not a fast-forward (4), nothing changes ---
fresh moved; echo m > "$R/m.txt"; G "$R" add .; G "$R" commit -qm "main moves"; before=$(snap)
expect main_moved_4 4 "fast-forward" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(snap)" = "$before" ] && { echo "PASS  main_moved_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  main_moved_changes_nothing"; FAIL=$((FAIL+1)); }
[ "$(bash "$M" --inspect "$P" feat/x "$W" | jq .behind)" = "1" ] && { echo "PASS  inspect_counts_behind"; PASS=$((PASS+1)); } || { echo "FAIL  inspect_counts_behind"; FAIL=$((FAIL+1)); }

# --- the repo is on another branch (3) ---
fresh other; G "$R" checkout -q -b elsewhere; before=$(snap)
expect repo_on_other_branch_3 3 "elsewhere" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(snap)" = "$before" ] && { echo "PASS  other_branch_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  other_branch_changes_nothing"; FAIL=$((FAIL+1)); }

# --- the user's unsaved edit to a file the branch also changes (5) ---
fresh overlap; echo mine >> "$R/a.txt"; before=$(snap)
expect user_edit_in_the_way_5 5 "a.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(snap)" = "$before" ] && { echo "PASS  overlap_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  overlap_changes_nothing"; FAIL=$((FAIL+1)); }
echo "$(bash "$M" --inspect "$P" feat/x "$W" | jq -r '.dirtyOverlap | join(",")')" | grep -qx "a.txt" && { echo "PASS  inspect_lists_overlap"; PASS=$((PASS+1)); } || { echo "FAIL  inspect_lists_overlap"; FAIL=$((FAIL+1)); }

# --- an untracked file with the name of a file the branch adds is in the way too (5) ---
fresh untracked; echo mine > "$R/c.txt"
expect untracked_same_name_5 5 "c.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"

# --- the user's edit to a file the branch does not touch is kept and does not block ---
fresh keeps; echo mine >> "$R/b.txt"
expect unrelated_edit_does_not_block_0 0 "" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
grep -q mine "$R/b.txt" && { echo "PASS  unrelated_edit_kept"; PASS=$((PASS+1)); } || { echo "FAIL  unrelated_edit_kept"; FAIL=$((FAIL+1)); }

# --- unsaved work in the agent's worktree (6) ---
fresh wtdirty; echo wip > "$W/wip.txt"; before=$(snap)
expect worktree_unsaved_work_6 6 "wip.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(snap)" = "$before" ] && { echo "PASS  worktree_dirty_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  worktree_dirty_changes_nothing"; FAIL=$((FAIL+1)); }

# --- the agent committed after the packet (7) ---
fresh stale; echo more > "$W/d.txt"; G "$W" add .; G "$W" commit -qm later; before=$(snap)
expect branch_tip_moved_7 7 "expected" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
[ "$(snap)" = "$before" ] && { echo "PASS  stale_head_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  stale_head_changes_nothing"; FAIL=$((FAIL+1)); }

# --- a branch with no commits of its own: nothing to merge ---
fresh empty; G "$W" reset -q --hard main
sha=$(G "$W" rev-parse HEAD)
expect nothing_to_merge_0 0 '"merged":null' bash "$M" "$P" feat/x "$W" --expect-head "$sha"

# --- the worktree must be on the named branch ---
fresh wrongwt; G "$W" checkout -q -b not-it
expect worktree_on_other_branch_2 2 "not-it" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"

# --- hostile or malformed arguments never reach git (2) ---
fresh bad
for b in "--force" "x; rm -rf ~" "../x" "feat/x.lock" "-x" "nope"; do
  expect "refuses_branch_$(printf '%s' "$b" | tr -c 'A-Za-z0-9' _)_2" 2 "" bash "$M" "$P" "$b" "$W" --expect-head "$HEAD_SHA"
done
expect missing_expect_head_2 2 "--expect-head" bash "$M" "$P" feat/x "$W"
expect no_arguments_2 2 "usage" bash "$M"

# --- review findings ---
# a git-ignored local file with the name of a file the branch adds would be silently overwritten
fresh ign; printf 'c.txt\n' > "$R/.gitignore"; G "$R" add .gitignore; G "$R" commit -qm ignore
G "$W" merge -q --no-edit main >/dev/null 2>&1; HEAD_SHA=$(G "$W" rev-parse HEAD)
echo "my secret" > "$R/c.txt"
expect ignored_file_in_the_way_5 5 "c.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
grep -q "my secret" "$R/c.txt" && { echo "PASS  ignored_file_kept"; PASS=$((PASS+1)); } || { echo "FAIL  ignored_file_kept"; FAIL=$((FAIL+1)); }

# a rename on the branch: the user's unsaved edit to the OLD name is in the way too
fresh ren; G "$W" mv b.txt renamed.txt; G "$W" commit -qm rename; HEAD_SHA=$(G "$W" rev-parse HEAD); echo mine >> "$R/b.txt"
expect edit_to_renamed_file_5 5 "b.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"

# git itself refusing the merge is not "main moved on" (exit 8, git's reason is shown)
fresh gitfail; touch "$R/.git/index.lock"
expect git_refuses_the_merge_8 8 "git could not" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
rm -f "$R/.git/index.lock"

# --expect-head must be a full commit id (it is what gets merged)
expect expect_head_must_be_a_full_sha_2 2 "40" bash "$M" "$P" feat/x "$W" --expect-head "main"

# non-ASCII names are listed readably
fresh uni; echo x > "$W/şey dosya.txt"; G "$W" add .; G "$W" commit -qm uni; HEAD_SHA=$(G "$W" rev-parse HEAD); echo mine > "$R/şey dosya.txt"
expect non_ascii_name_listed_5 5 "şey dosya.txt" bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"

# --- --rebase: a behind branch that applies cleanly is rebased in its worktree and reports the new head ---
fresh rb; echo m > "$R/m.txt"; G "$R" add .; G "$R" commit -qm "main moves"; main_sha=$(G "$R" rev-parse main)
expect rebase_clean_0 0 '"rebased":"' bash "$M" --rebase "$P" feat/x "$W"
new=$(G "$W" rev-parse HEAD)
[ "$new" != "$HEAD_SHA" ] && [ "$(G "$W" merge-base HEAD main)" = "$main_sha" ] && [ -f "$W/m.txt" ] && [ -f "$W/c.txt" ] && { echo "PASS  rebase_puts_branch_on_main"; PASS=$((PASS+1)); } || { echo "FAIL  rebase_puts_branch_on_main"; FAIL=$((FAIL+1)); }
[ "$(bash "$M" --rebase "$P" feat/x "$W" | jq -r .rebased)" = "null" ] && { echo "PASS  rebase_up_to_date_is_null"; PASS=$((PASS+1)); } || { echo "FAIL  rebase_up_to_date_is_null"; FAIL=$((FAIL+1)); }
expect rebased_branch_merges_0 0 '"merged":"' bash "$M" "$P" feat/x "$W" --expect-head "$new"

# --- --rebase: a conflict leaves everything exactly as it was (9) and names the files ---
fresh rbc; echo other >> "$R/a.txt"; G "$R" add .; G "$R" commit -qm "main edits a"; before=$(snap)
expect rebase_conflict_9 9 "a.txt" bash "$M" --rebase "$P" feat/x "$W"
[ "$(snap)" = "$before" ] && ! G "$W" status | grep -q "rebase in progress" && { echo "PASS  rebase_conflict_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  rebase_conflict_changes_nothing"; FAIL=$((FAIL+1)); }

# --- --rebase: a dirty worktree is refused (6) and untouched ---
fresh rbd; echo m > "$R/m.txt"; G "$R" add .; G "$R" commit -qm "main moves"; echo wip > "$W/wip.txt"; before=$(snap)
expect rebase_dirty_tree_6 6 "wip.txt" bash "$M" --rebase "$P" feat/x "$W"
[ "$(snap)" = "$before" ] && { echo "PASS  rebase_dirty_changes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  rebase_dirty_changes_nothing"; FAIL=$((FAIL+1)); }
# --- the panel's action log gets a merged line after a merge (and only then); an unwritable log never fails the merge ---
fresh lg; mkdir -p "$T/lg/data/tasks"; printf -- '---\nid: N7\nproject: demo\nstatus: review\nbranch: feat/x\n---\n# N7\n' > "$T/lg/data/tasks/N7.md"
bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA" >/dev/null
grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z \[demo\] merged N7 $HEAD_SHA \(script\)$" "$TENTACL_ACTION_LOG" && { echo "PASS  merge_writes_action_log_line"; PASS=$((PASS+1)); } || { echo "FAIL  merge_writes_action_log_line: $(cat "$TENTACL_ACTION_LOG" 2>&1)"; FAIL=$((FAIL+1)); }
before=$(wc -l < "$TENTACL_ACTION_LOG")
fresh lg2; echo m > "$R/m.txt"; G "$R" add .; G "$R" commit -qm "main moves"
bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA" >/dev/null 2>&1
bash "$M" --inspect "$P" feat/x "$W" >/dev/null
[ "$(wc -l < "$TENTACL_ACTION_LOG")" = "$before" ] && { echo "PASS  refused_merge_and_inspect_write_no_log"; PASS=$((PASS+1)); } || { echo "FAIL  refused_merge_and_inspect_write_no_log"; FAIL=$((FAIL+1)); }
fresh lg3; export TENTACL_ACTION_LOG="$T/no/such/dir/x/actions.log"; mkdir -p "$T/no"; chmod 500 "$T/no"
expect unwritable_log_does_not_fail_merge 0 '"merged":"' bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA"
chmod 700 "$T/no"; export TENTACL_ACTION_LOG="$T/actions.log"
# --- N221: under XCTest, without TENTACL_ACTION_LOG, the merge never writes the default (real) log ---
fresh lg4; mkdir -p "$T/fakehome"
out=$(env -u TENTACL_ACTION_LOG HOME="$T/fakehome" XCTestConfigurationFilePath=/x bash "$M" "$P" feat/x "$W" --expect-head "$HEAD_SHA" 2>/dev/null)
[ ! -e "$T/fakehome/Library" ] && printf '%s' "$out" | grep -q '"merged":"' && { echo "PASS  xctest_without_log_env_writes_no_default_log"; PASS=$((PASS+1)); } || { echo "FAIL  xctest_without_log_env_writes_no_default_log"; FAIL=$((FAIL+1)); }

finish
