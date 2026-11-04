#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
I="$ROOT/install.sh"
T=$(mktemp -d /tmp/agent-panel-inst.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }; no() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
export HOME="$T/home"; mkdir -p "$HOME"   # never the real home
# fake release v1.0 served from a folder through file://
R="$T/rel/releases/download/v1.0"; mkdir -p "$R" "$T/pkg/Tentacl.app/Contents"; echo new > "$T/pkg/Tentacl.app/Contents/marker"
( cd "$T/pkg" && ditto -c -k --keepParent Tentacl.app "$R/TentaclCrew-1.0.zip" )
echo '#!/bin/sh' > "$R/install.sh"
( cd "$R" && shasum -a 256 TentaclCrew-1.0.zip install.sh > SHA256SUMS )
echo '{"tag_name": "v1.0"}' > "$T/latest.json"
export TENTACL_INSTALL_BASE="file://$T/rel" TENTACL_INSTALL_API="file://$T/latest.json"
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/codesign"; chmod +x "$T/bin/codesign"
export TENTACL_INSTALL_TTY=/dev/null   # never ask the real terminal
D="$T/apps"; run() { PATH="$T/bin:$PATH" bash "$I" --dir "$D" "$@" </dev/null; }

expect install_latest_0 0 "Open Anyway" run
run | grep -qi "right-click" && no no_right_click_text || ok no_right_click_text
[ "$(cat "$D/Tentacl.app/Contents/marker")" = new ] && ok app_installed || no app_installed
expect install_explicit_version_0 0 "Installed" run --version v1.0
expect bad_tag_1 1 "not a release tag" run --version main

# bad checksum: nothing changes, old app stays
echo old > "$D/Tentacl.app/Contents/marker"
echo "0000  TentaclCrew-1.0.zip" > "$R/SHA256SUMS.bad"; cp "$R/SHA256SUMS" "$T/sums.good"; cp "$R/SHA256SUMS.bad" "$R/SHA256SUMS"
expect bad_checksum_1 1 "checksum mismatch" run
[ "$(cat "$D/Tentacl.app/Contents/marker")" = old ] && ok bad_checksum_keeps_old || no bad_checksum_keeps_old
cp "$T/sums.good" "$R/SHA256SUMS"

# failing signature check: old app stays, no leftovers
printf '#!/bin/sh\nexit 1\n' > "$T/bin/codesign"
expect bad_signature_1 1 "signature" run
[ "$(cat "$D/Tentacl.app/Contents/marker")" = old ] && ! ls "$D" | grep -q old\\. && ok bad_signature_keeps_old || no bad_signature_keeps_old
printf '#!/bin/sh\nexit 0\n' > "$T/bin/codesign"

# install failure after the old app was moved aside restores it
mkdir "$T/fake"; printf '#!/bin/sh\n[ "$1" = -x ] && exec /usr/bin/ditto "$@"\nexit 1\n' > "$T/fake/ditto"; chmod +x "$T/fake/ditto"
PATH="$T/fake:$T/bin:$PATH" bash "$I" --dir "$D" </dev/null >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$D/Tentacl.app/Contents/marker")" = old ] && ok failed_install_restores_old || no failed_install_restores_old

# --open: opens the app after success, and the old one after a failure
printf '#!/bin/sh\necho "$1" >> "%s/opened"\n' "$T" > "$T/bin/open"; chmod +x "$T/bin/open"
run --open >/dev/null 2>&1; grep -qx "$D/Tentacl.app" "$T/opened" && ok open_after_install || no open_after_install
rm -f "$T/opened"; run >/dev/null 2>&1; [ ! -e "$T/opened" ] && ok no_open_without_flag || no no_open_without_flag
rm -f "$T/opened"; PATH="$T/fake:$T/bin:$PATH" bash "$I" --dir "$D" --open </dev/null >/dev/null 2>&1
grep -qx "$D/Tentacl.app" "$T/opened" && ok open_old_after_failed_install || no open_old_after_failed_install
rm -f "$T/opened" "$T/bin/open"

# old macOS
printf '#!/bin/sh\necho 13.6\n' > "$T/bin/sw_vers"; chmod +x "$T/bin/sw_vers"
expect old_macos_1 1 "macOS 14" run
rm "$T/bin/sw_vers"

# a running copy is not quit on a pipe
mkdir -p "$D/Tentacl.app/Contents/MacOS"; printf '#!/bin/sh\nsleep 30\n' > "$D/Tentacl.app/Contents/MacOS/Tentacl"; chmod +x "$D/Tentacl.app/Contents/MacOS/Tentacl"; "$D/Tentacl.app/Contents/MacOS/Tentacl" 30 & rp=$!
sleep 0.3; expect running_not_quit_1 1 "quit it" run
kill -0 $rp 2>/dev/null && ok running_app_still_running || no running_app_still_running
pkill -f "$D/Tentacl.app/Contents/MacOS" 2>/dev/null; wait 2>/dev/null

# ask via a tty file (test seam): y quits the running app, n stops, no tty stops
mkdir -p "$D/Tentacl.app/Contents/MacOS"; printf '#!/bin/sh\nsleep 30\n' > "$D/Tentacl.app/Contents/MacOS/Tentacl"; chmod +x "$D/Tentacl.app/Contents/MacOS/Tentacl"
"$D/Tentacl.app/Contents/MacOS/Tentacl" & rp=$!; sleep 0.3
echo n > "$T/tty"; TENTACL_INSTALL_TTY="$T/tty" expect ask_no_stops_1 1 "quit it" run
kill -0 $rp 2>/dev/null && ok ask_no_keeps_running || no ask_no_keeps_running
TENTACL_INSTALL_TTY="$T/none" expect ask_no_tty_stops_1 1 "quit it" run
echo y > "$T/tty"; TENTACL_INSTALL_TTY="$T/tty" expect ask_yes_installs_0 0 "Installed" run
sleep 0.5; kill -0 $rp 2>/dev/null && no ask_yes_quits_app || ok ask_yes_quits_app
wait 2>/dev/null

# uninstall / purge
mkdir -p "$HOME/.config/tentacl" "$HOME/Library/Application Support/Tentacl"
expect purge_asks_1_keeps_data_0 0 "Kept your data" run --uninstall --purge
[ ! -e "$D/Tentacl.app" ] && [ -d "$HOME/.config/tentacl" ] && ok uninstall_removes_app_purge_keeps_data || no uninstall_removes_app_purge_keeps_data
expect purge_yes_0 0 "Removed." run --uninstall --purge --yes
[ ! -e "$HOME/.config/tentacl" ] && [ ! -e "$HOME/Library/Application Support/Tentacl" ] && ok purge_removed_data || no purge_removed_data

# a truncated script does nothing (cut before the last line; cut in the middle)
rm -rf "$D"
sed '$d' "$I" > "$T/cut1.sh"; head -c 2000 "$I" > "$T/cut2.sh"
for c in cut1 cut2; do PATH="$T/bin:$PATH" bash "$T/$c.sh" --dir "$D" </dev/null >/dev/null 2>&1; [ ! -e "$D" ] && ok "truncated_${c}_does_nothing" || no "truncated_${c}_does_nothing"; done
[ "$(tail -n 1 "$I")" = 'main "$@"' ] && ok main_called_on_last_line || no main_called_on_last_line
! grep -q 'sudo\|xattr' "$I" && ok no_sudo_no_quarantine_removal || no no_sudo_no_quarantine_removal
command -v shellcheck >/dev/null && { shellcheck "$I" && ok shellcheck_clean || no shellcheck_clean; }
finish
