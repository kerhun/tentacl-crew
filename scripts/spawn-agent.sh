#!/usr/bin/env bash
# Starts one agent in its own git worktree and its own simulator; the terminal is reached through term.sh only.
# Usage: spawn-agent.sh <project.json> <role.json> <task-id> <branch>
#        spawn-agent.sh --no-card <project.json> <role.json>   (a session on no card, in the project folder: no branch, worktree or simulator; the PM)
#        spawn-agent.sh --resume <session-id> <project.json> <role.json> <task-id> <branch>   (the same agent again in its existing worktree and branch,
#                       continuing that conversation: claude --resume <id>, codex resume <id>; the worktree is reused, never created or reset)
#        spawn-agent.sh --resume <session-id> --no-card <project.json> <role.json>   (the PM again, in the project folder)
#        spawn-agent.sh --print-flags <role.json> [udid] [project.json] [worktree]   (print the flags for the role's tool, claude or codex; start nothing)
# Prints one JSON line on success: {"agent","workspace_id","pane_id","worktree_path","udid"}.
# Refuses a branch that already exists, so a failed start can never delete someone's commits.
# Env: AGENT_PANEL_CLAUDE_HOME (default ~/.claude), AGENT_PANEL_STATE (default ~/.cache/agent-panel),
#      AGENT_PANEL_START_TIMEOUT_MS (default 60000), AGENT_PANEL_SIM_SCRIPT (default scripts/sim-for-agent.sh),
#      AGENT_PANEL_ATTACHMENTS (default ~/Library/Application Support/Tentacl/attachments: images sent from the Command box; agents may read it).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME=${AGENT_PANEL_CLAUDE_HOME:-$HOME/.claude}
STATE=${AGENT_PANEL_STATE:-$HOME/.cache/agent-panel}
TIMEOUT=${AGENT_PANEL_START_TIMEOUT_MS:-60000}
SIM=${AGENT_PANEL_SIM_SCRIPT:-$HERE/sim-for-agent.sh}
ATTACHMENTS=${AGENT_PANEL_ATTACHMENTS:-$HOME/Library/Application Support/Tentacl/attachments}   # keep in step with Attachments.defaultRoot

die() { echo "ERROR: $*" >&2; exit 1; }

# team_section <team.json> <role-name>: the "Your place in the team" text for that role (the chart is already validated).
team_section() {
  local team=$1 r=$2
  printf '\n## Your place in the team\n'
  jq -r --arg r "$r" '
    .members as $m
    | ($m | map({key: .role, value: .reportsTo}) | from_entries) as $boss
    | def above($x): [$x | recurse($boss[.]; . != null)] | .[1:];
      ([$m[].role] | index($r)) as $present
    | if $present == null then
        "You are not in this project'"'"'s team chart: you report to the user and may not give tasks to anyone."
      else
        ([$m[].role | select(. != $r) | select(above(.) | any(. == $r))]) as $below
        | ([$m[].role | select(. != $r) | select(($below | index(.)) == null)]) as $others
        | "You are the role \"\($r)\".",
          "You report to: \($boss[$r] // "the user").",
          "You may give tasks to: \(if ($below | length) == 0 then "nobody" else ($below | join(", ")) end).",
          (if ($others | length) == 0 then empty else "You may not give tasks to: \($others | join(", ")). Someone at your level or above can only be asked through your manager (or the user)." end),
          "When you write a task card for someone below you, put `from: \($r)` in its front matter.",
          "Report to your manager in the Report section of your task card. If you find problems in work done by someone below you, write them in the Fix notes section of that card."
      end' "$team"
}

# role_tool <role.json>: claude or codex, from the role file (the PM too; a session on no card follows its role's tool).
role_tool() { jq -r '.tool // "claude"' "$1"; }

# build_flags <role.json> <agent-name> [udid] [project.json]: fills the FLAGS array (one element per argument, so spaces survive)
# for the role's tool (claude unless the role says codex) and writes the agent's instructions file. WORKTREE is the folder the agent runs in.
build_flags() {
  if [ "$(role_tool "$1")" = codex ]; then build_flags_codex "$@"; else build_flags_claude "$@"; fi
}

# write_instructions <role.json> <agent-name> [udid] [project.json]: validates the role and writes $STATE/<name>/instructions.md
# (role text, plus its simulator when a UDID is given, plus its place in the team). Sets OUT to that path. Both tools use this text.
write_instructions() {
  local role=$1 name=$2 udid=${3:-} project=${4:-} dir instr team
  bash "$HERE/validate-config.sh" "$role" >&2 || exit 1
  dir=$(cd "$(dirname "$role")" && pwd)
  instr="$dir/$(jq -r '.instructionFile' "$role")"
  # The role's own <name>.md next to its file wins: that is the text the Team screen shows and edits.
  own="$dir/$(basename "$role" .json).md"; [ -f "$own" ] && instr=$own
  [ -f "$instr" ] || die "instruction file not found: $instr"
  mkdir -p "$STATE/$name"; out="$STATE/$name/instructions.md"
  cat "$instr" > "$out"
  if [ -n "$udid" ]; then
    printf '\n## Your simulator\nUse only the simulator with UDID %s for installs, launches and screenshots. Never use `booted`: other agents run their own simulators. Put derived data in `build/dd` inside your worktree.\n' "$udid" >> "$out"
  fi
  # The role's place in the project's team chart (team.json next to project.json), when the project has one. An invalid chart stops
  # the start. Only validated role names are written into the text.
  team=""
  [ -n "$project" ] && [ -f "$(dirname "$project")/team.json" ] && team="$(cd "$(dirname "$project")" && pwd)/team.json"
  if [ -n "$team" ]; then
    bash "$HERE/validate-config.sh" "$team" >&2 || die "the team chart $team is invalid; fix it (or remove it) before starting an agent"
    team_section "$team" "$(jq -r .name "$role")" >> "$out"
  fi
  # The app's working protocol (scripts/protocol), after the role text; the PM gets pm.md. A role opts out with "protocol": false.
  if [ "$(jq -r '.protocol == false' "$role")" = false ]; then
    local proto=agent.md
    if [ "$(jq -r .name "$role")" = pm ] || [ -n "${nocard:-}" ]; then proto=pm.md; fi
    { printf '\n'; sed "s|{{SCRIPTS}}|$HERE|g" "$HERE/protocol/$proto"; printf "\nThe user's language: %s.%s\n" "${TENTACL_USER_LANGUAGE:-English}" "${TENTACL_USER_LANGUAGE:+ Write user: lines in it.}"; } >> "$out"
  fi
}

# project_attribution <project.json>: prints "none", or "custom" then the text on the next line; prints nothing for "default" (today's behaviour).
# A custom setting without text counts as default.
project_attribution() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  local mode text
  mode=$(jq -r '.attribution // "default"' "$1"); text=$(jq -r '.attributionText // ""' "$1")
  case "$mode" in
    none) echo none ;;
    custom) [ -n "$text" ] && { echo custom; printf '%s\n' "$text"; } ;;
  esac
  return 0
}

# build_flags_claude: the claude flags and the generated settings file.
build_flags_claude() {
  local role=$1 name=$2 out settings t attr_mode attr_text
  write_instructions "$@"; out="$STATE/$name/instructions.md"; settings="$STATE/$name/settings.json"
  { read -r attr_mode; read -r attr_text; } < <(project_attribution "${4:-}")
  # Disable every installed plugin and user skill that the role does not list. The role's "advanced" settings are kept, except
  # enabledPlugins and skillOverrides, which belong to the skills list alone.
  # Every agent's status line records the plan usage (usage-statusline.sh); a command the role set itself runs first inside it.
  local own_sl sl_cmd
  own_sl=$(jq -r '.advanced.statusLine.command // empty' "$role")
  sl_cmd=$(printf '%q' "$HERE/usage-statusline.sh"); [ -n "$own_sl" ] && sl_cmd="$sl_cmd $(printf '%q' "$own_sl")"
  sl_cmd="bash $sl_cmd"
  # The output style is the role's field (built-in names in the casing Claude Code expects, it is case-sensitive); "advanced" cannot override it.
  # thinking on/off becomes alwaysThinkingEnabled and language becomes language; left out of the role, they are not written (and "advanced" may set them).
  # Everything that adds to the skill listing and is not in the role's list is turned off (smaller fixed context, N276). Sources:
  # plugins (enabledPlugins of the user settings, installed_plugins.json, user skill folders shaped like a plugin = <name>@skills-dir,
  # synced plugins = <name>@inline), user skill folders, org skills (skills/synced/*/<skill> = anthropic-skills:<skill>) and the built-in skills below.
  # A role entry matches a plugin by its name or marketplace, a skill by its name. claude.ai connectors are switched off by env
  # ENABLE_CLAUDEAI_MCP_SERVERS=false (settings key "env"; verified) unless the role lists "claudeai-mcp".
  # shortcut: the built-in list is fixed (Claude Code has no command that lists it); extend it when a new built-in skill shows up.
  local plugins skills org builtin
  plugins=$({ jq -r '.enabledPlugins // {} | keys[]' "$CLAUDE_HOME/settings.json"; jq -r '.plugins // {} | keys[]' "$CLAUDE_HOME/plugins/installed_plugins.json"
              for f in "$CLAUDE_HOME"/skills/*/.claude-plugin/plugin.json; do [ -f "$f" ] && echo "$(jq -r .name "$f")@skills-dir"; done
              for d in "$CLAUDE_HOME"/plugins/synced/*/*/; do [ -d "${d}skills" ] && echo "$(basename "$d")@inline"; done; } 2>/dev/null | sort -u | jq -R . | jq -sc .)
  skills=$(ls -1 "$CLAUDE_HOME/skills" 2>/dev/null | grep -vx synced | jq -R . | jq -sc .)
  org=$(ls -1 "$CLAUDE_HOME"/skills/synced/*/ 2>/dev/null | grep -v '\.json$' | jq -R . | jq -sc .)
  builtin='["design","design-sync","dataviz","update-config","verify","debug","code-review","simplify","batch","fewer-permission-prompts","doctor","loop","schedule","claude-api","run","run-skill-generator","plugin-authoring","artifact-design","artifact-diagramming","artifact-capabilities","init","security-review","keybindings-help"]'
  jq -n --slurpfile role "$role" --arg statusline "$sl_cmd" --argjson plugins "$plugins" --argjson skills "$skills" --argjson org "$org" --argjson builtin "$builtin" '
    ($role[0].skills) as $keep
    | (($role[0].advanced // {}) | del(.enabledPlugins, .skillOverrides, .statusLine)) + {
        outputStyle: ({default: "Default", proactive: "Proactive", concise: "Concise", explanatory: "Explanatory", learning: "Learning"}[$role[0].outputStyle | ascii_downcase] // $role[0].outputStyle)
      } + ({on: {alwaysThinkingEnabled: true}, off: {alwaysThinkingEnabled: false}}[$role[0].thinking // ""] // {})
      + (if ($role[0].language // "" | test("\\S")) then {language: $role[0].language} else {} end) + {
        enabledPlugins: ($plugins | map(select(split("@") | any(. as $n | $keep | index($n)) | not) | {key: ., value: false}) | from_entries),
        skillOverrides: (($skills + $builtin | map(select(. as $s | ($keep | index($s)) | not) | {key: ., value: "off"}))
          + ($org | map(select(. as $s | ($keep | index($s)) or ($keep | index("anthropic-skills")) | not) | {key: ("anthropic-skills:" + .), value: "off"})) | from_entries),
        statusLine: {type: "command", command: $statusline} }
      + (if ($keep | index("claudeai-mcp")) then {} else {env: ((($role[0].advanced // {}).env // {}) + {ENABLE_CLAUDEAI_MCP_SERVERS: "false"})} end)
  ' > "$settings"
  # Commit attribution (project setting): Claude Code's "attribution" setting, {commit, pr}; an empty string leaves the line out. "default" writes nothing.
  case "${attr_mode:-}" in
    none)   jq '.attribution = {commit: "", pr: ""}' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings" ;;
    custom) jq --arg t "$attr_text" '.attribution = {commit: $t, pr: $t}' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings" ;;
  esac
  # The PM's session key (set by the app in this script's environment for a session on no card, the PM) goes to claude through the settings env; the file is private.
  if [ -n "${TENTACL_PM_KEY:-}" ] && [ -n "${nocard:-}" ]; then
    jq --arg k "$TENTACL_PM_KEY" '.env = ((.env // {}) + {TENTACL_PM_KEY: $k})' "$settings" > "$settings.tmp" && chmod 600 "$settings.tmp" && mv "$settings.tmp" "$settings"
  fi
  FLAGS=(--model "$(jq -r .model "$role")" --effort "$(jq -r .effort "$role")"
         --permission-mode "$(jq -r .permissionMode "$role")"
         --append-system-prompt-file "$out" --settings "$settings" --add-dir "$ATTACHMENTS")
  if [ "$(jq '.allowedTools | length' "$role")" -gt 0 ]; then
    FLAGS+=(--allowed-tools)
    while IFS= read -r t; do FLAGS+=("$t"); done < <(jq -r '.allowedTools[]' "$role")
  fi
}

# build_flags_codex: the codex flags. Nothing is written outside $STATE/<name>/instructions.md and no codex file is touched:
# trust and the instructions go in as -c values. Every argument is one line (the terminal rejects newlines).
build_flags_codex() {
  local role=$1 name=$2 out mode approval sandbox attr_mode attr_text
  write_instructions "$@"; out="$STATE/$name/instructions.md"
  # Codex has no attribution setting: the project's choice goes into the instructions as a line.
  { read -r attr_mode; read -r attr_text; } < <(project_attribution "${4:-}")
  case "${attr_mode:-}" in
    none)   printf '\nCommit attribution: do not add any co-author, "Generated with" or tool-credit line to commit messages or pull request descriptions.\n' >> "$out" ;;
    custom) printf '\nCommit attribution: end every commit message and pull request description with exactly this line, and no other tool-credit line: %s\n' "$attr_text" >> "$out" ;;
  esac
  mode=$(jq -r .permissionMode "$role")
  # The PM on Codex: workspace-write (never bypass) so request-start.sh, answer-question.sh and card writes need no prompt per call.
  # Its key is NOT put in the command line or the environment: it comes in the "Panel: new authority key" message (--key).
  local pm_dirs=()
  if [ "$(jq -r .name "$role")" = pm ]; then
    mode=acceptEdits
    local data; data=$(jq -r '.dataDir // empty' "${4:-/dev/null}" 2>/dev/null)
    pm_dirs=(--add-dir "$STATE")
    [ -n "$data" ] && pm_dirs+=(--add-dir "$data" --add-dir "$data/.tentacl")
  fi
  # --no-daemon: the TUI otherwise asks the shared Codex app-server daemon for the account, and a daemon that started before the login
  # answers "no account" (Welcome / Sign in screen, N253). Only the top-level option works: after `resume <id>` it is ignored.
  FLAGS=(--no-daemon -m "$(jq -r .model "$role")" -c "model_reasoning_effort=$(jq -r .effort "$role")" -c "plan_mode_reasoning_effort=$(jq -r .effort "$role")")
  # Codex 0.163: -a takes on-request or never. manual and plan ask before every edit and command (read-only sandbox); workspace-write has open network.
  case "$mode" in
    manual)            FLAGS+=(-s read-only -a on-request) ;;
    plan)              FLAGS+=(-s read-only -a on-request); printf '\nPlan only: do not edit files.\n' >> "$out" ;;
    bypassPermissions) FLAGS+=(--dangerously-bypass-approvals-and-sandbox) ;;
    *)                 FLAGS+=(-a on-request -s workspace-write) ;;
  esac
  FLAGS+=(--add-dir "$ATTACHMENTS" ${pm_dirs[@]+"${pm_dirs[@]}"}
          -c check_for_update_on_startup=false
          -c "developer_instructions=$(jq -Rs . < "$out")"
          -c "projects={$(jq -nr --arg w "$WORKTREE" '$w | @json' | tr -d '\n')={trust_level=\"trusted\"}}")
}

# with_resume: puts the resume option in front of FLAGS for the role's tool (claude --resume <id>; codex resume <id> is a subcommand and comes first, after the top-level --no-daemon).
with_resume() {
  [ -n "$resume" ] || return 0
  if [ "$tool" = codex ]; then FLAGS=(--no-daemon resume "$resume" "${FLAGS[@]:1}"); else FLAGS=(--resume "$resume" "${FLAGS[@]}"); fi
}

if [ "${1:-}" = "--print-flags" ]; then
  [ $# -ge 2 ] || die "usage: spawn-agent.sh --print-flags <role.json> [udid] [project.json] [worktree]"
  WORKTREE=${5:-<worktree>}
  build_flags "$2" "$(jq -r '.name // "role"' "$2" 2>/dev/null)" "${3:-}" "${4:-}"
  printf '%q ' "${FLAGS[@]}"; echo; exit 0
fi

resume=""
if [ "${1:-}" = "--resume" ]; then
  [ $# -ge 3 ] || die "usage: spawn-agent.sh --resume <session-id> <project.json> <role.json> <task-id> <branch>"
  resume=$2; shift 2
  case "$resume" in ""|-*|*[!A-Za-z0-9._-]*) die "not a session id: $resume" ;; esac
fi
nocard=""
if [ "${1:-}" = "--no-card" ]; then
  [ $# -eq 3 ] || die "usage: spawn-agent.sh --no-card <project.json> <role.json>"
  nocard=1; shift; set -- "$1" "$2" "" ""
fi
[ $# -eq 4 ] || die "usage: spawn-agent.sh <project.json> <role.json> <task-id> <branch>"
project=$1; role=$2; task=$3; branch=$4

bash "$HERE/validate-config.sh" "$project" >&2 || exit 1
bash "$HERE/validate-config.sh" "$role" >&2 || exit 1
repo=$(jq -r .repoPath "$project")
# <role>-<task>-<project tag>: the tag (the project id cut to 12 characters) keeps two projects' tasks with the same id apart,
# since the name also names the agent's simulator and its state folder. Keep in step with TaskInput.agentName in the app.
tag=$(jq -r '.id // ""' "$project" | tr 'A-Z' 'a-z' | cut -c1-12 | sed 's/-*$//')
tool=$(role_tool "$role")
name=$(printf '%s%s%s' "$(jq -r .name "$role")" "${task:+-$task}" "${tag:+-$tag}" | tr 'A-Z' 'a-z')

# term.sh answers {"result":..} or {"error":..}.
term() { bash "$HERE/term.sh" "$@"; }
term_ok() { printf '%s' "$1" | jq -e 'has("result") and (has("error") | not)' >/dev/null 2>&1; }
term_err() { printf '%s' "$1" | jq -r '.error.message // "no answer"' 2>/dev/null; }

# Codex 0.163 shows "Hooks need review" on every start while a hook in ~/.codex/hooks.json (another tool's SessionStart hook) is untrusted, and waits there.
# The panel never trusts hooks or edits ~/.codex: it reads the pane and gives the user the way out. HOOKS_MSG is set when that screen is showing.
# (`-c` has no documented key that skips only this screen; --dangerously-bypass-hook-trust is not used.)
HOOKS_MSG="Codex asks to review its hooks: open Codex once and trust them"
codex_hooks_screen() {
  [ "$tool" = codex ] || return 1
  local screen; screen=$(term read "$1" 40 2>/dev/null | jq -r '.result.text // ""' 2>/dev/null)
  printf '%s' "$screen" | grep -q "Hooks need review"
}

ws_list=$(term list-workspaces 2>&1)
term_ok "$ws_list" || die "the terminal (tentacld) is not reachable: $(term_err "$ws_list")"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $repo"
if [ -n "$nocard" ]; then
  # A session on no card runs in the project folder itself: one workspace for it, nothing else to prepare or undo.
  term list-agents 2>/dev/null | jq -e --arg n "$name" '[.result.agents[]? | select(.name == $n and .sleeping != true)] | length > 0' >/dev/null 2>&1 && die "$name is already running"
  trap 'rm -rf "${STATE:?}/$name"' EXIT
  WORKTREE=$repo
  build_flags "$role" "$name" "" "$project"; with_resume
  created=$(term open "$name" "$repo" 2>&1)
  term_ok "$created" || die "workspace create failed: $(term_err "$created")"
  ws=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')
  pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
  started=$(term start "$name" "$pane" "$tool" -- "${FLAGS[@]}" 2>&1)
  if codex_hooks_screen "$pane"; then term close "$ws" >/dev/null 2>&1; die "agent start failed (workspace closed): $HOOKS_MSG"; fi
  if ! term_ok "$started"; then
    msg=$(term_err "$started"); term close "$ws" >/dev/null 2>&1
    die "agent start failed (workspace closed): $msg"
  fi
  trap - EXIT
  jq -nc --arg a "$name" --arg w "$ws" --arg p "$pane" --arg t "$repo" '{agent:$a, workspace_id:$w, pane_id:$p, worktree_path:$t, udid:""}'
  exit 0
fi
wt_path="$repo/.agent-worktrees/$(printf '%s' "$branch" | tr '/' '-')"
if [ -n "$resume" ]; then
  # Resuming reuses what is there: the branch and its worktree must both exist, and nothing is created, reset or removed.
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || die "cannot resume: branch '$branch' does not exist in $repo"
  [ -d "$wt_path" ] && git -C "$repo" worktree list --porcelain | grep -qxF "worktree $(cd "$wt_path" && pwd -P)" || die "cannot resume: the worktree $wt_path is gone"
  term list-agents 2>/dev/null | jq -e --arg n "$name" '[.result.agents[]? | select(.name == $n and .sleeping != true)] | length > 0' >/dev/null 2>&1 && die "$name is already running"
elif git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then die "branch '$branch' already exists in $repo; pick a new branch name (an existing branch is never reused or deleted)"; fi
base=$(jq -r '.mainBranch // "main"' "$project")   # the project's main branch, never whatever the repository is on right now

# Only a project that configures a simulator gives its agents a device of their own.
udid=""
if jq -e '.simulator.baseDevice // empty' "$project" >/dev/null 2>&1; then
  udid=$(bash "$SIM" "$name" "$project") || die "could not prepare a simulator for $name"
fi
# From here on a failure must not leave the simulator or the state folder behind.
cleanup_sim() { [ -n "$resume" ] && return 0; [ -n "$udid" ] && bash "$SIM" --remove "$name" >/dev/null 2>&1; rm -rf "${STATE:?}/$name"; }
trap 'cleanup_sim' EXIT

# The worktree is made with plain git for every backend. Worktrees live inside the project (<repo>/.agent-worktrees/<branch>): Claude Code trusts subfolders of a
# trusted project, so agents start without the folder-trust dialog. The folder is excluded locally via
# .git/info/exclude and never committed.
wt_path="$repo/.agent-worktrees/$(printf '%s' "$branch" | tr '/' '-')"
WORKTREE=$wt_path
build_flags "$role" "$name" "$udid" "$project"; with_resume
exclude=$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"; grep -qxF '/.agent-worktrees/' "$exclude" 2>/dev/null || echo '/.agent-worktrees/' >> "$exclude"

if [ -z "$resume" ] && ! wt_err=$(git -C "$repo" worktree add -q -b "$branch" "$wt_path" "$base" 2>&1); then
  die "worktree create failed: $wt_err"   # the EXIT trap removes the simulator and the state folder
fi
# Untracked local files the project lists in "copyFiles" (signing settings, .env) are not in a fresh worktree: copy them from the repository.
# Relative paths inside the repository only; a source that is missing, a symlink or outside the repository is skipped with a note.
while IFS= read -r rel; do
  [ -n "$rel" ] && [ -z "$resume" ] || continue
  case "$rel" in /*|../*|*/../*|*/..|..|.git|.git/*|*$'\n'*) echo "NOTE: copyFiles entry '$rel' is not allowed, skipped" >&2; continue ;; esac
  src_file="$repo/$rel"
  if [ -f "$src_file" ] && [ ! -L "$src_file" ]; then
    mkdir -p "$(dirname "$wt_path/$rel")" && [ ! -e "$wt_path/$rel" ] && cp "$src_file" "$wt_path/$rel"
  else
    echo "NOTE: copyFiles entry '$rel' was not found in $repo, skipped" >&2
  fi
done < <(jq -r '.copyFiles[]? // empty' "$project")

wpath=$wt_path

# Undo this run only: the workspace made for this agent, the worktree and the new branch.
rollback() {
  [ -n "${ws:-}" ] && term close "$ws" >/dev/null 2>&1
  [ -n "$resume" ] && return 0   # a resumed agent's worktree, branch and simulator were there before this run: only the new workspace goes
  git -C "$repo" worktree remove --force "$wt_path" >/dev/null 2>&1
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1   # safe: the branch did not exist before this run
  rmdir "$repo/.agent-worktrees" 2>/dev/null
  [ -n "$udid" ] && bash "$SIM" --remove "$name" >/dev/null 2>&1
}

# Optional "setupCommand" (npm install, bundle install, xcodegen): runs once in a new worktree, never on --resume. bash -lc in the worktree, output in
# $STATE/<name>/setup.log, a time limit (AGENT_PANEL_SETUP_TIMEOUT seconds, default 600). A failure rolls the worktree back like a failed start.
setup_cmd=$(jq -r '.setupCommand // empty' "$project")
if [ -z "$resume" ] && [ -n "$setup_cmd" ]; then
  mkdir -p "$STATE/$name"; setup_log="$STATE/$name/setup.log"; setup_flag="$STATE/$name/setup.timeout"; rm -f "$setup_flag"
  (cd "$wt_path" && exec perl -e 'setpgrp(0,0); exec @ARGV' bash -lc "$setup_cmd") >"$setup_log" 2>&1 </dev/null &
  setup_pid=$!
  ( sleep "${AGENT_PANEL_SETUP_TIMEOUT:-600}"; : > "$setup_flag"; kill -TERM -- "-$setup_pid" 2>/dev/null; sleep 2; kill -KILL -- "-$setup_pid" 2>/dev/null ) >/dev/null 2>&1 &
  setup_wd=$!
  wait "$setup_pid"; setup_rc=$?
  pkill -P "$setup_wd" 2>/dev/null; kill "$setup_wd" 2>/dev/null; wait "$setup_wd" 2>/dev/null
  if [ "$setup_rc" -ne 0 ]; then
    tail_log=$(tail -n 10 "$setup_log" | cut -c1-300)
    if [ -e "$setup_flag" ]; then why="timed out after ${AGENT_PANEL_SETUP_TIMEOUT:-600}s"; else why="exit status $setup_rc"; fi
    rollback
    die "Setup failed ($why, worktree rolled back): $setup_cmd"$'\n'"$tail_log"
  fi
  rm -f "$setup_flag"
fi

created=$(term open "$name" "$wt_path" 2>&1)
if ! term_ok "$created"; then
  msg=$(term_err "$created"); rollback
  die "workspace create failed (worktree rolled back): $msg"
fi
ws=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')

started=$(term start "$name" "$pane" "$tool" -- "${FLAGS[@]}" 2>&1)
if codex_hooks_screen "$pane"; then rollback; die "agent start failed (worktree rolled back): $HOOKS_MSG"; fi
if ! term_ok "$started"; then
  msg=$(term_err "$started"); rollback
  die "agent start failed (worktree rolled back): $msg"
fi

trap - EXIT   # started: the simulator and state folder now belong to the running agent
jq -nc --arg a "$name" --arg w "$ws" --arg p "$pane" --arg t "$wpath" --arg u "$udid" \
  '{agent:$a, workspace_id:$w, pane_id:$p, worktree_path:$t, udid:$u}'
