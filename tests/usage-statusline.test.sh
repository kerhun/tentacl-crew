#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
U="$ROOT/scripts/usage-statusline.sh"
D=$(mktemp -d); export AGENT_PANEL_USAGE="$D/usage"
FULL='{"session_id":"s-1","cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":23.4,"resets_at":1900000000},"seven_day":{"used_percentage":41,"resets_at":1900500000}}}'

expect prints_short_line_0          0 "5h 23% · week 41%" bash -c "printf '%s' '$FULL' | bash '$U'"
[ -f "$D/usage/s-1.json" ] && { echo "PASS  file_written"; PASS=$((PASS+1)); } || { echo "FAIL  file_written"; FAIL=$((FAIL+1)); }
expect file_keeps_percentage_0      0 "41"  jq -r '.rate_limits.seven_day.used_percentage' "$D/usage/s-1.json"
expect file_keeps_cost_0            0 "1.5" jq -r '.cost.total_cost_usd' "$D/usage/s-1.json"
expect file_has_time_seen_0         0 "true" jq -r '(.seen_at | type) == "number"' "$D/usage/s-1.json"
[ -z "$(ls "$D/usage" | grep -v '\.json$')" ] && { echo "PASS  no_temp_file_left"; PASS=$((PASS+1)); } || { echo "FAIL  no_temp_file_left: $(ls "$D/usage")"; FAIL=$((FAIL+1)); }

# a missing window is left out; no windows at all prints nothing but still records the session
expect only_five_hour_0             0 "5h 10%" bash -c "printf '%s' '{\"session_id\":\"s-2\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":1}}}' | bash '$U'"
out=$(printf '%s' '{"session_id":"s-3","cost":{"total_cost_usd":2}}' | bash "$U")
[ -z "$out" ] && { echo "PASS  no_windows_prints_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  no_windows_prints_nothing: '$out'"; FAIL=$((FAIL+1)); }
[ -f "$D/usage/s-3.json" ] && { echo "PASS  no_windows_still_recorded"; PASS=$((PASS+1)); } || { echo "FAIL  no_windows_still_recorded"; FAIL=$((FAIL+1)); }

# bad input never fails and never writes outside the folder
expect garbage_input_exit_0         0 "" bash -c "printf 'not json' | bash '$U'"
expect odd_session_id_not_written_0 0 "" bash -c "printf '%s' '{\"session_id\":\"../x\"}' | bash '$U'"
[ ! -e "$D/x.json" ] && { echo "PASS  odd_session_id_ignored"; PASS=$((PASS+1)); } || { echo "FAIL  odd_session_id_ignored"; FAIL=$((FAIL+1)); }

# a role's own statusLine command runs first, with the same input; its output comes before ours
expect chains_role_status_line_0    0 "ROLE:s-1 | 5h 23% · week 41%" bash -c "printf '%s' '$FULL' | bash '$U' 'echo ROLE:\$(jq -r .session_id)'"
expect chain_still_records_0        0 "" test -f "$D/usage/s-1.json"
expect failing_role_command_ok_0    0 "5h 23%" bash -c "printf '%s' '$FULL' | bash '$U' 'exit 3'"
rm -rf "$D"
finish
