#!/usr/bin/env bash
# The PM's answer to an agent's question the panel relayed ("QUESTION <ID>-q<n> …" in the PM's pane). The PM cannot type into the agent
# itself; the panel does, when the key is the PM session's and the question is still open and was relayed (never a critical one).
# Usage: answer-question.sh [--key <authority key>] <absolute data folder of the project> <ID>-q<n> "<option number, or your words>"
# --key: the PM session key; left out, $TENTACL_PM_KEY (set in the PM's environment by the app) is used. Never write the key anywhere else.
# Writes <data folder>/.tentacl/answer-requests/<id>.json; the panel picks it up and answers in the PM's pane.
# Exit: 0 written; 2 usage or bad input.
set -u
usage() { echo "Usage: answer-question.sh [--key <session key>] <absolute data folder> <ID>-q<n> \"<option number or text>\"" >&2; exit 2; }
key=${TENTACL_PM_KEY:-}
if [ "${1:-}" = "--key" ]; then
  [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --key needs the session key" >&2; exit 2; }
  key=$2; shift 2
fi
[ -n "$key" ] || { echo "ERROR: --key <session key> is required (or TENTACL_PM_KEY in the environment)" >&2; exit 2; }
[ $# -eq 3 ] || usage
dir=$1 question=$2 answer=$3
case "$dir" in /*) ;; *) echo "ERROR: the data folder must be an absolute path" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "ERROR: $dir is not a folder" >&2; exit 2; }
printf '%s' "$question" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}-q[0-9]{1,6}$' || { echo "ERROR: \"$question\" is not a question id like N12-q1" >&2; exit 2; }
[ -n "$(printf '%s' "$answer" | tr -d '[:space:]')" ] || { echo "ERROR: the answer is empty" >&2; exit 2; }
[ ${#answer} -le 600 ] || { echo "ERROR: the answer is longer than 600 characters" >&2; exit 2; }
out="$dir/.tentacl/answer-requests"
mkdir -p "$out" || { echo "ERROR: could not create $out" >&2; exit 2; }
id="$(date +%Y%m%dT%H%M%S)-$$-$RANDOM"
tmp=$(mktemp "$out/.tmp.XXXXXX") || { echo "ERROR: could not write in $out" >&2; exit 2; }
jq -n --arg id "$id" --arg q "$question" --arg a "$answer" --arg key "$key" '{id: $id, requestedBy: "pm", question: $q, answer: $a, key: $key}' > "$tmp" || { rm -f "$tmp"; echo "ERROR: could not build the request" >&2; exit 2; }
mv "$tmp" "$out/$id.json" || { rm -f "$tmp"; echo "ERROR: could not write the request" >&2; exit 2; }
echo "Answered: $question (the panel confirms in this pane)"
