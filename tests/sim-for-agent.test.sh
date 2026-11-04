#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
M="$ROOT/scripts/sim-for-agent.sh"; P="$ROOT/tests/fixtures/config/valid_project.json"
A1="aptest-$$-one"; A2="aptest-$$-two"
trap 'bash "$M" --remove "$A1" >/dev/null 2>&1; bash "$M" --remove "$A2" >/dev/null 2>&1' EXIT

is_udid() { [[ "$1" =~ ^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$ ]]; }
u1=$(bash "$M" "$A1" "$P" 2>/dev/null); u1b=$(bash "$M" "$A1" "$P" 2>/dev/null); u2=$(bash "$M" "$A2" "$P" 2>/dev/null)

if is_udid "$u1"; then echo "PASS  create_returns_udid_0"; PASS=$((PASS+1)); else echo "FAIL  create_returns_udid_0: got '$u1'"; FAIL=$((FAIL+1)); fi
if [ -n "$u1" ] && [ "$u1" = "$u1b" ]; then echo "PASS  same_agent_same_udid_0"; PASS=$((PASS+1)); else echo "FAIL  same_agent_same_udid_0: '$u1' vs '$u1b'"; FAIL=$((FAIL+1)); fi
if is_udid "$u2" && [ "$u1" != "$u2" ]; then echo "PASS  two_agents_different_udid_0"; PASS=$((PASS+1)); else echo "FAIL  two_agents_different_udid_0: '$u1' vs '$u2'"; FAIL=$((FAIL+1)); fi
expect remove_deletes_simulator_0 0 "" bash "$M" --remove "$A1"
if xcrun simctl list -j devices | jq -e --arg u "$u1" '[.devices[][] | select(.udid == $u)] | length == 0' >/dev/null; then echo "PASS  removed_simulator_is_gone"; PASS=$((PASS+1)); else echo "FAIL  removed_simulator_is_gone"; FAIL=$((FAIL+1)); fi
jq '.simulator.baseDevice="No Such Phone 99"' "$P" > "$ROOT/tests/fixtures/config/.tmp_bad_sim.json"
expect missing_base_device_clear_error_1 1 "base device" bash "$M" "$A1-x" "$ROOT/tests/fixtures/config/.tmp_bad_sim.json"
rm -f "$ROOT/tests/fixtures/config/.tmp_bad_sim.json"

# Runtimes sort by version, not as strings: iOS-26-10 is newer than iOS-26-2.
fake=$(mktemp -d); trap 'rm -rf "$fake"; bash "$M" --remove "$A1" >/dev/null 2>&1; bash "$M" --remove "$A2" >/dev/null 2>&1' EXIT
cat > "$fake/xcrun" <<'X'
#!/usr/bin/env bash
if [ "$1 $2" = "simctl list" ]; then
  cat <<'J'
{"devices":{
 "com.apple.CoreSimulator.SimRuntime.iOS-26-10":[{"name":"iPhone 17 Pro","isAvailable":true,"deviceTypeIdentifier":"T"}],
 "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"name":"iPhone 17 Pro","isAvailable":true,"deviceTypeIdentifier":"T"}],
 "com.apple.CoreSimulator.SimRuntime.iOS-9-3":[{"name":"iPhone 17 Pro","isAvailable":true,"deviceTypeIdentifier":"T"}]}}
J
elif [ "$1 $2" = "simctl create" ]; then echo "$5" > "$FAKE_OUT"; echo 00000000-0000-0000-0000-000000000000
fi
X
chmod +x "$fake/xcrun"
FAKE_OUT="$fake/runtime" PATH="$fake:$PATH" bash "$M" "$A1-v" "$P" >/dev/null 2>&1
if [ "$(cat "$fake/runtime" 2>/dev/null)" = "com.apple.CoreSimulator.SimRuntime.iOS-26-10" ]; then echo "PASS  newest_runtime_by_version"; PASS=$((PASS+1)); else echo "FAIL  newest_runtime_by_version: got '$(cat "$fake/runtime" 2>/dev/null)'"; FAIL=$((FAIL+1)); fi
export -n FAKE_OUT
finish
