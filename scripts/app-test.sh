#!/usr/bin/env bash
# Runs the AgentPanel unit tests and prints a short summary (full log: app/$DD/test.log, default app/build/test.log).
# Usage: scripts/app-test.sh [extra xcodebuild args, e.g. -only-testing:AgentPanelTests/CardParserTests]
# Env: TENTACL_DD = derived-data folder under app/ (default "build"). A review build uses another one (build/review) so it never collides
#      with the tests an agent runs in the same worktree at the same time.
#      TENTACL_REPEAT = N runs the whole suite N times (logs test.log.1 .. test.log.N); the summary then lists every test that failed in
#      at least one run, so a new test can be checked for flakiness. The exit code is non-zero if any run failed.
#      One test-host run at a time on the machine (N122): two runs of the same test host app ("Tentacl Dev") at once make a running one
#      restart. The xcodebuild part waits for the machine-wide slot <build root>/.build-slot (AGENT_PANEL_BUILD_ROOT, default
#      ~/.cache/agent-panel/build; the review packet uses the same one). AGENT_PANEL_SLOT_TIMEOUT (seconds, default 2700) and
#      AGENT_PANEL_SLOT_POLL (seconds, default 5) set how long and how often. A waiting run prints a line every
#      AGENT_PANEL_SLOT_HEARTBEAT seconds (default 60) and ends with "got the test slot after Ns" or the timeout line (N320). TENTACL_SLOT_HELD=1 (set by review-packet.sh) means the
#      caller already holds the slot: no wait, no release.
#      TENTACL_PARALLEL = 1 runs the test classes in parallel clones (a different order and timing than the default serial run).
#      Hung test host watchdog (N264): when the test host ("Tentacl Dev" under this run's derived-data folder) has been up for
#      TENTACL_HOST_HANG_SECONDS (default 480 = 8 min) and no test has started, this run's xcodebuild and every process whose command
#      line is under the derived-data folder are killed and the run is tried once more; a second hang fails with "test runner never
#      connected, twice". Nothing outside the derived-data folder (the real app, another worktree's run) is touched.
#      TENTACL_HANG_POLL (seconds, default 5) is how often it looks.
#      Per-test limit (N338): xcodebuild runs with test timeouts on: TENTACL_TEST_ALLOWANCE (default 120 s) per test, at most
#      TENTACL_TEST_MAX_ALLOWANCE (default 300 s) for a test that sets its own executionTimeAllowance. A test over it fails by name; the run goes on.
#      No-progress watchdog (N338): once tests run, if no test starts or ends for TENTACL_STALL_SECONDS (default 600 = 10 min) the run is
#      killed like the host hang ("stalled after <last test>", no retry) so a stuck test never holds the build slot for hours.
#      --verbose (first-class flag, not passed on to xcodebuild) prints the long per-test summary; without it the terminal gets only the
#      result, totals, failed tests with their failure lines, compile errors and the log path (N277). The full log is always written.
# A restarted test host names the last test that started before it and any crash report or exit line (the test after it only shows who ran next).
# The summary keeps every failure, crash and test-runner restart line, and the raw log lines around them.
set -u
verbose=""; args=(); for a in "$@"; do if [ "$a" = "--verbose" ]; then verbose=1; else args+=("$a"); fi; done
set -- ${args[@]+"${args[@]}"}
cd "$(dirname "$0")/../app" || exit 2
app_dir=$PWD
xcodegen generate >/dev/null 2>&1 || { echo "xcodegen failed"; exit 2; }
DD=${TENTACL_DD:-build}
mkdir -p "$DD"
REPEAT=${TENTACL_REPEAT:-1}
case "$REPEAT" in ''|*[!0-9]*|0) echo "TENTACL_REPEAT must be a positive number"; exit 2 ;; esac
extra=(-test-timeouts-enabled YES -default-test-execution-time-allowance "${TENTACL_TEST_ALLOWANCE:-120}" -maximum-test-execution-time-allowance "${TENTACL_TEST_MAX_ALLOWANCE:-300}")
[ "${TENTACL_PARALLEL:-0}" = "1" ] && extra+=(-parallel-testing-enabled YES)

# The machine-wide slot: a folder with the pid of its owner (and what it runs); a slot whose process is gone is taken over.
# The whole xcodebuild part (build and tests) is inside it: splitting the build out would change what a run is.
slot="${AGENT_PANEL_BUILD_ROOT:-$HOME/.cache/agent-panel/build}/.build-slot"; have_slot=""
release_slot() { [ -z "$have_slot" ] || rm -rf "$slot"; }
trap release_slot EXIT
if [ "${TENTACL_SLOT_HELD:-}" != "1" ]; then
  mkdir -p "$(dirname "$slot")" || { echo "could not create $(dirname "$slot")"; exit 2; }
  slot_timeout=${AGENT_PANEL_SLOT_TIMEOUT:-2700}; slot_poll=${AGENT_PANEL_SLOT_POLL:-5}; waited=0; told=""
  until mkdir "$slot" 2>/dev/null; do
    owner=$(cat "$slot/pid" 2>/dev/null); what=$(cat "$slot/what" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      mv "$slot" "$slot.stale.$$" 2>/dev/null && rm -rf "$slot.stale.$$"; continue
    fi
    # A packet from an older review-packet.sh holds the slot without passing TENTACL_SLOT_HELD: the owner is our own ancestor, so
    # it is already ours (waiting would deadlock until the timeout).
    a=$PPID; while [ -n "$owner" ] && [ "${a:-1}" -gt 1 ] && [ "$a" != "$owner" ]; do a=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' '); done
    [ -n "$owner" ] && [ "$a" = "$owner" ] && { by_ancestor=1; break; }
    if [ "$waited" -ge "$slot_timeout" ]; then
      echo "waited $((waited / 60)) min for another test run to finish (pid ${owner:-unknown}, ${what:-unknown}); run the tests again later"; exit 1
    fi
    [ -n "$told" ] || { echo "waiting for another test run to finish (pid ${owner:-unknown}, ${what:-unknown})..."; told=1; }
    sleep "$slot_poll"; waited=$((waited + slot_poll))
    # a heartbeat, so a waiting run is never silent (N320)
    [ $((waited % ${AGENT_PANEL_SLOT_HEARTBEAT:-60})) -lt "$slot_poll" ] && echo "still waiting for the test slot (${waited}s, held by pid ${owner:-unknown}, ${what:-unknown})..."
  done
  [ -z "$told" ] || echo "got the test slot after ${waited}s; running the tests now"
  [ -n "${by_ancestor:-}" ] || { echo $$ > "$slot/pid"; echo "app-test.sh in ${app_dir%/app}" > "$slot/what"; have_slot=1; }
fi

# Lines that mean "something went wrong", in any format xcodebuild or the test runner uses.
BAD='error:|\*\* TEST FAILED \*\*|\bfailed\b|[1-9][0-9]* failures|[1-9][0-9]* unexpected|[Cc]rash|Restarting after|unexpected exit|Testing failed|Failing tests|signal [0-9]+|Test runner|test runner|Fatal error|Assertion failed'

summarize() { # $1 = log file
  grep -E "^Test Case .* (passed|failed)|error:|\*\* TEST (SUCCEEDED|FAILED) \*\*|Executed [0-9]+ tests" "$1" | grep -v "Connection" \
    | sed -E "s/^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' (passed|failed).*/\3  \1.\2/" | sort -u
  grep -E "^Test case '.*' failed on" "$1" | sed -E "s/^Test case '([A-Za-z0-9_.]+)\(\)' failed.*/failed  \1/" | sort -u
  # failures, crashes and restarts in any other format, each with 2 raw lines of context before it and 2 after
  grep -n -E "$BAD" "$1" | grep -vE 'warning:|^[0-9]+:Test [Cc]ase .* (started|passed)|^[0-9]+:Test [Ss]uite .* (started|passed)|^[0-9]+:[ |]*[`|]|^[0-9]+:Test Case .* passed|Connection' | cut -d: -f1 | while read -r n; do
    s=$((n > 2 ? n - 2 : 1)); sed -n "${s},$((n + 2))p" "$1"; echo "--"
  done | sed 's/^/RAW  /'
}

# The short summary (N277): result line, totals, failed tests, error lines (compile errors and failure lines with file:line), log path.
compact() { # $1 = log file
  local t run fail skip
  t=$(grep -E 'Executed [0-9]+ tests?, with' "$1" | tail -n 1)
  run=$(printf '%s' "$t" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p'); fail=$(printf '%s' "$t" | sed -nE 's/.* ([0-9]+) failures?.*/\1/p')
  skip=$(printf '%s' "$t" | sed -nE 's/.* ([0-9]+) tests? skipped.*/\1/p')
  grep -E '\*\* (TEST|BUILD) (SUCCEEDED|FAILED) \*\*' "$1" | tail -n 1
  echo "tests: run ${run:-?} · failed ${fail:-?} · skipped ${skip:-0}"
  { grep -E "^Test Case .* failed" "$1" | sed -E "s/^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' failed.*/\1.\2/"
    grep -E "^Test case '.*' failed on" "$1" | sed -E "s/^Test case '([A-Za-z0-9_.]+)\(\)' failed.*/\1/"; } | awk '!s[$0]++' | sed 's/^/failed  /'
  grep -E ':[0-9]+(:[0-9]+)?: error:|^error:' "$1" | awk '!s[$0]++' | head -n 30
  grep -n -E "$BAD" "$1" | grep -vE 'warning:|error:|^[0-9]+:Test [Cc]ase |^[0-9]+:Test [Ss]uite |^[0-9]+:[ |]*[`|]|Connection|\*\* TEST|^[0-9]+:.*Executed [0-9]+ tests' | cut -d: -f1 | head -n 5 | while read -r n; do
    s=$((n > 2 ? n - 2 : 1)); sed -n "${s},$((n + 2))p" "$1"; echo "--"
  done | sed 's/^/RAW  /'
  echo "log: $app_dir/$1"
}
summary() { if [ -n "$verbose" ]; then summarize "$1"; else compact "$1"; fi; }

# The test that was running when the host died is the last "started" line before each restart (the next test only shows who came after),
# plus the crash report the host left, if any (N126).
restart_culprit() { # $1 = log file
  awk '/^Test [Cc]ase .* started/ { last = $0; sub(/^Test [Cc]ase .-\[/, "", last); sub(/\]. started.*/, "", last); sub(/ /, ".", last) }
       /Restarting after unexpected exit/ { print "last test started before the restart: " last }' "$1"
  grep -E "Crash: |Exited with signal|exited unexpectedly|Test crashed|signal [0-9]+|timed out|Test runner" "$1" | grep -v "^Test Case" | sort -u | head -5 | sed 's/^/  host exit: /'
  local r; r=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Tentacl Dev*.ips' -newer "$1.start" 2>/dev/null | head -3)
  [ -n "$r" ] && printf '%s\n' "$r" | sed 's/^/  crash report: /'
}

# Test leftovers (N190): a run must add no preference file of the kinds scripts/clean-test-prefs.sh lists (PREFS_DIR overrides the folder).
prefs_count() { "$app_dir/../scripts/clean-test-prefs.sh" --list 2>/dev/null | wc -l | tr -d ' '; }
prefs_before=$(prefs_count)

# The hung-host watchdog: only processes whose command line contains this run's derived-data folder are ever killed.
case "$DD" in /*) abs_dd=$DD ;; *) abs_dd="$app_dir/$DD" ;; esac
hang_limit=${TENTACL_HOST_HANG_SECONDS:-480}; hang_poll=${TENTACL_HANG_POLL:-5}; stall_limit=${TENTACL_STALL_SECONDS:-600}
kill_run_tree() { # $1 = xcodebuild pid
  local pids; pids=$(pgrep -f "$abs_dd/" 2>/dev/null | grep -vx "$$")
  kill "$1" $pids 2>/dev/null; sleep 2; kill -9 "$1" $pids 2>/dev/null
  return 0
}

rc=0; failed_any=""
for i in $(seq 1 "$REPEAT"); do
  log="$DD/test.log"; [ "$REPEAT" -gt 1 ] && log="$DD/test.log.$i"
  : > "$log.start"
  hung_runs=0
  while :; do
    xcodebuild test -skipPackagePluginValidation -project AgentPanel.xcodeproj -scheme AgentPanel -destination 'platform=macOS' -derivedDataPath "$DD" ${extra[@]+"${extra[@]}"} "$@" > "$log" 2>&1 &
    xpid=$!; host_since=""; started=""; hung=""; stalled=""; seen=0; seen_at=$SECONDS
    while kill -0 "$xpid" 2>/dev/null; do
      sleep "$hang_poll"
      if [ -n "$started" ]; then   # N338: any test start/end counts as progress
        n=$(grep -cE '^Test [Cc]ase .* (started|passed|failed)' "$log" 2>/dev/null)
        if [ "${n:-0}" != "$seen" ]; then seen=${n:-0}; seen_at=$SECONDS
        elif [ $((SECONDS - seen_at)) -ge "$stall_limit" ]; then stalled=1; break; fi
        continue
      fi
      if grep -qE '^Test [Cc]ase .* started' "$log" 2>/dev/null; then started=1; continue; fi
      if [ -n "$(pgrep -f "$abs_dd/.*Tentacl Dev" 2>/dev/null)" ]; then
        [ -n "$host_since" ] || host_since=$SECONDS
        [ $((SECONDS - host_since)) -ge "$hang_limit" ] && { hung=1; break; }
      fi
    done
    if [ -n "$stalled" ]; then
      kill_run_tree "$xpid"; wait "$xpid" 2>/dev/null
      last=$(grep -E '^Test [Cc]ase .* started' "$log" | tail -n 1 | sed -E "s/^Test [Cc]ase '-?\[?([A-Za-z0-9_.]+)[ .]([A-Za-z0-9_]+)\]?(\(\))?' started.*/\1.\2/")
      echo "stalled after ${last:-unknown}: no test started or ended for $stall_limit s; killed the run and its host to free the slot ($log)"; r=1; break
    fi
    if [ -n "$hung" ]; then
      kill_run_tree "$xpid"; wait "$xpid" 2>/dev/null
      hung_runs=$((hung_runs + 1))
      if [ "$hung_runs" -ge 2 ]; then
        echo "test runner never connected, twice: no test started $hang_limit s after the test host launched, in two runs ($log, $log.hung)"; r=1; break
      fi
      echo "test runner never connected: no test started $hang_limit s after the test host launched; killed it and the host, trying once more"
      mv "$log" "$log.hung"; : > "$log.start"; continue
    fi
    wait "$xpid"; r=$?; break
  done
  [ "$r" -ne 0 ] && rc=$r
  # "** TEST FAILED **" with no failed test line (a crash, a restart) still counts as failed
  if [ "$r" -eq 0 ] && grep -q "\*\* TEST FAILED \*\*" "$log"; then rc=1; fi
  # a restarted test runner (crash, kill, hang) is never a pass, even when every test that ran later passed (N116)
  if grep -q "Restarting after unexpected exit" "$log"; then
    echo "RUNNER RESTARTED in $log: the test host crashed or was killed; investigate, do not rerun and ignore"; [ "$rc" -eq 0 ] && rc=1
    restart_culprit "$log"
  fi
  rm -f "$log.start"
  if [ "$REPEAT" -gt 1 ]; then
    echo "=== run $i of $REPEAT (exit $r)"
    summary "$log" | grep -vE "^passed " | grep -vE "Executed [0-9]+ tests, with 0 failures"
    failed_any="$failed_any
$({ grep -E "^Test Case .* failed" "$log" | sed -E "s/^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' failed.*/\1.\2/"; grep -E "^Test case '.*' failed on" "$log" | sed -E "s/^Test case '([A-Za-z0-9_.]+)\(\)' failed.*/\1/"; })"
  else
    summary "$log"
  fi
done
if [ "$REPEAT" -gt 1 ]; then
  echo "=== failed in at least one of $REPEAT runs:"
  list=$(printf '%s\n' "$failed_any" | sed '/^$/d' | sort | uniq -c | sort -rn)
  [ -n "$list" ] && echo "$list" || echo "(none)"
  # keep the last run's log at the usual path
  cp "$DD/test.log.$REPEAT" "$DD/test.log"
fi
prefs_after=$(prefs_count)
if [ "$prefs_after" -gt "$prefs_before" ]; then
  echo "TEST LEFTOVERS: the run added $((prefs_after - prefs_before)) preference file(s) of the test kinds to ~/Library/Preferences ($prefs_before -> $prefs_after); a test bypasses TestDefaults"; [ "$rc" -eq 0 ] && rc=1
fi
exit $rc
