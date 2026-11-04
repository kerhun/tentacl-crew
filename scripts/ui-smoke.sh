#!/usr/bin/env bash
# UI smoke test: launches the Dev app in its isolated UI-test mode and opens every screen of the rail (app/AgentPanelUITests).
# Prints a short summary (full log: app/$DD/ui-smoke.log, default app/build/ui-smoke.log). Not part of app-test.sh or the review packet.
# Usage: scripts/ui-smoke.sh [extra xcodebuild args, e.g. -only-testing:AgentPanelUITests/ScreenSmokeTests/testGit]
# Env: TENTACL_DD = derived-data folder under app/ (default "build"). The xcodebuild part waits for the same machine-wide slot as
#      app-test.sh (<build root>/.build-slot, AGENT_PANEL_BUILD_ROOT, AGENT_PANEL_SLOT_TIMEOUT, AGENT_PANEL_SLOT_POLL);
#      TENTACL_SLOT_HELD=1 means the caller already holds it.
# The first run may need the macOS permission for the test runner to control the app (Accessibility / Automation); the script does not
# grant it. A run that stops on that says so ("UI TESTING PERMISSION").
set -u
cd "$(dirname "$0")/../app" || exit 2
app_dir=$PWD
xcodegen generate >/dev/null 2>&1 || { echo "xcodegen failed"; exit 2; }
DD=${TENTACL_DD:-build}
mkdir -p "$DD"

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
    a=$PPID; while [ -n "$owner" ] && [ "${a:-1}" -gt 1 ] && [ "$a" != "$owner" ]; do a=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' '); done
    [ -n "$owner" ] && [ "$a" = "$owner" ] && { by_ancestor=1; break; }
    if [ "$waited" -ge "$slot_timeout" ]; then
      echo "waited $((waited / 60)) min for another test run to finish (pid ${owner:-unknown}, ${what:-unknown}); run again later"; exit 1
    fi
    [ -n "$told" ] || { echo "waiting for another test run to finish (pid ${owner:-unknown}, ${what:-unknown})..."; told=1; }
    sleep "$slot_poll"; waited=$((waited + slot_poll))
  done
  [ -n "${by_ancestor:-}" ] || { echo $$ > "$slot/pid"; echo "ui-smoke.sh in ${app_dir%/app}" > "$slot/what"; have_slot=1; }
fi

log="$DD/ui-smoke.log"
start=$SECONDS
xcodebuild test -skipPackagePluginValidation -project AgentPanel.xcodeproj -scheme AgentPanelUI -destination 'platform=macOS' -derivedDataPath "$DD" "$@" > "$log" 2>&1
r=$?
if [ "$r" -eq 0 ] && grep -q "\*\* TEST FAILED \*\*" "$log"; then r=1; fi
grep -E "^Test Case .* (passed|failed)|error:|\*\* TEST (SUCCEEDED|FAILED) \*\*|Executed [0-9]+ tests" "$log" \
  | sed -E "s/^Test Case '-\[([A-Za-z0-9_.]+) ([A-Za-z0-9_]+)\]' (passed|failed).*/\3  \1.\2/" | sort -u
if grep -qiE "not authorized to send Apple events|is not trusted|Failed to (initialize|get) .*(automation|accessib)|Timed out while enabling automation mode|Authorization (was )?denied|enable UI Automation" "$log"; then
  echo "UI TESTING PERMISSION: macOS did not let the test runner control the app; allow it in System Settings > Privacy & Security (Accessibility / Automation), then run again. See $log"
  [ "$r" -eq 0 ] && r=1
fi
echo "ui-smoke: $((SECONDS - start)) s, exit $r (log: app/$log)"
exit $r
