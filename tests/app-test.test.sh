#!/usr/bin/env bash
# N122: scripts/app-test.sh takes the machine-wide slot, so only one test-host run goes at a time.
source "$(dirname "$0")/lib.sh"
# A packet that holds the slot exports TENTACL_SLOT_HELD to its build; the cases here start their own runs, so it must not leak in.
unset TENTACL_SLOT_HELD
T=$(mktemp -d /tmp/agent-panel-at.XXXXXX); trap 'rm -rf "$T"' EXIT
# a copy of the script in a throw-away tree (it works relative to its own folder), with a fake xcodegen and xcodebuild
mkdir -p "$T/scripts" "$T/app" "$T/bin"; cp "$ROOT/scripts/app-test.sh" "$ROOT/scripts/clean-test-prefs.sh" "$T/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xcodegen"
cat > "$T/bin/xcodebuild" <<XEOF
#!/bin/bash
if [ -n "\${FAKE_XCB_HANG:-}" ]; then   # the first FAKE_XCB_HANG runs: the host starts (under this run's derived data) and no test ever does
  n=\$(cat "$T/hangs" 2>/dev/null || echo 0)
  if [ "\$n" -lt "\$FAKE_XCB_HANG" ]; then
    echo \$((n + 1)) > "$T/hangs"; echo "hung run \$((n + 1))"
    bash -c 'while :; do sleep 1; done' "\$PWD/build/Build/Products/Debug/Tentacl Dev.app/Contents/MacOS/Tentacl Dev" & echo \$! > "$T/host.pid"
    exec sleep 300
  fi
fi
echo "\$@" > "$T/args"
if [ -n "\${FAKE_XCB_STALL:-}" ]; then echo "Test Case '-[Fake.SuiteTests testStuck]' started."; exec sleep 300; fi
echo "start \$\$" >> "$T/order"; sleep \${FAKE_XCB_SLEEP:-2}; echo "end \$\$" >> "$T/order"
if [ -n "\${FAKE_XCB_RESTART:-}" ]; then
  echo "Test Case '-[Fake.SuiteTests testBefore]' started."; echo "Test Case '-[Fake.SuiteTests testBefore]' passed (0.1 seconds)."
  echo "Test Case '-[Fake.SuiteTests testTheCulprit]' started."; echo "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches."
  echo "Test Case '-[Fake.SuiteTests testNext]' started."; echo "Test Case '-[Fake.SuiteTests testNext]' passed (0.1 seconds)."
fi
[ -n "\${FAKE_XCB_LEAK:-}" ] && echo x > "\$PREFS_DIR/agent-panel-tests-11111111-2222-3333-4444-555555555555.plist"
if [ -n "\${FAKE_XCB_FAIL:-}" ]; then
  echo "Test Case '-[Fake.SuiteTests testOk]' passed (0.1 seconds)."
  echo "/src/Foo.swift:42: error: -[Fake.SuiteTests testBroken] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")"
  echo "Test Case '-[Fake.SuiteTests testBroken]' failed (0.1 seconds)."
  echo "Executed 5 tests, with 1 test skipped and 1 failure (0 unexpected) in 0.3 seconds"; echo "** TEST FAILED **"; exit 65
fi
echo "Test Case '-[Fake.SuiteTests testOk]' passed (0.1 seconds)."
echo "Executed 1 tests, with 0 failures"; echo "** TEST SUCCEEDED **"
XEOF
chmod +x "$T/bin/xcodegen" "$T/bin/xcodebuild"; export PATH="$T/bin:$PATH"
export AGENT_PANEL_BUILD_ROOT="$T/build"; SLOT="$T/build/.build-slot"
A="$T/scripts/app-test.sh"
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }; bad() { echo "FAIL  $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# one run: passes, and the slot is released afterwards
expect single_run_0 0 "TEST SUCCEEDED" env FAKE_XCB_SLEEP=0 bash "$A"
[ ! -e "$SLOT" ] && ok slot_released_after_run || bad slot_released_after_run

# two runs started together run one after the other, and one of them says it waits
rm -f "$T/order"
bash "$A" > "$T/out1" 2>&1 & p1=$!
bash "$A" > "$T/out2" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
o=$(awk '{print $1}' "$T/order" | tr '\n' ' ')
[ "$r1$r2" = "00" ] && [ "$o" = "start end start end " ] && ok two_runs_one_after_the_other || bad two_runs_one_after_the_other "rc=$r1$r2 order=$o"
cat "$T/out1" "$T/out2" | grep -q "waiting for another test run to finish (pid [0-9]*, " && ok waiting_line_printed || bad waiting_line_printed
cat "$T/out1" "$T/out2" | grep -q "got the test slot after [0-9]*s" && ok got_slot_line_printed || bad got_slot_line_printed
[ ! -e "$SLOT" ] && ok slot_free_after_two_runs || bad slot_free_after_two_runs

# a slot held by a live process that never finishes: the wait ends with a clear message and a non-zero exit
sleep 300 & holder=$!  # a live process that is not our ancestor
mkdir -p "$SLOT"; echo $holder > "$SLOT/pid"; echo "review packet for T9" > "$SLOT/what"
expect wait_times_out_1 1 "waited" env AGENT_PANEL_SLOT_TIMEOUT=2 AGENT_PANEL_SLOT_POLL=1 bash "$A"
out=$(AGENT_PANEL_SLOT_TIMEOUT=1 AGENT_PANEL_SLOT_POLL=1 AGENT_PANEL_SLOT_HEARTBEAT=1 bash "$A" 2>&1)
printf '%s' "$out" | grep -q "review packet for T9" && ok waiting_line_names_the_owner || bad waiting_line_names_the_owner "$out"
[ -e "$SLOT" ] && ok foreign_slot_kept_on_timeout || bad foreign_slot_kept_on_timeout
printf '%s' "$out" | grep -q "still waiting for the test slot" && ok heartbeat_printed_while_waiting || bad heartbeat_printed_while_waiting "$out"
# the holder goes away while a run waits: the run takes the slot within a poll and says so
( AGENT_PANEL_SLOT_POLL=1 AGENT_PANEL_SLOT_HEARTBEAT=1 FAKE_XCB_SLEEP=0 bash "$A" > "$T/outw" 2>&1 ) & pw=$!
sleep 2; kill $holder 2>/dev/null; wait $pw; rcw=$?
[ "$rcw" = 0 ] && grep -q "got the test slot after" "$T/outw" && grep -q "TEST SUCCEEDED" "$T/outw" && ok freed_slot_taken_and_announced || bad freed_slot_taken_and_announced "rc=$rcw $(cat "$T/outw")"
rm -rf "$SLOT"

# a slot left by a dead process is taken over
( exit 0 ) & dead=$!; wait $dead; mkdir -p "$SLOT"; echo "$dead" > "$SLOT/pid"
expect dead_owner_taken_over_0 0 "TEST SUCCEEDED" env FAKE_XCB_SLEEP=0 bash "$A"

# the packet's own run (TENTACL_SLOT_HELD=1) does not wait for the slot its parent holds, and does not release it
mkdir -p "$SLOT"; echo $$ > "$SLOT/pid"
expect held_by_parent_does_not_wait_0 0 "TEST SUCCEEDED" env FAKE_XCB_SLEEP=0 TENTACL_SLOT_HELD=1 AGENT_PANEL_SLOT_TIMEOUT=1 bash "$A"
[ -e "$SLOT" ] && ok held_slot_not_released_by_child || bad held_slot_not_released_by_child
# an older packet holds the slot without TENTACL_SLOT_HELD: the owner is an ancestor, so the run neither waits nor releases it
rm -rf "$SLOT"; mkdir -p "$SLOT"; echo $$ > "$SLOT/pid"
expect ancestor_owner_does_not_wait_0 0 "TEST SUCCEEDED" env FAKE_XCB_SLEEP=0 AGENT_PANEL_SLOT_TIMEOUT=1 bash "$A"
[ "$(cat "$SLOT/pid" 2>/dev/null)" = "$$" ] && ok ancestor_slot_kept || bad ancestor_slot_kept
rm -rf "$SLOT"

# N126: a restarted runner names the test that was running when the host died (not the next one)
out=$(FAKE_XCB_RESTART=1 FAKE_XCB_SLEEP=0 bash "$A" 2>&1)
printf '%s' "$out" | grep -q "RUNNER RESTARTED" && ok restart_still_flagged || bad restart_still_flagged "$out"
printf '%s' "$out" | grep -q "last test started before the restart: Fake.SuiteTests.testTheCulprit" && ok restart_names_last_started_test || bad restart_names_last_started_test "$out"
printf '%s' "$out" | grep "last test started" | grep -q "testBefore\|testNext" && bad restart_does_not_name_finished_test "$out" || ok restart_does_not_name_finished_test

# N264: a test host that never connects is killed with its xcodebuild and the run is tried once more
rm -f "$T/hangs"; mkdir -p "$T/other"
bash -c 'while :; do sleep 1; done' "$T/other/build/Tentacl Dev" & decoy=$!   # another worktree's host: must survive
export TENTACL_HOST_HANG_SECONDS=2 TENTACL_HANG_POLL=1
out=$(FAKE_XCB_HANG=1 FAKE_XCB_SLEEP=0 bash "$A" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "TEST SUCCEEDED" && ok hung_host_retried_and_passes || bad hung_host_retried_and_passes "rc=$rc $out"
printf '%s' "$out" | grep -q "test runner never connected: no test started" && ok hang_retry_says_so || bad hang_retry_says_so "$out"
kill -0 "$(cat "$T/host.pid")" 2>/dev/null && bad hung_host_killed || ok hung_host_killed
kill -0 $decoy 2>/dev/null && ok watchdog_leaves_other_trees_alone || bad watchdog_leaves_other_trees_alone
rm -f "$T/hangs"
out=$(FAKE_XCB_HANG=2 FAKE_XCB_SLEEP=0 bash "$A" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "test runner never connected, twice" && ok second_hang_fails_with_message || bad second_hang_fails_with_message "rc=$rc $out"
kill -0 "$(cat "$T/host.pid")" 2>/dev/null && bad second_hung_host_killed || ok second_hung_host_killed
kill -0 $decoy 2>/dev/null && ok decoy_alive_after_second_hang || bad decoy_alive_after_second_hang
# a slow but connected run (tests started) is never killed by the watchdog
out=$(FAKE_XCB_RESTART= FAKE_XCB_SLEEP=3 bash "$A" 2>&1); rc=$?
[ "$rc" = 0 ] && ok slow_run_without_host_untouched || bad slow_run_without_host_untouched "rc=$rc $out"
kill $decoy 2>/dev/null; rm -f "$T/hangs"; unset TENTACL_HOST_HANG_SECONDS TENTACL_HANG_POLL

# N338: the per-test timeout flags are passed; a run with no test start/end for the stall limit is killed and names the last test
FAKE_XCB_SLEEP=0 bash "$A" >/dev/null 2>&1
grep -q -- "-test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 300" "$T/args" && ok timeout_flags_passed || bad timeout_flags_passed "$(cat "$T/args")"
out=$(FAKE_XCB_STALL=1 TENTACL_STALL_SECONDS=2 TENTACL_HANG_POLL=1 bash "$A" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "stalled after Fake.SuiteTests.testStuck" && ok stalled_run_killed_and_named || bad stalled_run_killed_and_named "rc=$rc $out"
[ ! -e "$SLOT" ] && ok slot_free_after_stall || bad slot_free_after_stall

# N190: a run that adds a test preference file fails; a clean run does not
mkdir -p "$T/prefs"; export PREFS_DIR="$T/prefs"
expect clean_run_adds_no_prefs 0 "TEST SUCCEEDED" env FAKE_XCB_SLEEP=0 bash "$A"
expect leaked_pref_fails_the_run 1 "TEST LEFTOVERS" env FAKE_XCB_SLEEP=0 FAKE_XCB_LEAK=1 bash "$A"
# N277: the terminal gets a short summary; --verbose keeps the per-test lines; the full log is on disk
out=$(FAKE_XCB_SLEEP=0 bash "$A" 2>&1)
printf '%s' "$out" | grep -q "tests: run 1 · failed 0 · skipped 0" && ok summary_totals_on_pass || bad summary_totals_on_pass "$out"
printf '%s' "$out" | grep -q "passed  Fake" && bad summary_hides_passed_tests "$out" || ok summary_hides_passed_tests
printf '%s' "$out" | grep -q "log: .*/app/build/test.log" && ok summary_names_log || bad summary_names_log "$out"
out=$(FAKE_XCB_FAIL=1 FAKE_XCB_SLEEP=0 bash "$A" 2>&1); rc=$?
[ "$rc" -eq 65 ] && ok failing_exit_code_kept || bad failing_exit_code_kept "rc=$rc"
for n in "TEST FAILED" "run 5 · failed 1 · skipped 1" "failed  Fake.SuiteTests.testBroken" "/src/Foo.swift:42: error:"; do
  printf '%s' "$out" | grep -qF "$n" && ok "failing_summary_has_$n" || bad "failing_summary_has_$n" "$out"
done
grep -q "testOk" "$T/app/build/test.log" && ok full_log_on_disk || bad full_log_on_disk
out=$(FAKE_XCB_SLEEP=0 bash "$A" --verbose 2>&1)
printf '%s' "$out" | grep -q "passed  Fake.SuiteTests.testOk" && ok verbose_keeps_per_test_lines || bad verbose_keeps_per_test_lines "$out"
finish
