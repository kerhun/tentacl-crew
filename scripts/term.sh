#!/usr/bin/env bash
# The one way the scripts reach the terminal: Tentacl's own terminal daemon (scripts/term-tentacl.sh). Tests may point AGENT_PANEL_TERM_SCRIPT at a fake.
# Usage: term.sh <command> [args]
#   ping                               is the terminal reachable
#   list-agents                        {"result":{"agents":[{name, pane_id, workspace_id, agent_status, completion_seq, ...}]}}; agent_status "sleeping" = put to sleep by the panel
#   list-workspaces                    {"result":{"workspaces":[{id, workspace_id, label, cwd}]}} (cwd may be null)
#   open <name> <cwd>                  a workspace named <name> in <cwd>: {"result":{"workspace":{workspace_id},"root_pane":{pane_id}}}
#   close <workspace_id>               close that workspace
#   start <name> <pane> <tool> -- <flags...>   start the agent tool (claude or codex) in that pane; waits until it is ready
#   read <target> <lines>              {"result":{"text":"<the visible screen>"}}
#   prompt <target> <text>             send a prompt and press Enter (an agent that is sleeping is woken first, same session)
#   keys <target> <key...>             enter, esc, tab, up, down or digits
#   text <target> <text>               type text without Enter
#   focus <target>                     bring that agent to the front
# Output is always one JSON line: {"result":...} or {"error":{"code","message"}}. Exit 0 with a result, 1 with an error, 2 on misuse.
# <target> is a pane id or an agent name.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
fail() { jq -nc --arg c "$1" --arg m "$2" '{error:{code:$c, message:$m}}'; exit 2; }

[ $# -ge 1 ] || fail usage "usage: term.sh <command> [args]"
impl=${AGENT_PANEL_TERM_SCRIPT:-$HERE/term-tentacl.sh}
[ -f "$impl" ] || fail unreachable "terminal script not found: $impl"
exec bash "$impl" "$@"
