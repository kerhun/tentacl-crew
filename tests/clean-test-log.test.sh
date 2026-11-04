#!/usr/bin/env bash
# N221: scripts/clean-test-log.sh removes only the known test lines, and only with --apply, after a backup.
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/clean-test-log.sh"
T=$(mktemp -d /tmp/agent-panel-ctl.XXXXXX); trap 'rm -rf "$T"' EXIT
L="$T/actions.log"; SHA=0123456789abcdef0123456789abcdef01234567
cat > "$L" <<LOG
2026-10-17T20:08:57Z answered B1 (w2:p1)
2026-10-17T20:09:00Z answered B1 (w2:pA)
2026-10-17T20:09:34Z approved N31
2026-10-19T00:24:19Z [recipe-box] merged T1 $SHA (script)
2026-10-20T21:09:45Z [tmp] merged T1 $SHA (script)
2026-10-20T21:10:00Z merged T1 $SHA (script)
2026-10-20T21:11:00Z [agent-panel] merged N106 $SHA (script)
2026-10-20T21:12:00Z merged T1 $SHA (script) extra
2026-10-20T21:13:00Z [agent-panel] command to w2:pB: answered B1 (w2:p1)
2026-10-20T21:14:00Z start T1 agent=dev-t1 branch=task/t1 pane=w2K:p1
LOG
cp "$L" "$T/orig"
expect "dry run counts the matching lines" 0 "total                   4  of 10 lines" "$S" "$L"
expect "dry run says it wrote nothing" 0 "dry run: nothing written" "$S" "$L"
cmp -s "$L" "$T/orig" && [ -z "$(ls "$T" | grep bak)" ] && { echo "PASS  dry run changes nothing and makes no backup"; PASS=$((PASS+1)); } || { echo "FAIL  dry run changed something"; FAIL=$((FAIL+1)); }
expect "missing file fails" 2 "no such file" "$S" "$T/nope"
expect "unknown flag fails" 2 "unknown argument" "$S" "$L" --nope

expect "--apply backs up and removes" 0 "removed 4 lines" "$S" --apply "$L"
bak=$(ls "$T"/actions.log.bak-* 2>/dev/null | head -1)
[ -n "$bak" ] && cmp -s "$bak" "$T/orig" && { echo "PASS  the backup is the untouched original"; PASS=$((PASS+1)); } || { echo "FAIL  backup missing or changed"; FAIL=$((FAIL+1)); }
[ "$(wc -l < "$L" | tr -d ' ')" = 6 ] && ! grep -q 'answered B1 (w2:p1)$' <(grep -v command "$L") && ! grep -qE '(\[tmp\] |\[recipe-box\] |Z )merged T1 [0-9a-f]{40} \(script\)$' "$L" \
  && { echo "PASS  only the 4 matching lines are gone"; PASS=$((PASS+1)); } || { echo "FAIL  wrong lines left:"; cat "$L"; FAIL=$((FAIL+1)); }
for k in "answered B1 (w2:pA)" "approved N31" "merged N106" "(script) extra" "command to w2:pB" "start T1"; do
  grep -qF "$k" "$L" || { echo "FAIL  lost a non-test line: $k"; FAIL=$((FAIL+1)); continue; }
done
echo "PASS  lines that do not clearly match stay"; PASS=$((PASS+1))
[ -z "$(ls "$T" | grep -v -e actions.log -e orig)" ] && { echo "PASS  no temp file left behind"; PASS=$((PASS+1)); } || { echo "FAIL  stray files: $(ls "$T")"; FAIL=$((FAIL+1)); }
cp "$L" "$T/after1"
expect "a second run finds nothing" 0 "nothing to remove" "$S" --apply "$L"
cmp -s "$L" "$T/after1" && { echo "PASS  second run leaves the log as it was"; PASS=$((PASS+1)); } || { echo "FAIL  second run changed the log"; FAIL=$((FAIL+1)); }
finish
