#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
RA="$ROOT/scripts/request-approve.sh"
T=$(mktemp -d /tmp/agent-panel-reqapprove.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
D="$T/data"; mkdir -p "$D/tasks"

expect writes_a_request_0 0 "" bash "$RA" "$D" 'approve N18 and "N19" please' N18 N19
f=$(ls "$D/.tentacl/approve-requests"/*.json 2>/dev/null | head -1)
[ -n "$f" ] && ok request_file_exists || no request_file_exists "none"
jq -e '.cards == ["N18","N19"] and .requestedBy == "pm" and .userWords == "approve N18 and \"N19\" please" and (.id | length > 0)' "$f" >/dev/null && ok request_content || no request_content "$(cat "$f")"
[ "$(ls "$D/.tentacl/approve-requests" | grep -vc '\.json$')" = 0 ] && ok no_temp_files_left || no no_temp_files_left "$(ls -a "$D/.tentacl/approve-requests")"
expect two_requests_do_not_collide_0 0 "" bash "$RA" "$D" 'again' N18
[ "$(ls "$D/.tentacl/approve-requests"/*.json | wc -l | tr -d ' ')" = 2 ] && ok separate_files || no separate_files ""
expect missing_data_dir_2 2 "folder" bash "$RA" "$T/nope" 'x' N18
expect relative_data_dir_2 2 "absolute" bash "$RA" "data" 'x' N18
expect bad_card_id_2 2 "card id" bash "$RA" "$D" 'x' '../etc'
expect no_cards_2 2 "Usage" bash "$RA" "$D" 'x'
expect empty_words_0 0 "" bash "$RA" "$D" '' N18
jq -e '.userWords == "" and .cards == ["N18"]' "$(ls -t "$D/.tentacl/approve-requests"/*.json | head -1)" >/dev/null && ok empty_words_recorded || no empty_words_recorded ""
expect too_many_cards_2 2 "at most" bash "$RA" "$D" 'x' A1 A2 A3 A4 A5 A6 A7 A8 A9
expect with_key_0 0 "" bash "$RA" --key abc123 "$D" 'x' N18
jq -e '.key == "abc123" and .cards == ["N18"]' "$(ls -t "$D/.tentacl/approve-requests"/*.json | head -1)" >/dev/null && ok key_recorded || no key_recorded ""
expect no_key_field_without_flag_0 0 "" bash "$RA" "$D" 'x' N18
jq -e 'has("key") | not' "$(ls -t "$D/.tentacl/approve-requests"/*.json | head -1)" >/dev/null && ok no_key_without_flag || no no_key_without_flag ""
expect key_without_value_2 2 "session key" bash "$RA" --key
expect empty_key_2 2 "session key" bash "$RA" --key "" "$D" 'x' N18
expect env_key_0 0 "" env TENTACL_PM_KEY=envk bash "$RA" "$D" 'x' N18
jq -e '.key == "envk"' "$(ls -t "$D/.tentacl/approve-requests"/*.json | head -1)" >/dev/null && ok env_key_used || no env_key_used ""
expect flag_beats_env_0 0 "" env TENTACL_PM_KEY=envk bash "$RA" --key flagk "$D" 'x' N18
jq -e '.key == "flagk"' "$(ls -t "$D/.tentacl/approve-requests"/*.json | head -1)" >/dev/null && ok flag_beats_env || no flag_beats_env ""
finish
