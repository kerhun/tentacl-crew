#!/usr/bin/env bash
# Stands in for review-packet.sh: writes "Head:" and "Build:" into the card (FAKE_PACKET_FAIL=1: EVIDENCE MISSING), counts its runs.
card=$1; wt=$2
echo run >> "${FAKE_PACKET_COUNT:-/dev/null}"
[ -z "${FAKE_PACKET_FAIL:-}" ] || { echo "EVIDENCE MISSING: build failed"; exit 1; }
printf '\n## Review packet\nHead: %s\nBuild: passed (fake)\n' "$(git -C "$wt" rev-parse HEAD)" >> "$card"
