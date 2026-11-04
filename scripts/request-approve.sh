#!/usr/bin/env bash
# Asks the panel to review and approve tasks the user just asked the PM to approve in the Command box. The PM cannot merge a task itself; the panel does,
# through its own Prepare review and Approve (packet checks, merge, card done, agent closed), when the user's message is really there.
# The words may be empty: the panel then approves only when the project's PM authority rule is on (Autopilot rules), within its limits.
# Usage: request-approve.sh [--key <session key>] <absolute data folder of the project> "<the user's words, or an empty string>" <card id>...
# --key: the PM session key; left out, $TENTACL_PM_KEY (set in the PM's environment by the app) is used. With the right key with the right key the request may use the PM authority. Never write the key anywhere else.
# Writes <data folder>/.tentacl/approve-requests/<id>.json; the panel picks it up, answers in the PM's pane and in its decision feed.
# Exit: 0 written; 2 usage or bad input.
set -u
usage() { echo "Usage: request-approve.sh [--key <session key>] <absolute data folder> \"<the user's words or empty>\" <card id>..." >&2; exit 2; }
key=${TENTACL_PM_KEY:-}
if [ "${1:-}" = "--key" ]; then
  [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --key needs the session key" >&2; exit 2; }
  key=$2; shift 2
fi
[ $# -ge 3 ] || usage
dir=$1 words=$2; shift 2
case "$dir" in /*) ;; *) echo "ERROR: the data folder must be an absolute path" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "ERROR: $dir is not a folder" >&2; exit 2; }
[ $# -le 8 ] || { echo "ERROR: ask for at most 8 cards at a time" >&2; exit 2; }
for id in "$@"; do
  printf '%s' "$id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' || { echo "ERROR: \"$id\" is not a plain card id" >&2; exit 2; }
done
out="$dir/.tentacl/approve-requests"
mkdir -p "$out" || { echo "ERROR: could not create $out" >&2; exit 2; }
id="$(date +%Y%m%dT%H%M%S)-$$-$RANDOM"
tmp=$(mktemp "$out/.tmp.XXXXXX") || { echo "ERROR: could not write in $out" >&2; exit 2; }
jq -n --arg id "$id" --arg words "$words" --arg key "$key" '{id: $id, requestedBy: "pm", userWords: $words, cards: $ARGS.positional} + (if $key == "" then {} else {key: $key} end)' --args "$@" > "$tmp" || { rm -f "$tmp"; echo "ERROR: could not build the request" >&2; exit 2; }
mv "$tmp" "$out/$id.json" || { rm -f "$tmp"; echo "ERROR: could not write the request" >&2; exit 2; }
echo "Requested: $* (the panel answers in this pane)"
