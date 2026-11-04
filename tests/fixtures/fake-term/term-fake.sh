#!/usr/bin/env bash
# Test double for the terminal behind term.sh (AGENT_PANEL_TERM_SCRIPT points here). Answers like term-tentacl.sh; state lives in
# $FAKE_TERM_STATE: calls.log (one line per call, plus "ARG:<flag>" per argument of start), sessions (name<TAB>cwd per open session),
# agent_seq / cseq (queues of statuses and completion counters, one per list-agents call), screen (what `read` shows).
# FAKE_START=fail / FAKE_PROMPT=fail make start / prompt answer with an error.
S=${FAKE_TERM_STATE:?}; mkdir -p "$S"; echo "$*" >> "$S/calls.log"
cmd=${1:-}; shift
ok() { jq -nc '{result:{type:"ok"}}'; }
case "$cmd" in
  ping) jq -nc '{result:{backend:"fake"}}' ;;
  list-workspaces)
    jq -Rsc '{result:{workspaces: [split("\n")[] | select(length > 0) | split("\t") | {id: .[0], workspace_id: .[0], label: .[0], cwd: .[1]}]}}' < <(cat "$S/sessions" 2>/dev/null) ;;
  list-agents)
    seq="$S/agent_seq"; touch "$seq" "$S/cseq"; st=$(head -n1 "$seq" 2>/dev/null); [ -n "$st" ] || st=idle
    [ "$(wc -l < "$seq" 2>/dev/null || echo 0)" -gt 1 ] && sed -i '' '1d' "$seq"
    cs=$(head -n1 "$S/cseq" 2>/dev/null); [ "$(wc -l < "$S/cseq" 2>/dev/null || echo 0)" -gt 1 ] && sed -i '' '1d' "$S/cseq"
    jq -Rsc --arg s "$st" --arg cs "$cs" '{result:{agents: [split("\n")[] | select(length > 0) | split("\t") | {pane_id: .[0], name: .[0], workspace_id: .[0], cwd: .[1], agent_status: $s} + (if $cs != "" then {completion_seq: ($cs|tonumber)} else {} end)]}}' < <(cat "$S/sessions" 2>/dev/null) ;;
  open) printf '%s\t%s\n' "$1" "$2" >> "$S/sessions"
    jq -nc --arg n "$1" '{result:{workspace:{workspace_id:$n}, root_pane:{pane_id:$n}}}' ;;
  close) echo "CLOSED:$1" >> "$S/calls.log"; grep -v "^$1	" "$S/sessions" > "$S/sessions.new" 2>/dev/null; mv "$S/sessions.new" "$S/sessions" 2>/dev/null; ok ;;
  start)
    shift 3; [ "${1:-}" = "--" ] && shift; echo "start-args:" >> "$S/calls.log"; for a in "$@"; do echo "ARG:$a" >> "$S/calls.log"; done
    if [ "${FAKE_START:-ok}" = fail ]; then jq -nc '{error:{code:"agent_not_ready", message:"blocked during startup"}}'; exit 1; fi
    jq -nc '{result:{type:"agent_started"}}' ;;
  prompt)
    if [ "${FAKE_PROMPT:-ok}" = fail ]; then jq -nc '{error:{code:"no_such_agent", message:"agent not found"}}'; exit 1; fi
    jq -nc '{result:{type:"agent_prompted"}}' ;;
  read) jq -Rsc '{result:{text:.}}' < <(cat "$S/screen" 2>/dev/null) ;;
  keys|text|focus) ok ;;
  *) jq -nc --arg c "$cmd" '{error:{code:"usage", message:("unknown command: " + $c)}}'; exit 2 ;;
esac
