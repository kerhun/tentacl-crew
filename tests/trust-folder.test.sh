#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
TR="$ROOT/scripts/trust-folder.sh"
T=$(mktemp -d /tmp/agent-panel-trust.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj" "$T/other"
export AGENT_PANEL_CLAUDE_JSON="$T/claude.json"
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }

echo '{"numStartups":7,"projects":{"'"$T"'/other":{"hasTrustDialogAccepted":true,"allowedTools":["x"]}}}' > "$AGENT_PANEL_CLAUDE_JSON"
expect trusts_a_new_folder_0 0 "" bash "$TR" "$T/proj"
jq -e --arg p "$T/proj" '.projects[$p].hasTrustDialogAccepted == true' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok entry_is_trusted || no entry_is_trusted "$(cat "$AGENT_PANEL_CLAUDE_JSON")"
jq -e --arg o "$T/other" '.numStartups == 7 and .projects[$o].allowedTools == ["x"]' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok other_settings_kept || no other_settings_kept "$(cat "$AGENT_PANEL_CLAUDE_JSON")"
[ -f "$AGENT_PANEL_CLAUDE_JSON.tentacl-backup" ] && jq -e '.projects | length == 1' "$AGENT_PANEL_CLAUDE_JSON.tentacl-backup" >/dev/null && ok backup_has_the_old_file || no backup_has_the_old_file ""
expect trusting_twice_is_fine_0 0 "" bash "$TR" "$T/proj"
jq -e --arg p "$T/proj" '[.projects | keys[]] | length == 2' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok no_duplicate_entry || no no_duplicate_entry ""
echo '{"projects":{"'"$T"'/proj":{"hasTrustDialogAccepted":false,"mcpServers":{"a":1}}}}' > "$AGENT_PANEL_CLAUDE_JSON"
bash "$TR" "$T/proj" >/dev/null 2>&1
jq -e --arg p "$T/proj" '.projects[$p].hasTrustDialogAccepted == true and .projects[$p].mcpServers.a == 1' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok false_becomes_true_keeping_the_rest || no false_becomes_true_keeping_the_rest ""
rm -f "$AGENT_PANEL_CLAUDE_JSON"
expect creates_the_file_when_missing_0 0 "" bash "$TR" "$T/proj"
jq -e --arg p "$T/proj" '.projects[$p].hasTrustDialogAccepted == true' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok missing_file_created || no missing_file_created ""
echo '{ broken' > "$AGENT_PANEL_CLAUDE_JSON"
expect corrupt_file_refused_1 1 "not valid" bash "$TR" "$T/proj"
[ "$(cat "$AGENT_PANEL_CLAUDE_JSON")" = '{ broken' ] && ok corrupt_file_untouched || no corrupt_file_untouched ""
expect relative_path_2 2 "absolute" bash "$TR" "proj"
expect missing_folder_2 2 "folder" bash "$TR" "$T/nope"
expect not_a_folder_2 2 "folder" bash "$TR" "$T/claude.json"
# another Claude session rewrites the file right after our write: the flag is read back and written once more
mkdir -p "$T/fakebin"; rm -f "$T/mv-count"
cat > "$T/fakebin/mv" <<MV
#!/usr/bin/env bash
/bin/mv "\$@" || exit \$?
if [ ! -f "$T/mv-count" ]; then touch "$T/mv-count"; echo '{"numStartups":8}' > "\$2"; fi
MV
chmod +x "$T/fakebin/mv"
echo '{"numStartups":7}' > "$AGENT_PANEL_CLAUDE_JSON"
expect lost_write_is_retried_0 0 "" env PATH="$T/fakebin:$PATH" bash "$TR" "$T/proj"
jq -e --arg p "$T/proj" '.projects[$p].hasTrustDialogAccepted == true' "$AGENT_PANEL_CLAUDE_JSON" >/dev/null && ok flag_present_after_retry || no flag_present_after_retry "$(cat "$AGENT_PANEL_CLAUDE_JSON")"
# a write that is lost twice is reported
cat > "$T/fakebin/mv" <<MV
#!/usr/bin/env bash
/bin/mv "\$@" || exit \$?
echo '{"numStartups":9}' > "\$2"
MV
expect twice_lost_write_fails_1 1 "could not be confirmed" env PATH="$T/fakebin:$PATH" bash "$TR" "$T/proj"
finish
