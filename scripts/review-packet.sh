#!/usr/bin/env bash
# Builds the evidence a human needs to approve a task and moves the card to "review".
# Usage: review-packet.sh <task-card.md> <worktree_path> <udid> <project.json>
# Success: fills the card's "## Review packet" section (build result, screenshots, diff summary), sets status: review, exit 0.
# Missing evidence (build fails, or no screenshot): prints "EVIDENCE MISSING: ...", leaves the card untouched, exit 1.
# Env: AGENT_PANEL_SCREENSHOT_CMD overrides the screenshot command; it may use $UDID and $FILE.
#      AGENT_PANEL_BUILD_ROOT overrides where builds and locks live (default ~/.cache/agent-panel/build); never the data folder.
#      AGENT_PANEL_SLOT_TIMEOUT (seconds, default 2700) and AGENT_PANEL_SLOT_POLL (seconds, default 5): how long a packet waits for the
#      machine-wide build slot, and how often it looks again.
#      The line "PACKET RUN STARTED" on stdout means the wait is over (slot taken, or nothing to wait for): the app counts its run
#      limit from there, and the wait has its own limit (N264).
set -u
[ $# -eq 4 ] && [ -f "$1" ] && [ -d "$2" ] && [ -f "$4" ] || { echo "usage: review-packet.sh <task-card.md> <worktree_path> <udid> <project.json>" >&2; exit 2; }
card=$1; wt=$2; udid=$3; project=$4

# fm_get <key>: the first value of a front-matter key (the body is never read; CRLF is tolerated).
fm_get() { tr -d '\r' < "$card" | awk -v k="$1" 'NR == 1 && $0 == "---" { infm = 1; next } infm && $0 == "---" { exit } infm && index($0, k ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'; }
card_hash() { shasum "$card" | cut -d' ' -f1; }
start_hash=$(card_hash)
id=$(fm_get id)
[ -n "$id" ] || { echo "ERROR: card has no id in its front matter" >&2; exit 2; }
data=$(jq -r .dataDir "$project"); build=$(jq -r '.buildCommand // empty' "$project"); testc=$(jq -r '.testCommand // empty' "$project"); repo=$(jq -r .repoPath "$project")
base=$(jq -r '.mainBranch // "main"' "$project")   # the project's main branch, not the branch the repository is on
dir="$data/tasks/$id"; shots="$dir/shots"; log="$dir/build.log"
mkdir -p "$shots"

# One packet per card at a time: a lock folder (with the pid) next to the build tree, outside the data folder (which sits in the
# user's vault). A second run refuses with a message; a lock whose process is gone is taken over (the rename lets only one taker win).
broot="${AGENT_PANEL_BUILD_ROOT:-$HOME/.cache/agent-panel/build}/$(basename "$repo")"
bt="$broot/$id"; lock="$broot/$id.lock"; have_lock=""
slot="${AGENT_PANEL_BUILD_ROOT:-$HOME/.cache/agent-panel/build}/.build-slot"; have_slot=""
mkdir -p "$broot" || { echo "ERROR: could not create $broot" >&2; exit 2; }
if ! mkdir "$lock" 2>/dev/null; then
  owner=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    echo "EVIDENCE MISSING: a packet for $id is already being prepared (pid $owner); wait for it to finish"; exit 1
  fi
  mv "$lock" "$lock.stale.$$" 2>/dev/null && rm -rf "$lock.stale.$$"
  mkdir "$lock" 2>/dev/null || { echo "EVIDENCE MISSING: a packet for $id is already being prepared (pid $(cat "$lock/pid" 2>/dev/null || echo unknown)); wait for it to finish"; exit 1; }
fi
echo $$ > "$lock/pid"; have_lock=1
cleanup_tree() { git -C "$wt" worktree remove --force "$bt" >/dev/null 2>&1; rm -rf "$bt"; git -C "$wt" worktree prune >/dev/null 2>&1; }
cleanup() { cleanup_tree; [ -z "$have_slot" ] || rm -rf "$slot"; [ -z "$have_lock" ] || rm -rf "$lock"; }
trap cleanup EXIT

# failure_lines <log>: the lines that say what failed (failed tests, errors, TEST FAILED, the Executed summary, FAIL lines of tests/run.sh),
# at most 15 (only the last Executed line); the last 5 lines when none of those is found. The test summary is sorted, so its tail is only passed tests.
failure_lines() {
  local found
  found=$({ grep -E '^failed  |^Test Case .* failed|error:|\*\* TEST FAILED \*\*|^FAIL( |$)' "$1" | awk '!seen[$0]++' | head -n 14; grep -E 'Executed [0-9]+ tests?' "$1" | tail -n 1; })
  if [ -n "$found" ]; then printf '%s\n' "$found"; else tail -n 5 "$1"; fi
}

# write_card <body-file>: replace the "## Review packet" section (appended when missing) and set status: review.
# The card is written to a temp file in its own folder and moved over it only when it is byte-identical to what was read at the
# start: an agent or the panel that wrote to it meanwhile keeps its changes, and the packet has to be built again.
write_card() {
  local body=$1 tmp
  tmp=$(mktemp "$(dirname "$card")/.$id.packet.XXXXXX") || { echo "ERROR: could not write next to $card" >&2; exit 2; }
  awk -v body="$body" '
    function section() { print "## Review packet"; print ""; while ((getline line < body) > 0) print line; print "" }
    /^## Review packet[[:space:]]*$/ { section(); found = 1; skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    skipping { next }
    NR > 1 && infm && /^status:/ { print "status: review" (sub(/\r$/, "") ? "\r" : ""); next }
    NR == 1 && $0 ~ /^---\r?$/ { infm = 1 }
    infm && NR > 1 && $0 ~ /^---\r?$/ { infm = 0 }
    { print }
    END { if (!found) { print ""; section() } }
  ' "$card" > "$tmp" || { rm -f "$tmp"; echo "ERROR: could not build the card" >&2; exit 2; }
  chmod "$(stat -f %Lp "$card" 2>/dev/null || echo 644)" "$tmp" 2>/dev/null
  if [ "$(card_hash)" != "$start_hash" ]; then
    rm -f "$tmp"; echo "EVIDENCE MISSING: the card changed while the packet was being built (its changes are kept); run it again"; exit 1
  fi
  mv "$tmp" "$card" || { rm -f "$tmp"; echo "ERROR: could not write $card" >&2; exit 2; }
}

# The packet describes one fixed state of the branch: its tip is read now, the tree must be clean, and the tip must still be the same
# when the evidence is complete (otherwise the build and screenshot belong to code that is not what gets merged).
head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { echo "ERROR: $wt is not a git worktree" >&2; exit 2; }

# Analysis tasks (kind: analysis): the report is the evidence, nothing may have changed in the worktree; no build, no screenshots.
kind=$(fm_get kind)
if [ "$kind" = "analysis" ]; then
  echo "PACKET RUN STARTED"
  report=$(awk '/^## Report[[:space:]]*$/ { r = 1; next } r && /^## / { exit } r && NF { print }' "$card")
  [ -n "$report" ] || { echo "EVIDENCE MISSING: report section is empty (the agent may still be working or waiting for your answer: check the Agents column, or ask it to write its report)"; exit 1; }
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || [ -n "$(git -C "$wt" log --oneline "$base"..HEAD 2>/dev/null)" ]; then
    echo "EVIDENCE MISSING: analysis task changed files in the worktree"; exit 1
  fi
  body=$(mktemp)
  { echo "Head: $head"; echo; echo "Analysis task: no build or screenshots needed."; echo "Report: $(printf '%s\n' "$report" | wc -l | tr -d ' ') lines in the card. Worktree unchanged."; } > "$body"
  write_card "$body"; rm -f "$body"; exit 0
fi

# 1. Build in the worktree. $UDID in the command is replaced by the agent's simulator before the shell sees it,
#    so quoting like 'id=$UDID' works.
dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
if [ -n "$dirty" ]; then
  # app-test.sh runs xcodegen on every run: a forgotten regenerated project.pbxproj is named on its own
  if ! printf '%s\n' "$dirty" | grep -qv 'project\.pbxproj$'; then
    echo "EVIDENCE MISSING: project.pbxproj changed but not committed (xcodegen regenerated it; commit it)"; exit 1
  fi
  echo "EVIDENCE MISSING: uncommitted work in the agent's worktree: commit first (or discard it)"; printf '%s\n' "$dirty"; exit 1
fi
# A project without a build command (build is optional) is reviewed from the diff and the report alone: nothing to wait for.
[ -n "$build" ] || echo "PACKET RUN STARTED"
# The build runs in a throw-away detached worktree at the reviewed commit, so the agent's own tree is never reset or touched.
if [ -n "$build" ]; then
  # One build at a time on the machine (two full builds and test runs together make tests fail on timing): wait for the slot, a folder
  # with the pid of its owner; a slot whose process is gone is taken over like a card lock.
  slot_timeout=${AGENT_PANEL_SLOT_TIMEOUT:-2700}; slot_poll=${AGENT_PANEL_SLOT_POLL:-5}; waited=0; told=""
  until mkdir "$slot" 2>/dev/null; do
    owner=$(cat "$slot/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      mv "$slot" "$slot.stale.$$" 2>/dev/null && rm -rf "$slot.stale.$$"; continue
    fi
    if [ "$waited" -ge "$slot_timeout" ]; then
      echo "EVIDENCE MISSING: waited $((waited / 60)) min for another packet to finish building (pid ${owner:-unknown}); run the packet again later"; exit 1
    fi
    [ -n "$told" ] || { echo "waiting for another packet to finish (pid ${owner:-unknown})..."; told=1; }
    sleep "$slot_poll"; waited=$((waited + slot_poll))
  done
  echo $$ > "$slot/pid"; echo "review packet for $id" > "$slot/what"; have_slot=1
  echo "PACKET RUN STARTED"
  build=${build//\$UDID/$udid}
  cleanup_tree
  git -C "$wt" worktree add -q --detach "$bt" "$head" >/dev/null 2>&1 || { echo "ERROR: could not create a build worktree at $head" >&2; exit 2; }
  # Untracked local files the project lists in "copyFiles" (signing settings, .env) are not in a fresh worktree.
  while IFS= read -r rel; do
    case "$rel" in ""|/*|../*|*/../*|*/..|..|.git|.git/*) continue ;; esac
    if [ -f "$wt/$rel" ] && [ ! -L "$wt/$rel" ] && [ ! -e "$bt/$rel" ]; then mkdir -p "$(dirname "$bt/$rel")" && cp "$wt/$rel" "$bt/$rel"; fi
  done < <(jq -r '.copyFiles[]? // empty' "$project")
  ( cd "$bt" && UDID=$udid TENTACL_SLOT_HELD=1 bash -c "$build" ) > "$log" 2>&1; build_rc=$?
  if [ "$build_rc" -ne 0 ]; then
    cleanup_tree; echo "EVIDENCE MISSING: build failed, see $log"; failure_lines "$log"; exit 1
  fi
  # The tests run in the same tree, after a build that passed; their output goes on the same log.
  if [ -n "$testc" ]; then
    ( cd "$bt" && UDID=$udid TENTACL_SLOT_HELD=1 bash -c "${testc//\$UDID/$udid}" ) >> "$log" 2>&1; test_rc=$?
    cleanup_tree
    if [ "$test_rc" -ne 0 ]; then
      echo "EVIDENCE MISSING: tests failed, see $log"; failure_lines "$log"; exit 1
    fi
  else cleanup_tree; fi
fi
# Screenshots are taken unless the project says "screenshots": false (a missing value means yes, as before) or has no simulator.
want_shots=1
[ "$(jq -r 'if has("screenshots") then .screenshots else true end' "$project")" = "false" ] && want_shots=""
jq -e '.simulator.baseDevice // empty' "$project" >/dev/null 2>&1 || want_shots=""
shot_list=""
if [ -n "$want_shots" ]; then

# 2. Screenshot of the simulator as the agent left it (status bar pinned to 9:41, the project rule).
FILE="$shots/final.png"; export UDID="$udid" FILE
if [ -n "${AGENT_PANEL_SCREENSHOT_CMD:-}" ]; then
  bash -c "$AGENT_PANEL_SCREENSHOT_CMD" >/dev/null 2>&1
else
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryLevel 100 --cellularBars 4 >/dev/null 2>&1
  xcrun simctl io "$udid" screenshot "$FILE" >/dev/null 2>&1
  xcrun simctl status_bar "$udid" clear >/dev/null 2>&1
fi
# Only images newer than the previous packet count: a screenshot from an earlier round is not evidence.
marker="$shots/.packet-time"
if [ -f "$marker" ]; then newer=(-newer "$marker"); else newer=(); fi
shot_list=$(find "$shots" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' \) -size +0 ${newer[@]+"${newer[@]}"} 2>/dev/null | sort)
[ -n "$shot_list" ] || { echo "EVIDENCE MISSING: screenshot (no new image in $shots since the last packet)"; exit 1; }


# Two different screens cannot produce byte-identical files (final.png is the script's own capture and may equal the agent's last shot).
dups=$(printf '%s\n' "$shot_list" | grep -v '/final\.png$' | while IFS= read -r f; do echo "$(shasum "$f" | cut -d' ' -f1) $f"; done | sort | awk '{ if ($1 == prev) print prevf " and " $2; prev = $1; prevf = $2 }' | head -1)
[ -z "$dups" ] || { echo "EVIDENCE MISSING: identical screenshots: $dups"; exit 1; }

fi

[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ] || { echo "EVIDENCE MISSING: the branch changed while the packet was being built; run it again"; exit 1; }

# 3. Diff summary against the project's main branch.
mb=$(git -C "$wt" merge-base HEAD "$base" 2>/dev/null)
diffstat=$( [ -n "$mb" ] && git -C "$wt" diff --stat "$mb"..HEAD 2>/dev/null || echo "(diff unavailable)" )

body=$(mktemp)
{
  echo "Head: $head"
  # the sha the agent wrote in the card's Report; a different one means the packet tested other code than the report describes
  rh=$(awk '/^## Report[[:space:]]*$/ { r = 1; next } r && /^## / { exit } r' "$card" | grep -oiE 'head:? *`?[0-9a-f]{7,40}' | head -n 1 | grep -oE '[0-9a-f]{7,40}$')
  [ -z "$rh" ] || case "$head" in "$rh"*) ;; *) echo; echo "NOTE: the card's Report names Head $rh, but this packet tested $head" ;; esac
  echo
  if [ -n "$build" ] && [ -n "$testc" ]; then echo "Build: passed, tests passed (\`$build\`, \`$testc\`), log: $log"
  elif [ -n "$build" ]; then echo "Build: passed (\`$build\`), log: $log"; else echo "Build: none (this project has no build command)"; fi
  echo
  if [ -n "$want_shots" ]; then
    echo "Screenshots:"
    printf '%s\n' "$shot_list" | while IFS= read -r s; do echo "- ${s#"$data"/}"; done
  else
    echo "Screenshots: not used in this project"
  fi
  echo
  echo "Diff summary:"
  echo '```'; printf '%s\n' "$diffstat"; echo '```'
} > "$body"
write_card "$body"
rm -f "$body"
if [ -n "$want_shots" ]; then touch "$marker"; fi   # the next packet needs images newer than this one
