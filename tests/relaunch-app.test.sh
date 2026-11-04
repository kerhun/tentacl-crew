#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/relaunch-app.sh"
T=$(mktemp -d /tmp/agent-panel-relaunch.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
# a fake `open` that records its arguments
mkdir -p "$T/bin" "$T/Tentacl.app"
printf '#!/bin/sh\necho "$@" >> "%s/opened"\n' "$T" > "$T/bin/open"; chmod +x "$T/bin/open"
export PATH="$T/bin:$PATH"

expect missing_app_1 1 "not found" bash "$S" "$T/Nope.app" 1
[ ! -e "$T/opened" ] && ok missing_app_opens_nothing || no missing_app_opens_nothing "$(cat "$T/opened")"
expect missing_args_2 2 "usage" bash "$S"
expect bad_pid_2 2 "usage" bash "$S" "$T/Tentacl.app" abc

# waits until the pid is gone, then opens the app once
sleep 2 & pid=$!
start=$(date +%s)
bash "$S" "$T/Tentacl.app" "$pid"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 0 ] && ok waits_then_exit_0 || no waits_then_exit_0 "exit $rc"
kill -0 "$pid" 2>/dev/null && no pid_gone_before_open "still alive" || ok pid_gone_before_open
[ "$elapsed" -ge 1 ] && ok waited_for_the_pid || no waited_for_the_pid "elapsed ${elapsed}s"
[ "$(cat "$T/opened")" = "$T/Tentacl.app" ] && ok opened_once_with_the_app || no opened_once_with_the_app "$(cat "$T/opened")"

# a pid that never exits: gives up waiting after the limit, still opens once
rm -f "$T/opened"; sleep 20 & stuck=$!
RELAUNCH_WAIT_SECS=1 bash "$S" "$T/Tentacl.app" "$stuck"; rc=$?
kill "$stuck" 2>/dev/null
[ "$rc" -eq 0 ] && [ "$(wc -l < "$T/opened" | tr -d ' ')" = 1 ] && ok wait_limit_then_opens_once || no wait_limit_then_opens_once "exit $rc"
finish
