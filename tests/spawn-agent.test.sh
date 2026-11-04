#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$ROOT/scripts/spawn-agent.sh"; X="$ROOT/scripts/stop-agent.sh"; F="$ROOT/tests/fixtures/config"
FAKE_HOME="$ROOT/tests/fixtures/claude-home"
export AGENT_PANEL_STATE=$(mktemp -d)

# ---- offline: flag generation (no terminal, no claude) ----
expect print_flags_model_and_effort_0   0 "--model sonnet --effort medium" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json"
expect print_flags_permission_mode_0    0 "--permission-mode acceptEdits" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json"
expect print_flags_concise_prompt_0     0 "--append-system-prompt-file" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json"
expect print_flags_invalid_role_1       1 "ERROR:" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/missing_model.json"

# every agent may read the panel's attachments folder (pasted images) without a permission prompt
expect print_flags_add_dir_attachments_0 0 "--add-dir /att/dir" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" AGENT_PANEL_ATTACHMENTS=/att/dir bash "$S" --print-flags "$F/valid_role.json"
expect print_flags_add_dir_default_folder_0 0 "Tentacl/attachments" \
  env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json"

# The generated settings disable plugins and user skills the role does not list.
settings_path=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect settings_disable_unlisted_plugin_0   0 "false" jq -r '.enabledPlugins["caveman@caveman"]' "$settings_path"
expect settings_keep_listed_plugin_0        0 "null"  jq -r '.enabledPlugins["superpowers@official"]' "$settings_path"
expect settings_disable_unlisted_skill_0    0 "off"   jq -r '.skillOverrides["dropme"]' "$settings_path"
expect settings_keep_listed_skill_0         0 "null"  jq -r '.skillOverrides["keepme"]' "$settings_path"

# ---- N276: the listing sources outside enabledPlugins are turned off too ----
expect settings_plugin_from_installed_list_0   0 "false" jq -r '.enabledPlugins["hidden@market"]' "$settings_path"
expect settings_plugin_dir_off_0               0 "false" jq -r '.enabledPlugins["plugdir@skills-dir"]' "$settings_path"
expect settings_synced_plugin_off_0            0 "false" jq -r '.enabledPlugins["syncplug@inline"]' "$settings_path"
expect settings_org_skill_off_0                0 "off"   jq -r '.skillOverrides["anthropic-skills:orgdoc"]' "$settings_path"
expect settings_builtin_skill_off_0            0 "off"   jq -r '.skillOverrides["loop"]' "$settings_path"
expect settings_synced_folder_not_a_skill_0    0 "null"  jq -r '.skillOverrides["synced"]' "$settings_path"
expect settings_connectors_off_0               0 "false" jq -r '.env.ENABLE_CLAUDEAI_MCP_SERVERS' "$settings_path"
# a role matches a plugin by its marketplace name and a built-in or org skill by name
kept_path=$(mktemp -d); jq '.skills += ["market","loop","plugdir","claudeai-mcp"]' "$F/valid_role.json" > "$kept_path/dev.json"; cp "$F/dev.md" "$kept_path/"
kp=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$kept_path/dev.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect role_keeps_plugin_by_marketplace_0      0 "null" jq -r '.enabledPlugins["hidden@market"]' "$kp"
expect role_keeps_builtin_skill_0              0 "null" jq -r '.skillOverrides["loop"]' "$kp"
expect role_keeps_plugin_dir_0                 0 "null" jq -r '.enabledPlugins["plugdir@skills-dir"]' "$kp"
expect role_can_keep_connectors_0              0 "null" jq -r '.env.ENABLE_CLAUDEAI_MCP_SERVERS' "$kp"

# ---- advanced settings of a role (phase 4) ----
adv_path=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/role_advanced_ok.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect advanced_permissions_kept_0          0 "Bash(git push:*)" jq -r '.permissions.deny[0]' "$adv_path"
expect advanced_generated_still_present_0   0 "false"            jq -r '.enabledPlugins["caveman@caveman"]' "$adv_path"
ov_path=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/role_advanced_overrides.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect advanced_cannot_reenable_a_plugin_0  0 "false"            jq -r '.enabledPlugins["caveman@caveman"]' "$ov_path"
expect advanced_cannot_disable_a_kept_one_0 0 "null"             jq -r '.enabledPlugins["superpowers@official"]' "$ov_path"
expect advanced_model_does_not_change_flags_0 0 "--model sonnet" env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/role_advanced_overrides.json"
# a role without "advanced" produces exactly the settings it always did
plain_path=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
[ "$(jq -c 'keys' "$plain_path")" = '["enabledPlugins","env","outputStyle","skillOverrides","statusLine"]' ] && { echo "PASS  plain_role_settings_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  plain_role_settings_unchanged: $(jq -c keys "$plain_path")"; FAIL=$((FAIL+1)); }
# ---- output style (N83): the role's style goes into the settings file; "advanced" cannot override it ----
expect settings_output_style_builtin_cased_0 0 "Concise" jq -r '.outputStyle' "$plain_path"
OS=$(mktemp -d); cp "$F/dev.md" "$OS/dev.md"
style_of() { env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$OS/$1.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p' | xargs jq -r '.outputStyle'; }
jq '.outputStyle="Explanatory"' "$F/valid_role.json" > "$OS/a.json"
jq '.outputStyle="House style" | .advanced={outputStyle:"Learning"}' "$F/valid_role.json" > "$OS/b.json"
jq '.outputStyle="default"' "$F/valid_role.json" > "$OS/c.json"
[ "$(style_of a)" = "Explanatory" ] && { echo "PASS  output_style_explanatory"; PASS=$((PASS+1)); } || { echo "FAIL  output_style_explanatory: $(style_of a)"; FAIL=$((FAIL+1)); }
[ "$(style_of b)" = "House style" ] && { echo "PASS  advanced_cannot_override_output_style"; PASS=$((PASS+1)); } || { echo "FAIL  advanced_cannot_override_output_style: $(style_of b)"; FAIL=$((FAIL+1)); }
[ "$(style_of c)" = "Default" ] && { echo "PASS  output_style_default_cased"; PASS=$((PASS+1)); } || { echo "FAIL  output_style_default_cased: $(style_of c)"; FAIL=$((FAIL+1)); }
# ---- thinking and reply language (N220): role fields become alwaysThinkingEnabled and language; left out, nothing is written ----
jq '.thinking="on" | .language="turkish"' "$F/valid_role.json" > "$OS/t1.json"
jq '.thinking="off"' "$F/valid_role.json" > "$OS/t2.json"
jq '.language="" | .advanced={alwaysThinkingEnabled:false, language:"german"} | .thinking="on"' "$F/valid_role.json" > "$OS/t3.json"
set_of() { env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$OS/$1.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p' | xargs jq -c "$2"; }
[ "$(set_of t1 '[.alwaysThinkingEnabled, .language]')" = '[true,"turkish"]' ] && { echo "PASS  thinking_on_language_set"; PASS=$((PASS+1)); } || { echo "FAIL  thinking_on_language_set: $(set_of t1 '[.alwaysThinkingEnabled, .language]')"; FAIL=$((FAIL+1)); }
[ "$(set_of t2 '[.alwaysThinkingEnabled, has("language")]')" = '[false,false]' ] && { echo "PASS  thinking_off_no_language"; PASS=$((PASS+1)); } || { echo "FAIL  thinking_off_no_language: $(set_of t2 '[.alwaysThinkingEnabled, has("language")]')"; FAIL=$((FAIL+1)); }
[ "$(set_of t3 '[.alwaysThinkingEnabled, .language]')" = '[true,"german"]' ] && { echo "PASS  role_thinking_wins_empty_language_keeps_advanced"; PASS=$((PASS+1)); } || { echo "FAIL  role_thinking_wins_empty_language_keeps_advanced: $(set_of t3 '[.alwaysThinkingEnabled, .language]')"; FAIL=$((FAIL+1)); }
cp "$F/valid_role.json" "$OS/t4.json"
[ "$(set_of t4 '[has("alwaysThinkingEnabled"), has("language")]')" = '[false,false]' ] && { echo "PASS  thinking_default_writes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL  thinking_default_writes_nothing"; FAIL=$((FAIL+1)); }
rm -rf "$OS"
expect spawn_refuses_env_role_1             1 "env" env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/role_env_top.json"

# the instruction text a start uses is the role's own <name>.md when it exists (what the form shows), else its instructionFile
RD=$(mktemp -d); jq '.instructionFile="legacy.md" | .name="rr"' "$F/valid_role.json" > "$RD/rr.json"
echo "LEGACY TEXT" > "$RD/legacy.md"
ipath=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$RD/rr.json" 2>/dev/null | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p')
expect legacy_instruction_file_used_when_no_own_md_0 0 "LEGACY TEXT" cat "$ipath"
echo "OWN TEXT" > "$RD/rr.md"
ipath=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$RD/rr.json" 2>/dev/null | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p')
expect own_md_wins_over_instruction_file_0  0 "OWN TEXT"    cat "$ipath"
[ "$(grep -c "LEGACY TEXT" "$ipath")" = "0" ] && { echo "PASS  legacy_text_not_used_when_own_md_exists"; PASS=$((PASS+1)); } || { echo "FAIL  legacy_text_not_used_when_own_md_exists"; FAIL=$((FAIL+1)); }
rm -rf "$RD"

# ---- the role's place in the team chart (phase 5) ----
TD=$(mktemp -d); cp "$F/dev.md" "$TD/dev.md"; cp "$F/valid_project.json" "$TD/project.json"
mkrole() { jq --arg n "$1" '.name=$n | .instructionFile="dev.md"' "$F/valid_role.json" > "$TD/$1.json"; }
for r in pm reviewer dev ui_dev ghost; do mkrole "$r"; done
instr_of() { env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$TD/$1.json" "" "$TD/project.json" 2>/dev/null | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p'; }
# no team.json: the instruction file is exactly the role's text (also when the project is given)
ip=$(instr_of dev); head -c "$(wc -c < "$F/dev.md")" "$ip" | cmp -s - "$F/dev.md" && { echo "PASS  no_team_file_instructions_unchanged"; PASS=$((PASS+1)); } || { echo "FAIL  no_team_file_instructions_unchanged"; FAIL=$((FAIL+1)); }
cp "$F/team_ok.json" "$TD/team.json"
ip=$(instr_of pm);       expect pm_reports_to_the_user_0       0 "You report to: the user"        cat "$ip"
expect pm_may_give_to_everyone_below_0     0 "give tasks to: reviewer, dev, ui_dev" cat "$ip"
ip=$(instr_of reviewer); expect reviewer_reports_to_pm_0       0 "You report to: pm"              cat "$ip"
expect reviewer_may_give_to_devs_0         0 "give tasks to: dev, ui_dev"  cat "$ip"
ip=$(instr_of dev);      expect dev_reports_to_reviewer_0      0 "You report to: reviewer"        cat "$ip"
expect dev_may_give_to_nobody_0            0 "give tasks to: nobody"       cat "$ip"
expect cards_name_their_giver_0            0 'put `from: dev`'             cat "$ip"
expect dev_may_not_give_to_others_0        0 "may not give tasks to: pm, reviewer, ui_dev" cat "$ip"
expect dev_instructions_keep_the_role_text_0 0 "Test fixture instruction file"       cat "$ip"
ip=$(instr_of ghost);    expect role_not_in_chart_0            0 "not in this project's team chart" cat "$ip"
# the same rules as validate-config.sh: an invalid chart stops the start
cp "$F/team_cycle.json" "$TD/team.json"
expect invalid_team_stops_the_start_1      1 "cycle" env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$TD/dev.json" "" "$TD/project.json"
# ---- N278: the working protocol is appended after the role text ----
rm -f "$TD/team.json"
flags_instr() { env "${@:2}" AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$TD/$1.json" "" "$TD/project.json" 2>/dev/null | sed -n 's/.*--append-system-prompt-file \([^ ]*\).*/\1/p'; }
ip=$(instr_of dev); expect protocol_agent_for_dev_0 0 "## Working protocol" cat "$ip"
grep -q "PM protocol" "$ip" && { echo "FAIL  protocol_dev_has_no_pm_text"; FAIL=$((FAIL+1)); } || { echo "PASS  protocol_dev_has_no_pm_text"; PASS=$((PASS+1)); }
expect protocol_language_default_0 0 "The user's language: English." cat "$ip"
ip=$(instr_of pm); expect protocol_pm_script_path_absolute_0 0 "$ROOT/scripts/answer-question.sh <state" cat "$ip"
expect protocol_pm_for_pm_0 0 "## PM protocol" cat "$ip"
grep -q "Working protocol" "$ip" && { echo "FAIL  protocol_pm_has_no_agent_text"; FAIL=$((FAIL+1)); } || { echo "PASS  protocol_pm_has_no_agent_text"; PASS=$((PASS+1)); }
ip=$(flags_instr dev TENTACL_USER_LANGUAGE=Türkçe); expect protocol_language_from_env_0 0 "The user's language: Türkçe. Write user: lines in it." cat "$ip"
jq '.protocol=false' "$TD/dev.json" > "$TD/nop.json"; ip=$(flags_instr nop)
cmp -s "$ip" "$F/dev.md" && { echo "PASS  protocol_opt_out"; PASS=$((PASS+1)); } || { echo "FAIL  protocol_opt_out"; FAIL=$((FAIL+1)); }
jq '.protocol="no"' "$TD/dev.json" > "$TD/bad.json"
expect protocol_must_be_boolean_1 1 "protocol must be" bash "$ROOT/scripts/validate-config.sh" "$TD/bad.json"
jq '.tool="codex"' "$TD/dev.json" > "$TD/cx.json"; env AGENT_PANEL_STATE="$TD/st" bash "$S" --print-flags "$TD/cx.json" "" "$TD/project.json" >/dev/null 2>&1
expect protocol_codex_0 0 "## Working protocol" cat "$TD/st/dev/instructions.md"
rm -rf "$TD"

# ---- Codex roles (N147): print-flags shows the codex flags, one argument per element ----
CX=$(mktemp -d); cp "$F/dev.md" "$CX/dev.md"
cxrole() { jq --arg m "$1" '.permissionMode=$m | del(.advanced)' "$F/role_codex_ignored.json" > "$CX/$1.json"; }
for m in manual acceptEdits plan bypassPermissions; do cxrole $m; done
cx_flags() { env AGENT_PANEL_ATTACHMENTS=/att/dir bash "$S" --print-flags "$CX/$1.json" "${2:-}" "" "${3:-/wt/x}" 2>/dev/null; }
cx_has() { local out; out=$(cx_flags "$1" "" "${3:-}"); eval "local a=($out)"; local i; for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "$2" ] && return 0; done; return 1; }
cx_check() { local name=$1 mode=$2 want=$3; if cx_has "$mode" "$want"; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name: no '$want' in $(cx_flags "$mode")"; FAIL=$((FAIL+1)); fi; }
cx_absent() { local name=$1 mode=$2 bad=$3; if cx_has "$mode" "$bad"; then echo "FAIL  $name: found '$bad'"; FAIL=$((FAIL+1)); else echo "PASS  $name"; PASS=$((PASS+1)); fi; }
expect codex_flags_model_0              0 "-m gpt-5.5"                          bash "$S" --print-flags "$CX/acceptEdits.json"
expect codex_flags_effort_0             0 "model_reasoning_effort=high"         bash "$S" --print-flags "$CX/acceptEdits.json"
expect codex_flags_add_dir_0            0 "--add-dir /att/dir"                  env AGENT_PANEL_ATTACHMENTS=/att/dir bash "$S" --print-flags "$CX/acceptEdits.json"
expect codex_flags_no_update_check_0    0 "check_for_update_on_startup=false"   bash "$S" --print-flags "$CX/acceptEdits.json"
expect codex_flags_manual_0             0 "-s read-only -a on-request"          bash "$S" --print-flags "$CX/manual.json"
cx_absent codex_no_untrusted_manual manual untrusted
cx_absent codex_manual_no_workspace_write manual workspace-write
cx_check codex_plan_mode_effort_manual manual plan_mode_reasoning_effort=high
cx_check codex_plan_mode_effort_plan plan plan_mode_reasoning_effort=high
expect codex_flags_accept_edits_0       0 "-a on-request -s workspace-write"    bash "$S" --print-flags "$CX/acceptEdits.json"
expect codex_flags_plan_readonly_0      0 "-s read-only -a on-request"          bash "$S" --print-flags "$CX/plan.json"
expect codex_flags_bypass_explicit_0    0 "--dangerously-bypass-approvals-and-sandbox" bash "$S" --print-flags "$CX/bypassPermissions.json"
cx_absent codex_bypass_never_by_default acceptEdits --dangerously-bypass-approvals-and-sandbox
cx_absent codex_plan_no_workspace_write plan workspace-write
cx_absent codex_plan_no_untrusted plan untrusted
cx_dev() { local a; eval "a=($(cx_flags "$1"))"; local x; for x in "${a[@]}"; do case "$x" in developer_instructions=*) printf '%s' "${x#developer_instructions=}" | jq -r .;; esac; done; }
case "$(cx_dev plan)" in *"Plan only: do not edit files"*) echo "PASS  codex_plan_instruction_line"; PASS=$((PASS+1));; *) echo "FAIL  codex_plan_instruction_line"; FAIL=$((FAIL+1));; esac
case "$(cx_dev acceptEdits)" in *"Plan only"*) echo "FAIL  codex_accept_edits_no_plan_line"; FAIL=$((FAIL+1));; *) echo "PASS  codex_accept_edits_no_plan_line"; PASS=$((PASS+1));; esac
cx_absent codex_no_claude_flags_model acceptEdits --model
cx_absent codex_no_claude_flags_settings acceptEdits --settings
cx_absent codex_no_claude_flags_prompt acceptEdits --append-system-prompt-file
cx_absent codex_no_claude_flags_allowed acceptEdits --allowed-tools
# instructions: one line (a prompt line stays one line), a JSON string, same text as instructions.md
cx_dev_arg() { local l x; l=$(cx_flags acceptEdits); eval "local a=($l)"; for x in "${a[@]}"; do if [[ "$x" == developer_instructions=* ]]; then printf '%s' "$x"; fi; done; }
dev_arg=$(cx_dev_arg)
case "$dev_arg" in *$'\n'*|"") echo "FAIL  codex_instructions_one_line: '$dev_arg'"; FAIL=$((FAIL+1));; *) echo "PASS  codex_instructions_one_line"; PASS=$((PASS+1));; esac
expect codex_instructions_json_string_0 0 "Test fixture instruction file" jq -r . <<< "${dev_arg#developer_instructions=}"
expect codex_instructions_file_written_0 0 "Test fixture instruction file" cat "$AGENT_PANEL_STATE/dev/instructions.md"
# trust: the inline table form, for the worktree
cx_check codex_trust_inline_table acceptEdits 'projects={"/wt/x"={trust_level="trusted"}}'
# a codex role writes no Claude settings.json and no AGENTS.md
CXS=$(mktemp -d); AGENT_PANEL_STATE=$CXS bash "$S" --print-flags "$CX/acceptEdits.json" >/dev/null 2>&1
[ -f "$CXS/dev/instructions.md" ] && [ ! -e "$CXS/dev/settings.json" ] && rm -rf "$CXS" && { echo "PASS  codex_writes_no_claude_settings"; PASS=$((PASS+1)); } || { echo "FAIL  codex_writes_no_claude_settings"; FAIL=$((FAIL+1)); }
# a Claude role still gets the Claude flags
expect claude_role_unchanged_flags_0    0 "--permission-mode acceptEdits"       env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json"
# Claude PM golden (N365): no tool / tool claude keeps the Claude command, settings key file and permission mode
jq '.name="pm"' "$F/valid_role.json" > "$CX/cpm.json"; cp "$F/dev.md" "$CX/cpm.md"
expect pm_claude_golden_flags_0 0 "--permission-mode acceptEdits" env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" TENTACL_PM_KEY=kgold bash "$S" --print-flags "$CX/cpm.json"
grep -q kgold <(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" TENTACL_PM_KEY=kgold bash "$S" --print-flags "$CX/cpm.json") && { echo "FAIL  pm_claude_key_not_in_flags"; FAIL=$((FAIL+1)); } || { echo "PASS  pm_claude_key_not_in_flags"; PASS=$((PASS+1)); }
# the PM on Codex (N365): codex flags, workspace-write even for manual, add-dirs, no key anywhere
cp "$F/dev.md" "$CX/pm.md"; jq '.model="sonnet" | .effort="medium" | .permissionMode="manual"' "$F/role_codex_pm.json" > "$CX/pm.json"
jq -n '{id:"d",name:"D",repoPath:"/r",dataDir:"/data/d"}' > "$CX/proj.json"
pmout=$(TENTACL_PM_KEY=ksecret bash "$S" --print-flags "$CX/pm.json" "" "$CX/proj.json")
for want in "--no-daemon" "workspace-write" "--add-dir /data/d " "--add-dir /data/d/.tentacl" "--add-dir $AGENT_PANEL_STATE"; do
  case "$pmout" in *"$want"*) echo "PASS  pm_codex_has_${want//[^a-z-]/_}"; PASS=$((PASS+1));; *) echo "FAIL  pm_codex_has $want: $pmout"; FAIL=$((FAIL+1));; esac
done
case "$pmout" in *ksecret*|*shell_environment_policy*|*dangerously-bypass*|*read-only*) echo "FAIL  pm_codex_no_key_no_bypass"; FAIL=$((FAIL+1));; *) echo "PASS  pm_codex_no_key_no_bypass"; PASS=$((PASS+1));; esac
rm -rf "$CX"

# ---- commit attribution (N262): project "attribution" default | none | custom ----
AT=$(mktemp -d); cp "$F/dev.md" "$AT/dev.md"
jq '.attribution="none"' "$F/valid_project.json" > "$AT/none.json"
jq '.attribution="custom" | .attributionText="Co-Authored-By: Team <t@example.com>"' "$F/valid_project.json" > "$AT/custom.json"
jq '.attribution="custom"' "$F/valid_project.json" > "$AT/custom_empty.json"
cp "$F/valid_project.json" "$AT/default.json"
jq '.attribution="default"' "$F/valid_project.json" > "$AT/default2.json"
at_settings() { env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json" "" "$AT/$1.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p'; }
expect attribution_default_writes_nothing_0   0 "false" jq 'has("attribution")' "$(at_settings default)"
expect attribution_default_word_writes_nothing_0 0 "false" jq 'has("attribution")' "$(at_settings default2)"
expect attribution_none_commit_empty_0        0 '{"commit":"","pr":""}' jq -c '.attribution' "$(at_settings none)"
expect attribution_custom_commit_text_0       0 "Co-Authored-By: Team <t@example.com>" jq -r '.attribution.commit' "$(at_settings custom)"
expect attribution_custom_pr_text_0           0 "Co-Authored-By: Team <t@example.com>" jq -r '.attribution.pr' "$(at_settings custom)"
expect attribution_custom_without_text_is_invalid_1 1 "needs attributionText" bash "$ROOT/scripts/validate-config.sh" "$AT/custom_empty.json"
jq '.attribution="bogus"' "$F/valid_project.json" > "$AT/bogus.json"
expect attribution_unknown_value_invalid_1    1 "attribution must be" bash "$ROOT/scripts/validate-config.sh" "$AT/bogus.json"
expect attribution_none_valid_0               0 "" bash "$ROOT/scripts/validate-config.sh" "$AT/none.json"
# Codex: no setting exists, the line goes into the instructions
cp "$F/dev.md" "$AT/cdev.md"; jq '.permissionMode="acceptEdits" | del(.advanced)' "$F/role_codex_ignored.json" > "$AT/crole.json"
cx_instr() { env AGENT_PANEL_STATE="$AT/st" bash "$S" --print-flags "$AT/crole.json" "" "$AT/$1.json" /wt/x >/dev/null 2>&1; cat "$AT/st/dev/instructions.md"; }
case "$(cx_instr default)" in *"Commit attribution"*) echo "FAIL  attribution_codex_default_no_line"; FAIL=$((FAIL+1));; *) echo "PASS  attribution_codex_default_no_line"; PASS=$((PASS+1));; esac
case "$(cx_instr none)" in *"do not add any co-author"*) echo "PASS  attribution_codex_none_line"; PASS=$((PASS+1));; *) echo "FAIL  attribution_codex_none_line"; FAIL=$((FAIL+1));; esac
case "$(cx_instr custom)" in *"exactly this line"*"Co-Authored-By: Team <t@example.com>"*) echo "PASS  attribution_codex_custom_line"; PASS=$((PASS+1));; *) echo "FAIL  attribution_codex_custom_line"; FAIL=$((FAIL+1));; esac
rm -rf "$AT"

# ---- plan usage: every agent's status line records the rate limits (N72) ----
SL_PATH=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$F/valid_role.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect statusline_is_command_0          0 "command" jq -r '.statusLine.type' "$SL_PATH"
expect statusline_runs_usage_script_0   0 "usage-statusline.sh" jq -r '.statusLine.command' "$SL_PATH"
SLR=$(mktemp -d); jq '.advanced = {statusLine: {type: "command", command: "echo mine"}}' "$F/valid_role.json" > "$SLR/r.json"; cp "$F"/*.md "$SLR/" 2>/dev/null
SLR_PATH=$(env AGENT_PANEL_CLAUDE_HOME="$FAKE_HOME" bash "$S" --print-flags "$SLR/r.json" 2>/dev/null | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
expect statusline_chains_roles_own_0    0 "echo\\ mine" jq -r '.statusLine.command' "$SLR_PATH"
expect statusline_chain_still_ours_0    0 "usage-statusline.sh" jq -r '.statusLine.command' "$SLR_PATH"
rm -rf "$SLR"

# ---- a terminal that cannot be reached, on a throwaway repo (a real agent run through tentacld is in term-tentacl.test.sh) ----
REPO=$(mktemp -d /tmp/agent-panel-test.XXXXXX)
git -C "$REPO" init -q -b main && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
PROJECT="$REPO.project.json"
jq --arg r "$REPO" '.repoPath=$r' "$F/valid_project.json" > "$PROJECT"
trap 'rm -rf "$REPO" "$PROJECT"' EXIT

expect invalid_role_blocks_start_1       1 "ERROR:" bash "$S" "$PROJECT" "$F/missing_model.json" t1 test/t1
expect terminal_down_clear_error_1       1 "tentacld does not answer" \
  env TENTACL_SOCKET=/nonexistent/sock TENTACLD=/nonexistent/tentacld bash "$S" "$PROJECT" "$F/valid_role.json" t1 test/t1
if [ -n "$(git -C "$REPO" branch --list 'test/t1')" ]; then echo "FAIL  terminal_down_leaves_no_branch: branch test/t1 exists"; FAIL=$((FAIL+1)); else echo "PASS  terminal_down_leaves_no_branch"; PASS=$((PASS+1)); fi

# Rollback after a failed start is covered deterministically in spawn-agent-fake.test.sh.
finish
