#!/usr/bin/env bash
# Regenerates every README and guide screenshot from a live window (N383).
# Usage: docs/screenshots/generate.sh
# Runs only ReadmeShotsTests with AGENT_PANEL_README_SHOTS set: it opens an on-screen window that hosts the real views with the demo
# data, in light and dark, and this script copies <name>.png and <name>-dark.png here at 1400 px wide.
# Needs a logged-in, unlocked screen (a window on a locked screen draws no materials); it stops with an error instead of waiting.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=docs/screenshots
session=$(ioreg -n Root -d1 2>/dev/null | grep -o 'IOConsoleUsers.*' || true)
if ! printf '%s' "$session" | grep -q '"kCGSSessionOnConsoleKey"=Yes'; then
  echo "generate.sh: no logged-in screen session; log in at the Mac (not over ssh) and run it again" >&2; exit 2
fi
if printf '%s' "$session" | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  echo "generate.sh: the screen is locked; unlock it and run it again (the shots need a live window)" >&2; exit 2
fi
tmp=$(mktemp -d /tmp/tentacl-shots.XXXXXX); trap 'rm -rf "$tmp"' EXIT
TEST_RUNNER_AGENT_PANEL_README_SHOTS=$tmp scripts/app-test.sh -only-testing:AgentPanelTests/ReadmeShotsTests | tail -3
names="dashboard questions question-card tasks start-sheet approve-sheet autopilot round team team-chart stats settings setup add-project"
for name in $names; do
  for file in "$name.png" "$name-dark.png"; do
    [ -s "$tmp/$file" ] || { echo "missing shot: $file" >&2; exit 1; }
    sips --resampleWidth 1400 "$tmp/$file" --out "$out/$file" >/dev/null
  done
done
echo "wrote $(( $(echo $names | wc -w) * 2 )) screenshots to $out"
