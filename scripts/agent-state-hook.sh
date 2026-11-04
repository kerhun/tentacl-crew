#!/usr/bin/env bash
# Agent state hook for Claude Code and Codex: reads one hook event (JSON) on stdin and atomically writes
# <cache>/<agent>/state.json = {v, agent, tool, status, session_id, seq, completion_seq, updated_at}.
# SessionStart -> idle; UserPromptSubmit/PreToolUse/PostToolUse -> working; PermissionRequest or
# Notification(permission_prompt|elicitation_dialog) -> blocked; Stop -> done (completion_seq + 1); SessionEnd -> file removed.
# Does nothing when AGENT_PANEL_AGENT is not set (the Codex hook is global). Always exits 0; no network.
# Env: AGENT_PANEL_AGENT (agent name), AGENT_PANEL_TOOL (claude|codex, default claude),
#      AGENT_PANEL_CACHE (default ~/.cache/agent-panel; tests override it).
trap 'exit 0' EXIT
agent=${AGENT_PANEL_AGENT:-}
[ -n "$agent" ] || exit 0
case "$agent" in *[!A-Za-z0-9._-]*|.|..) exit 0 ;; esac
input=$(cat)
dir=${AGENT_PANEL_CACHE:-$HOME/.cache/agent-panel}/$agent
file=$dir/state.json

parsed=$(printf '%s' "$input" | jq -r '.hook_event_name // "", .notification_type // "", .session_id // ""' 2>/dev/null) || exit 0
{ IFS= read -r event; IFS= read -r ntype; IFS= read -r sid; } <<< "$parsed"
case "$event" in
  SessionStart) status=idle ;;
  UserPromptSubmit|PreToolUse|PostToolUse) status=working ;;
  PermissionRequest) status=blocked ;;
  Notification) case "$ntype" in permission_prompt|elicitation_dialog) status=blocked ;; *) exit 0 ;; esac ;;
  Stop) status=done ;;
  SessionEnd) rm -f "$file" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac

mkdir -p "$dir" 2>/dev/null || exit 0
old=$(jq -c . "$file" 2>/dev/null)   # empty when missing or corrupt
tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || exit 0
if printf '%s' "${old:-null}" | jq -c --arg agent "$agent" --arg tool "${AGENT_PANEL_TOOL:-claude}" --arg status "$status" --arg sid "$sid" \
     --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  (if type == "object" then . else {} end) as $o
  | {v: 1, agent: $agent, tool: $tool, status: $status,
     session_id: (if $sid != "" then $sid else ($o.session_id // "") end),
     seq: (($o.seq // 0) + 1),
     completion_seq: (($o.completion_seq // 0) + (if $status == "done" then 1 else 0 end)),
     updated_at: $now}' > "$tmp" 2>/dev/null; then
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
else
  rm -f "$tmp"
fi
exit 0
