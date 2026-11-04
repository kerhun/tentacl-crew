#!/usr/bin/env bash
# term.sh backend for Tentacl's own terminal daemon, tentacld (see term.sh for the commands). One tentacld session per agent: the
# session id is the agent name, which is also its pane id and workspace id. `open` starts a login shell in the folder, `start` types
# the `exec <tool> ...` line into it. The agent's state (working/idle/blocked/done) comes from the last
# OSC 7501 record the daemon keeps per session (error -> blocked; its seq/completion_seq counters feed state_change_seq/completion_seq);
# the state files agent-state-hook.sh writes are only the fallback for a program with no live 7501 record. alive/exit from the daemon.
# Every answer is {"result":...} or {"error":{code,message}}.
# Env: TENTACL_SOCKET (default ~/Library/Application Support/Tentacl/term.sock): the daemon's socket; tests use their own.
#      TENTACLD: the tentacld executable started once when nothing answers on the socket (default: the helper inside Tentacl.app).
#      AGENT_PANEL_START_TIMEOUT_MS (default 60000): how long `start` waits for the first 7501 record or the SessionStart state file.
#      AGENT_PANEL_CACHE (default ~/.cache/agent-panel): where the state files live.
#      AGENT_PANEL_OPEN (default open): how `focus` activates Tentacl.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TIMEOUT=${AGENT_PANEL_START_TIMEOUT_MS:-60000}
CACHE=${AGENT_PANEL_CACHE:-$HOME/.cache/agent-panel}
SOCK=${TENTACL_SOCKET:-$HOME/Library/Application Support/Tentacl/term.sock}

err() { jq -nc --arg c "$1" --arg m "$2" '{error:{code:$c, message:$m}}'; exit "${3:-1}"; }
need() { [ "$1" -ge "$2" ] || err usage "$3" 2; }
valid_name() { case "$1" in ""|*[!A-Za-z0-9._-]*|.|..) err usage "bad agent name: $1" 2 ;; esac; }
command -v jq >/dev/null 2>&1 || err unreachable "jq is not installed"
command -v nc >/dev/null 2>&1 || err unreachable "nc is not installed"

# raw <json request>: one request, one connection; prints the reply line (nothing when the daemon does not answer).
raw() { printf '%s\n' "$1" | nc -U -w 10 "$SOCK" 2>/dev/null | head -n 1; }

# helper: the tentacld executable (Env TENTACLD, else the one inside Tentacl.app / Tentacl Dev.app next to or under /Applications).
helper() {
  [ -n "${TENTACLD:-}" ] && { printf '%s' "$TENTACLD"; return; }
  local c
  for c in "/Applications/Tentacl.app" "$HOME/Applications/Tentacl.app" "/Applications/Tentacl Dev.app" "$HOME/Applications/Tentacl Dev.app"; do
    [ -x "$c/Contents/Helpers/tentacld" ] && { printf '%s' "$c/Contents/Helpers/tentacld"; return; }
  done
}

# ensure: starts the daemon once when nothing answers, then waits up to 5 s.
ensure() {
  [ -n "$(raw '{"verb":"ping"}')" ] && return 0
  local h; h=$(helper)
  [ -n "$h" ] && [ -x "$h" ] || err unreachable "tentacld does not answer on $SOCK and no tentacld executable was found (set TENTACLD)"
  mkdir -p "$(dirname "$SOCK")" 2>/dev/null
  nohup "$h" --socket "$SOCK" >/dev/null 2>&1 </dev/null &
  local i; for i in $(seq 1 100); do
    [ -n "$(raw '{"verb":"ping"}')" ] && return 0
    sleep 0.05
  done
  err unreachable "tentacld did not answer on $SOCK"
}

# td <json request>: runs a verb; on success $TD holds the reply, on failure prints the error answer and exits 1.
td() {
  ensure
  TD=$(raw "$1")
  [ -n "$TD" ] || err unreachable "tentacld did not answer on $SOCK"
  if [ "$(jq -r '.ok // false' <<< "$TD" 2>/dev/null)" != true ]; then err tentacl_error "$(jq -r '.error // "tentacld error"' <<< "$TD" 2>/dev/null)"; fi
}
# tdq: like td, but an unreachable daemon is not started and reads as an empty answer (a list of nothing).
tdq() {
  TD=$(raw "$1")
  [ -n "$TD" ] || { TD='{"ok":true,"sessions":[]}'; return 0; }
  if [ "$(jq -r '.ok // false' <<< "$TD" 2>/dev/null)" != true ]; then err tentacl_error "$(jq -r '.error // "tentacld error"' <<< "$TD" 2>/dev/null)"; fi
}
# target <agent name or pane id>: the session id (the id of a pane is the name).
target() { valid_name "$1"; printf '%s' "$1"; }
# write_text <id> <text>: types the text (UTF-8) into the session.
write_text() { td "$(jq -nc --arg id "$1" --arg t "$2" '{verb:"write", id:$id, text:$t}')"; }

# Adds the state hook to the settings file given with --settings, so Claude reports its state without any install.
add_hooks() {
  local file=$1 cmd tmp; cmd="bash $(printf '%q' "$HERE/agent-state-hook.sh")"
  [ -f "$file" ] || return 0
  tmp=$(mktemp) || return 0
  if jq --arg cmd "$cmd" '
      ([ "SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop","SessionEnd" ]) as $ev
      | .hooks = ((.hooks // {}) as $h | reduce $ev[] as $e ($h; .[$e] = ((.[$e] // []) + [{hooks: [{type: "command", command: $cmd}]}])))' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else rm -f "$tmp"; fi
}

# wake_if_sleeping <name>: an agent put to sleep by the app (a marker in $CACHE/sleeping) is started again in its worktree, same session, before a prompt.
wake_if_sleeping() {
  local m="$CACHE/sleeping/$1.json" s src role card branch out
  [ -f "$m" ] || return 0
  s=$(jq -r '.worktree // empty' "$m" 2>/dev/null)
  if [ -n "$s" ] && [ ! -d "$s" ]; then rm -f "$m"; err wake_failed "$1's worktree is gone; it cannot be woken"; fi
  tdq '{"verb":"list"}'
  if ! jq -e --arg id "$1" '[.sessions[] | select(.id == $id and .alive == true)] | length == 1' <<< "$TD" >/dev/null; then
    s=$(jq -r '.session // empty' "$m"); src=$(jq -r '.source // empty' "$m"); role=$(jq -r '.role // empty' "$m")
    card=$(jq -r '.card // empty' "$m"); branch=$(jq -r '.branch // empty' "$m")
    [ -n "$s" ] && [ -n "$src" ] && [ -n "$role" ] && [ -n "$card" ] && [ -n "$branch" ] || err wake_failed "the sleep marker of $1 is incomplete"
    out=$(bash "$HERE/spawn-agent.sh" --resume "$s" "$src" "$role" "$card" "$branch" 2>&1 >/dev/null) || err wake_failed "could not wake $1: $(printf '%s' "$out" | tail -n 1)"
  fi
  rm -f "$m"
}

cmd=${1:-}; shift
case "$cmd" in
  ping)    td '{"verb":"ping"}'; jq -nc '{result:{backend:"tentacl", socket:$s}}' --arg s "$SOCK" ;;
  list-workspaces)
           tdq '{"verb":"list"}'
           jq -c '{result:{workspaces: [.sessions[] | {id: .id, workspace_id: .id, label: .id, cwd: (.cwd // null)}]}}' <<< "$TD" ;;
  list-agents)
           tdq '{"verb":"list"}'
           out='[]'
           while IFS='|' read -r s alive exitc cwd; do
             [ -n "$s" ] || continue
             st=$(jq -c . "$CACHE/$s/state.json" 2>/dev/null); [ -n "$st" ] || st=null
             osc=$(jq -c --arg id "$s" '[.sessions[] | select(.id == $id) | .status | select(. != null and .live == true)] | first // null' <<< "$TD")
             out=$(jq -c --arg s "$s" --arg alive "$alive" --arg exitc "$exitc" --arg cwd "$cwd" --argjson st "$st" --argjson osc "$osc" \
               '. + [{name: $s, pane_id: $s, workspace_id: $s, cwd: $cwd, title: $s,
                      alive: ($alive == "true"), exit: (if $exitc == "" then null else ($exitc | tonumber) end),
                      agent_status: (if $alive != "true" then "unknown"
                                     elif $osc != null then ({working: "working", idle: "idle", done: "done", blocked: "blocked", error: "blocked"}[$osc.state] // "unknown")
                                     elif $st == null then "unknown" else $st.status end),
                      completion_seq: (if $osc != null then ($osc.completion_seq // 0) else ($st.completion_seq // 0) end),
                      state_change_seq: (if $osc != null then ($osc.seq // 0) else ($st.seq // 0) end),
                      session_id: ($st.session_id // null)}]' <<< "$out")
           done < <(jq -r '.sessions[] | [.id, (.alive|tostring), (.exit // "" | tostring), .cwd] | join("|")' <<< "$TD")
           # sleeping agents (N261): no session, a marker the app wrote; a prompt to one wakes it
           for f in "$CACHE"/sleeping/*.json; do
             [ -f "$f" ] || continue
             # the worktree is gone (card merged, cancelled or cleaned up): the marker is stale
             w=$(jq -r '.worktree // empty' "$f" 2>/dev/null); [ -z "$w" ] || [ -d "$w" ] || { rm -f "$f"; continue; }
             out=$(jq -c --slurpfile m "$f" '($m[0]) as $m | if any(.[]; .name == $m.agent) then . else . + [{name: $m.agent, pane_id: $m.agent, workspace_id: $m.agent, cwd: "", title: $m.agent,
                      alive: false, exit: null, agent_status: "sleeping", completion_seq: 0, state_change_seq: 0, session_id: $m.session, card: $m.card, sleeping: true}] end' <<< "$out" 2>/dev/null) || continue
           done
           jq -nc --argjson a "$out" '{result:{agents:$a}}' ;;
  open)    need $# 2 "usage: term.sh open <name> <cwd>"; valid_name "$1"
           [ -d "$2" ] || err tentacl_error "no such folder: $2"
           sh=${SHELL:-/bin/zsh}; [ -x "$sh" ] || sh=/bin/sh
           td "$(jq -nc --arg id "$1" --arg sh "$sh" --arg cwd "$2" '{verb:"spawn", id:$id, argv:[$sh, "-l"], cwd:$cwd, env:{AGENT_PANEL_AGENT:$id}}')"
           jq -nc --arg n "$1" '{result:{workspace:{workspace_id:$n}, root_pane:{pane_id:$n}}}' ;;
  close)   need $# 1 "usage: term.sh close <workspace_id>"; valid_name "$1"
           td "$(jq -nc --arg id "$1" '{verb:"kill", id:$id}')"
           # a session that had already ended is only removed by the first kill; a live one is ended, then removed
           for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
             tdq '{"verb":"list"}'
             jq -e --arg id "$1" '[.sessions[] | select(.id == $id)] | length == 0' <<< "$TD" >/dev/null && break
             raw "$(jq -nc --arg id "$1" '{verb:"kill", id:$id}')" >/dev/null; sleep 0.2
           done
           rm -rf "${CACHE:?}/${1:?}"; jq -nc '{result:{type:"ok"}}' ;;
  start)   need $# 4 "usage: term.sh start <name> <pane> <tool> -- <flags...>"
           name=$1; pane=$2; tool=$3; shift 3; [ "${1:-}" = "--" ] && shift; valid_name "$name"; valid_name "$pane"
           case "$tool" in claude|codex) ;; *) err usage "unknown tool: $tool" 2 ;; esac
           if [ "$tool" = claude ]; then
             prev=""; for a in "$@"; do [ "$prev" = "--settings" ] && add_hooks "$a"; prev=$a; done
           fi
           rm -f "$CACHE/$name/state.json"
           bin=$(command -v "$tool" 2>/dev/null); [ -n "$bin" ] || bin=$tool   # the daemon's login PATH finds it otherwise
           line="exec env AGENT_PANEL_TOOL=$tool"
           [ -n "${AGENT_PANEL_CACHE:-}" ] && line="$line AGENT_PANEL_CACHE=$(printf '%q' "$AGENT_PANEL_CACHE")"
           line="$line $(printf '%q' "$bin")"; for a in "$@"; do line="$line $(printf '%q' "$a")"; done
           write_text "$pane" "$line"; sleep 0.1; write_text "$pane" $'\r'
           tries=$(( TIMEOUT / 200 + 1 ))
           while [ $tries -gt 0 ]; do
             [ -f "$CACHE/$name/state.json" ] && { jq -nc '{result:{type:"agent_started"}}'; exit 0; }
             tdq '{"verb":"list"}'
             jq -e --arg id "$pane" '[.sessions[] | select(.id == $id and .status.live == true)] | length == 1' <<< "$TD" >/dev/null && { jq -nc '{result:{type:"agent_started"}}'; exit 0; }
             jq -e --arg id "$pane" '[.sessions[] | select(.id == $id and .alive == true)] | length == 1' <<< "$TD" >/dev/null || err agent_not_ready "the session of $name ended before the agent was ready"
             sleep 0.2; tries=$((tries - 1))
           done
           err agent_not_ready "no 7501 record or SessionStart state from $name within ${TIMEOUT} ms" ;;
  read)    need $# 2 "usage: term.sh read <target> <lines>"
           case "$2" in ""|*[!0-9]*) err usage "lines must be a number" 2 ;; esac
           td "$(jq -nc --arg id "$(target "$1")" --argjson n "$2" '{verb:"read", id:$id, lines:$n}')"
           jq -c '{result:{text:(.text // "")}}' <<< "$TD" ;;
  prompt)  need $# 2 "usage: term.sh prompt <target> <text>"; t=$(target "$1")
           wake_if_sleeping "$t"
           # bracketed paste, so a multi-line prompt stays one message; then Enter once the TUI has taken it
           write_text "$t" "$(printf '\033[200~%s\033[201~' "$2")"
           sleep 0.2
           write_text "$t" $'\r'; jq -nc '{result:{type:"agent_prompted"}}' ;;
  keys)    need $# 2 "usage: term.sh keys <target> <key...>"; t=$(target "$1"); shift; seq_=""
           for k in "$@"; do case "$k" in enter) seq_+=$'\r' ;; esc) seq_+=$'\033' ;; tab) seq_+=$'\t' ;; up) seq_+=$'\033[A' ;; down) seq_+=$'\033[B' ;;
                                      [0-9]*) case "$k" in *[!0-9]*) err usage "unknown key: $k" 2 ;; esac; seq_+="$k" ;; *) err usage "unknown key: $k" 2 ;; esac; done
           write_text "$t" "$seq_"; jq -nc '{result:{type:"ok"}}' ;;
  text)    need $# 2 "usage: term.sh text <target> <text>"; write_text "$(target "$1")" "$2"; jq -nc '{result:{type:"ok"}}' ;;
  focus)   need $# 1 "usage: term.sh focus <target>"; valid_name "$1"
           ${AGENT_PANEL_OPEN:-open} -a Tentacl >/dev/null 2>&1 || err focus_failed "could not open Tentacl"
           jq -nc '{result:{type:"ok"}}' ;;
  *)       err usage "unknown command: ${cmd:-}" 2 ;;
esac
