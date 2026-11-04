#!/usr/bin/env bash
# Gives each agent its own simulator so two agents never drive the same device.
# Usage: sim-for-agent.sh <agent> <project.json>   prints the UDID (creates "agent-<agent>" once, reuses it later)
#        sim-for-agent.sh --remove <agent>         deletes that agent's simulator
# The simulator is a fresh device of the same type and runtime as project.json's simulator.baseDevice.
# Build output convention: <worktree>/build/dd
set -u
die() { echo "ERROR: $*" >&2; exit 1; }
devices() { xcrun simctl list -j devices; }

if [ "${1:-}" = "--remove" ]; then
  [ $# -eq 2 ] || die "usage: sim-for-agent.sh --remove <agent>"
  udid=$(devices | jq -r --arg n "agent-$2" '[.devices[][] | select(.name == $n)][0].udid // empty')
  [ -n "$udid" ] || exit 0
  xcrun simctl shutdown "$udid" >/dev/null 2>&1
  xcrun simctl delete "$udid" || die "could not delete simulator $udid"
  exit 0
fi

[ $# -eq 2 ] && [ -f "$2" ] || die "usage: sim-for-agent.sh <agent> <project.json>"
agent=$1; name="agent-$1"; base=$(jq -r '.simulator.baseDevice // empty' "$2")
[ -n "$base" ] || die "simulator.baseDevice is missing in $2"

existing=$(devices | jq -r --arg n "$name" '[.devices[][] | select(.name == $n)][0].udid // empty')
[ -n "$existing" ] && { echo "$existing"; exit 0; }

# Newest available device named like the base device: runtime key plus its device type identifier.
found=$(devices | jq -r --arg b "$base" '
  [.devices | to_entries[] | .key as $rt | .value[] | select(.name == $b and .isAvailable) | {rt: $rt, type: .deviceTypeIdentifier}]
  | sort_by(.rt | sub(".*\\."; "") | [scan("[0-9]+") | tonumber]) | last // empty | "\(.rt) \(.type)"')
[ -n "$found" ] || die "base device '$base' not found among available simulators (xcrun simctl list devices)"
runtime=${found%% *}; dtype=${found#* }
xcrun simctl create "$name" "$dtype" "$runtime" || die "could not create simulator $name"
