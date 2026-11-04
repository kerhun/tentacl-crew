#!/usr/bin/env bash
# N190: scripts/clean-test-prefs.sh removes only the known test preference files, and only with --apply, after a backup.
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/clean-test-prefs.sh"
T=$(mktemp -d /tmp/agent-panel-ctp.XXXXXX); trap 'rm -rf "$T"' EXIT
P="$T/prefs"; B="$T/backup"; mkdir -p "$P" "$T/bin"
U1=11111111-2222-3333-4444-555555555555; U2=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
mine=(agent-panel-tests-$U1 agent-panel-key-tests-$U1 agent-panel-tests-probe-$U1 finished-sort-tests-$U1 notes-pad-tests-$U1 mode-$U1 stats-range-$U1 RoundModelTests.$U2
      agent-panel-tests-host agent-panel-tests-git-suggestions agent-panel-scroll-tests finished-sort-tests)
keep=(agent-panel-demo com.apple.finder mode-not-a-uuid agent-panel-tests-$U1.bak agent-panel-tests-hostile agent-panel-tests com.example.mode-$U1 notes-pad-tests-$U1x)
for n in "${mine[@]}"; do echo x > "$P/$n.plist"; done
for n in "${keep[@]}"; do echo x > "$P/$n.plist"; done
echo x > "$P/agent-panel-tests-$U1.plist.lockfile"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pgrep"; chmod +x "$T/bin/pgrep"
export PATH="$T/bin:$PATH"
count() { ls "$P" | wc -l | tr -d ' '; }
total=$(count)

expect "dry run counts the matching files" 0 "12  0 MB on disk" "$S" --dir "$P"
expect "dry run says it deleted nothing" 0 "dry run: nothing deleted" "$S" --dir "$P" --backup-dir "$B"
[ "$(count)" = "$total" ] && [ ! -e "$B" ] && { echo "PASS  dry run changes nothing and makes no backup"; PASS=$((PASS+1)); } || { echo "FAIL  dry run changed something"; FAIL=$((FAIL+1)); }
n=$("$S" --dir "$P" --list | wc -l | tr -d ' '); [ "$n" = 12 ] && { echo "PASS  --list lists exactly the 12 names"; PASS=$((PASS+1)); } || { echo "FAIL  --list gave $n"; FAIL=$((FAIL+1)); }
expect "unknown folder fails" 2 "no such folder" "$S" --dir "$T/nope"

# refuses while xcodebuild tests run (fake pgrep finds one)
printf '#!/bin/sh\necho 123 xcodebuild test -scheme X\nexit 0\n' > "$T/bin/pgrep"
expect "--apply refuses while xcodebuild tests run" 1 "refusing" "$S" --apply --dir "$P" --backup-dir "$B"
[ "$(count)" = "$total" ] && { echo "PASS  nothing deleted when refused"; PASS=$((PASS+1)); } || { echo "FAIL  refused run deleted files"; FAIL=$((FAIL+1)); }
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pgrep"

expect "--apply backs up and removes" 0 "removed 12 files" "$S" --apply --dir "$P" --backup-dir "$B"
[ "$(count)" = "$((total - 12))" ] && { echo "PASS  only the 12 matching files are gone"; PASS=$((PASS+1)); } || { echo "FAIL  $(count) files left, expected $((total - 12))"; FAIL=$((FAIL+1)); }
left=0; for n in "${keep[@]}"; do [ -e "$P/$n.plist" ] || left=1; done; [ -e "$P/agent-panel-tests-$U1.plist.lockfile" ] || left=1
[ "$left" = 0 ] && { echo "PASS  every other file is still there (demo plist, other apps)"; PASS=$((PASS+1)); } || { echo "FAIL  a non-matching file was removed"; FAIL=$((FAIL+1)); }
tb=$(ls "$B"/prefs-backup-*.tar.gz 2>/dev/null | head -1)
if [ -n "$tb" ] && [ "$(tar -tzf "$tb" | wc -l | tr -d ' ')" = 12 ] && tar -tzf "$tb" | grep -q "agent-panel-tests-host.plist"; then
  echo "PASS  the backup holds exactly the 12 removed files"; PASS=$((PASS+1)); else echo "FAIL  backup missing or wrong"; FAIL=$((FAIL+1)); fi
expect "a second run finds nothing" 0 "nothing to remove" "$S" --apply --dir "$P" --backup-dir "$B"
finish
