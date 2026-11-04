#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
AQ="$ROOT/scripts/answer-question.sh"
T=$(mktemp -d /tmp/agent-panel-answerq.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
D="$T/data"; mkdir -p "$D"
newest() { ls -t "$D/.tentacl/answer-requests"/*.json | head -1; }

expect writes_a_request_0 0 "" bash "$AQ" --key abc123 "$D" N279-q1 2
f=$(newest)
jq -e '.question == "N279-q1" and .answer == "2" and .key == "abc123" and .requestedBy == "pm" and (.id | length > 0)' "$f" >/dev/null && ok request_content || no request_content "$(cat "$f")"
[ "$(ls "$D/.tentacl/answer-requests" | grep -vc '\.json$')" = 0 ] && ok no_temp_files_left || no no_temp_files_left "$(ls -a "$D/.tentacl/answer-requests")"
expect text_answer_0 0 "" bash "$AQ" --key abc123 "$D" N279-q2 'use "the second" way'
jq -e '.answer == "use \"the second\" way"' "$(newest)" >/dev/null && ok text_kept_whole || no text_kept_whole ""
expect no_key_2 2 "--key" env -u TENTACL_PM_KEY bash "$AQ" "$D" N279-q1 2
expect env_key_0 0 "" env TENTACL_PM_KEY=envk bash "$AQ" "$D" N279-q1 2
jq -e '.key == "envk"' "$(newest)" >/dev/null && ok env_key_used || no env_key_used ""
expect flag_beats_env_0 0 "" env TENTACL_PM_KEY=envk bash "$AQ" --key flagk "$D" N279-q1 2
jq -e '.key == "flagk"' "$(newest)" >/dev/null && ok flag_beats_env || no flag_beats_env ""
expect empty_key_2 2 "session key" bash "$AQ" --key "" "$D" N279-q1 2
expect key_without_value_2 2 "session key" bash "$AQ" --key
expect relative_dir_2 2 "absolute" bash "$AQ" --key k data N279-q1 2
expect missing_dir_2 2 "folder" bash "$AQ" --key k "$T/nope" N279-q1 2
expect bad_question_id_2 2 "question id" bash "$AQ" --key k "$D" '../etc' 2
expect id_without_q_2 2 "question id" bash "$AQ" --key k "$D" N279 2
expect empty_answer_2 2 "empty" bash "$AQ" --key k "$D" N279-q1 '   '
expect missing_answer_2 2 "Usage" bash "$AQ" --key k "$D" N279-q1
expect long_answer_2 2 "600" bash "$AQ" --key k "$D" N279-q1 "$(printf 'x%.0s' $(seq 1 601))"
finish
