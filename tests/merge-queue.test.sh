#!/usr/bin/env bash
# merge-queue.sh on temporary repos: each step and each way it stops.
source "$(dirname "$0")/lib.sh"
Q="$ROOT/scripts/merge-queue.sh"; FX="$ROOT/tests/fixtures/merge-queue"
T=$(mktemp -d /tmp/agent-panel-mq.XXXXXX); trap 'rm -rf "$T"' EXIT
export TENTACL_ACTION_LOG="$T/panel.log" AGENT_PANEL_BUILD_ROOT="$T/build" MERGE_QUEUE_POLL=1 MERGE_QUEUE_LOCK_TIMEOUT=2
export MERGE_QUEUE_PACKET="$FX/fake-packet.sh" MERGE_QUEUE_STOP="$FX/fake-stop.sh" MERGE_QUEUE_START="$FX/fake-start.sh"
export FAKE_STOP_LOG="$T/stop.log" FAKE_START_LOG="$T/start.log" FAKE_PACKET_COUNT="$T/packets"
G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then ok "$1"; else no "$1" "$2"; fi; }

# fresh <name> [status]: repo on main, worktree for task/n1 with one commit, a card N1 and a project.json
fresh() {
  D="$T/$1"; R="$D/repo"; W="$R/.agent-worktrees/task-n1"; DATA="$D/data"; mkdir -p "$DATA/tasks" "$R"
  git init -q -b main "$R"; echo a > "$R/a.txt"; echo b > "$R/b.txt"; echo ".agent-worktrees" > "$R/.gitignore"; G "$R" add .; G "$R" commit -qm init
  G "$R" worktree add -q -b task/n1 "$W"; echo c > "$W/c.txt"; G "$W" add .; G "$W" commit -qm feat
  printf -- '---\nid: N1\nstatus: %s\nbranch: task/n1\nagent: dev-n1\n---\n# N1\n## Report\nx\n' "${2:-review}" > "$DATA/tasks/N1.md"
  jq -n --arg r "$R" --arg d "$DATA" '{id:"mq",name:"MQ",repoPath:$r,dataDir:$d}' > "$D/project.json"; P="$D/project.json"
  CARD="$DATA/tasks/N1.md"; rm -f "$FAKE_STOP_LOG" "$FAKE_START_LOG" "$FAKE_PACKET_COUNT"; rm -rf "$T/build"
}
last() { tail -n1; }

# --- success: packet, merge, tag, card done, log, agent closed ---
fresh ok
out=$(bash "$Q" --decision "Looks good." "$P" N1); rc=$?
H=$(G "$R" rev-parse HEAD)
check merges_0 "[ $rc -eq 0 ]"
check result_line "[ \"\$(printf '%s' \"$out\" | tail -n1)\" = \"N1 merged ${H:0:7} stable-1\" ]"
check main_has_work "[ -f '$R/c.txt' ]"
check tag_on_merged_commit "[ \"\$(G '$R' rev-parse stable-1)\" = '$H' ]"
check card_done "grep -qx 'status: done' '$CARD'"
check decision_written "grep -q 'Merged .* by PM (${H:0:7}, stable-1). Looks good.' '$CARD'"
check front_matter_intact "[ \"\$(head -n1 '$CARD')\" = '---' ] && grep -qx 'agent: dev-n1' '$CARD'"
check actions_log_line "grep -q 'done N1 ${H:0:7} (PM)' '$DATA/actions.log'"
check agent_closed "grep -q \"dev-n1 $W --remove-worktree --delete-branch --expect-branch task/n1 --no-sim\" '$FAKE_STOP_LOG'"
check lock_released "[ ! -d '$T/build/.merge-queue.lock' ]"

# --- the next tag counts on ---
fresh next; G "$R" tag stable-7
out=$(bash "$Q" "$P" N1 | tail -n1); check next_tag_is_8 "[ \"\${out##* }\" = stable-8 ]"

# --- a current passing packet is not made again ---
fresh cur; printf '\n## Review packet\nHead: %s\nBuild: passed\n' "$(G "$W" rev-parse HEAD)" >> "$CARD"
bash "$Q" "$P" N1 >/dev/null; check current_packet_kept "[ ! -f '$FAKE_PACKET_COUNT' ]"

# --- behind main: rebased, packet made on the new head, merged ---
fresh behind; echo m > "$R/m.txt"; G "$R" add .; G "$R" commit -qm "main moves"
out=$(bash "$Q" "$P" N1 | tail -n1)
check behind_merged "printf '%s' \"$out\" | grep -q '^N1 merged '"
check behind_rebased_linear "[ \"\$(G '$R' rev-list --count main)\" = 3 ] && [ -f '$R/m.txt' ] && [ -f '$R/c.txt' ]"
check behind_packet_after_rebase "[ \"\$(wc -l < '$FAKE_PACKET_COUNT' | tr -d ' ')\" = 1 ]"

# --- the panel's "behind main" needs-fix is not a real fix ---
fresh bm needs-fix; printf '\n## Fix notes\n> Your branch is 2 commits behind main\n' >> "$CARD"
out=$(bash "$Q" "$P" N1 | tail -n1); check behind_needs_fix_merges "printf '%s' \"$out\" | grep -q '^N1 merged '"

# --- a real needs-fix stops (10), nothing changes ---
fresh nf needs-fix; printf '\n## Fix notes\n> please fix the thing\n' >> "$CARD"; before=$(G "$R" rev-parse HEAD)
expect needs_fix_10 10 "N1 needs a fix" bash "$Q" "$P" N1
check needs_fix_changes_nothing "[ \"\$(G '$R' rev-parse HEAD)\" = '$before' ] && grep -qx 'status: needs-fix' '$CARD'"

# --- a card already done is refused (10) ---
fresh dn done; expect done_card_10 10 "not in review" bash "$Q" "$P" N1

# --- rebase conflict (11): branch untouched, main untouched ---
fresh conf; echo x > "$W/a.txt"; G "$W" add .; G "$W" commit -qm "edit a"; echo y > "$R/a.txt"; G "$R" add .; G "$R" commit -qm "main edits a"
wb=$(G "$W" rev-parse HEAD); mb=$(G "$R" rev-parse HEAD)
expect rebase_conflict_11 11 "a.txt" bash "$Q" "$P" N1
check conflict_changes_nothing "[ \"\$(G '$W' rev-parse HEAD)\" = '$wb' ] && [ \"\$(G '$R' rev-parse HEAD)\" = '$mb' ] && [ -z \"\$(G '$W' status --porcelain)\" ]"

# --- packet cannot be made (12): tried three times, card not done ---
fresh pf; export FAKE_PACKET_FAIL=1
expect packet_failed_12 12 "packet failed: EVIDENCE MISSING: build failed" bash "$Q" "$P" N1
check packet_tried_3_times "[ \"\$(wc -l < '$FAKE_PACKET_COUNT' | tr -d ' ')\" = 3 ]"
check packet_failure_keeps_card "grep -qx 'status: review' '$CARD' && [ ! -f '$R/c.txt' ]"
unset FAKE_PACKET_FAIL

# --- merge-task refuses: unsaved work in the agent's worktree (13) ---
fresh wd; bash "$FX/fake-packet.sh" "$CARD" "$W"; echo wip > "$W/wip.txt"
expect merge_refused_13 13 "merge refused" bash "$Q" "$P" N1
check refused_not_tagged "[ -z \"\$(G '$R' tag -l 'stable-*')\" ] && grep -qx 'status: review' '$CARD'"

# --- the user's unsaved edit in the repo is in the way (13) ---
fresh ow; echo c > "$R/c.txt"; expect untracked_in_the_way_13 13 "merge refused" bash "$Q" "$P" N1

# --- a second caller waits, then gives up (14) while the first holds the lock ---
fresh lk; mkdir -p "$T/build/.merge-queue.lock"; sleep 30 & sp=$!; echo $sp > "$T/build/.merge-queue.lock/pid"
expect lock_held_14 14 "another merge is running" bash "$Q" "$P" N1
check lock_kept_by_owner "[ -d '$T/build/.merge-queue.lock' ]"; kill $sp 2>/dev/null; wait $sp 2>/dev/null
# a lock of a dead process is taken over
echo 999999 > "$T/build/.merge-queue.lock/pid"; out=$(bash "$Q" "$P" N1 | tail -n1); check stale_lock_taken_over "printf '%s' \"$out\" | grep -q '^N1 merged '"

# --- two callers at once: both merge, one after the other, with different tags ---
fresh two; W2="$R/.agent-worktrees/task-n2"; G "$R" worktree add -q -b task/n2 "$W2"; echo d > "$W2/d.txt"; G "$W2" add .; G "$W2" commit -qm f2
printf -- '---\nid: N2\nstatus: review\nbranch: task/n2\nagent: dev-n2\n---\n' > "$DATA/tasks/N2.md"
export MERGE_QUEUE_LOCK_TIMEOUT=60
bash "$Q" "$P" N1 > "$T/o1" & p1=$!; bash "$Q" "$P" N2 > "$T/o2" & p2=$!; wait $p1; r1=$?; wait $p2; r2=$?
check both_merged "[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ -f '$R/c.txt' ] && [ -f '$R/d.txt' ]"
check distinct_tags "[ \"\$(G '$R' tag -l 'stable-*' | wc -l | tr -d ' ')\" = 2 ]"
export MERGE_QUEUE_LOCK_TIMEOUT=2

# --- start of the next cards, with the key ---
fresh st; bash "$Q" --start "N2 N3" --key K1 "$P" N1 >/dev/null
check start_requested "grep -q -- \"--key K1 $DATA  N2 N3\" '$FAKE_START_LOG'"

# --- bad input (2) ---
fresh bad
expect usage_2 2 "usage" bash "$Q"
expect unknown_card_2 2 "no card" bash "$Q" "$P" N99
expect bad_id_2 2 "plain card id" bash "$Q" "$P" "N1;rm"
expect bad_project_2 2 "project file" bash "$Q" "$T/none.json" N1
expect unknown_option_2 2 "unknown option" bash "$Q" --bogus "$P" N1

finish
