#!/usr/bin/env bash
# Validates a project or role configuration.
# Usage: validate-config.sh <file.json>
# Exit: 0 valid (warnings go to stdout as "WARNING: ..."), 1 invalid (errors go to stderr).
set -u
file=${1:-}
[ -n "$file" ] && [ -f "$file" ] || { echo "usage: validate-config.sh <file.json>" >&2; exit 2; }

if ! jq empty "$file" 2>/dev/null; then
  echo "ERROR: malformed JSON: $file" >&2
  exit 1
fi

errors=0
err() { echo "ERROR: $*" >&2; errors=$((errors+1)); }
warn() { echo "WARNING: $*"; }
has() { if [ "$1" = "--arg" ]; then jq -e --arg "$2" "$3" "$4" "$file" >/dev/null 2>&1; else jq -e "$1" "$file" >/dev/null 2>&1; fi; }

check_project() {
  for k in id name repoPath dataDir; do
    has "(.${k} | type) == \"string\" and (.${k} | length) > 0" || err "$k is missing or empty"
  done
  # Optional: a project without a build, a simulator or Xcode is fine; a value that is present must not be empty.
  for k in buildCommand testCommand setupCommand openWith xcodeProject; do
    if has "has(\"$k\")"; then has "(.${k} | type) == \"string\" and (.${k} | length) > 0" || err "$k is empty (leave it out instead)"; fi
  done
  # Optional: untracked files copied from the repository into every new worktree (signing settings, .env).
  if has 'has("copyFiles")'; then
    has '(.copyFiles | type) == "array" and ([.copyFiles[] | (type == "string") and (length > 0) and (startswith("/") | not) and (test("(^|/)\\.\\.(/|$)") | not) and (test("^\\.git(/|$)") | not) and (test("[\\n\\r]") | not)] | all)' \
      || err "copyFiles must be a list of relative file paths inside the repository (no .., no absolute paths, nothing in .git)"
  fi
  # Optional: commit attribution for agents' commits; custom needs text.
  if has 'has("attribution")'; then has '.attribution == "default" or .attribution == "none" or .attribution == "custom"' || err "attribution must be default, none or custom"; fi
  if has 'has("attributionText")'; then has '(.attributionText | type) == "string" and (.attributionText | length) > 0 and (.attributionText | test("[\\n\\r]") | not)' || err "attributionText must be one non-empty line (leave it out instead)"; fi
  if has '.attribution == "custom"'; then has '(.attributionText // "") != ""' || err "attribution custom needs attributionText"; fi
  if has 'has("screenshots")'; then has '(.screenshots | type) == "boolean"' || err "screenshots must be true or false"; fi
  has '(.maxParallel | type) == "number" and .maxParallel >= 2 and .maxParallel <= 8 and (.maxParallel | floor) == .maxParallel' \
    || err "maxParallel must be an integer from 2 to 8"
  if has 'has("simulator")'; then
    has '(.simulator.baseDevice | type) == "string" and (.simulator.baseDevice | length) > 0' || err "simulator.baseDevice is missing"
  fi
  has '(.sharedFiles | type) == "array"' || err "sharedFiles must be a list"
  if has 'has("mainBranch")'; then
    has '(.mainBranch | type) == "string" and (.mainBranch | test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$")) and (.mainBranch | test("\\.\\.|//|\\.lock$") | not)' \
      || err "mainBranch is not a plain branch name"
  fi
}

check_team() {
  local name_re='^[a-z][a-z0-9_]{0,19}$'
  has '(.members | type) == "array"' || { err "members must be a list of {role, reportsTo} entries"; return; }
  has --arg re "$name_re" '[.members[] | (type == "object") and ((.role | type) == "string") and (.role | test($re))] | all' \
    || { err "a role name in the team chart is not a plain role name (lowercase letters, digits or _)"; return; }
  has '([.members[].role] | length) == ([.members[].role] | unique | length)' || err "a role is in the team chart more than once"
  has --arg re "$name_re" '[.members[] | .reportsTo as $b | ($b == null) or ((($b | type) == "string") and ($b | test($re)))] | all' \
    || { err "a role in the team chart reports to a name that is not a plain role name"; return; }
  has '[.members[] | .reportsTo == .role] | any' && err "a role in the team chart reports to itself"
  has '[.members[].role] as $roles | [.members[] | select(.reportsTo != null) | select(.reportsTo as $b | ($roles | index($b)) == null)] | length == 0' \
    || { err "a role in the team chart reports to a role that is not in the chart"; return; }
  has '(.members | map({key: .role, value: .reportsTo}) | from_entries) as $boss
       | def up($r; $n): if $n == 0 then $r else ($boss[$r]) as $b | if $b == null then null else up($b; $n - 1) end end;
       [.members[].role | up(.; ($boss | length) + 1)] | any(. != null)' && err "the team chart has a cycle"
}

# style_known <name>: a built-in style (any casing) or a user style file (name from its front matter, else the file name).
style_known() {
  local want f n
  want=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$want" in default|proactive|concise|explanatory|learning) return 0 ;; esac
  for f in "${AGENT_PANEL_CLAUDE_HOME:-$HOME/.claude}"/output-styles/*.md; do
    [ -f "$f" ] || continue
    n=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} /^name:/{sub(/^name:[ \t]*/,""); gsub(/^["\x27]|["\x27]$/,""); print; exit}' "$f")
    [ -n "$n" ] || n=$(basename "$f" .md)
    [ "$(printf '%s' "$n" | tr 'A-Z' 'a-z')" = "$want" ] && return 0
  done
  return 1
}

# codex_efforts: a JSON array, the efforts `codex debug models` lists for the role's model (all listed models' efforts when the model
# is not listed); low..max when codex is missing or gives nothing readable. Nothing is started or written.
codex_efforts() {
  local fallback='["low","medium","high","xhigh","max"]' out got
  if command -v codex >/dev/null 2>&1 && out=$(codex debug models 2>/dev/null </dev/null); then
    got=$(printf '%s' "$out" | jq -c --arg m "$(jq -r '.model // ""' "$file")" '
      [.models[]? | select(.visibility == "list") | {slug, e: [.supported_reasoning_levels[]?.effort]}] as $l
      | (([$l[] | select(.slug == $m) | .e[]] | unique) as $one
         | if ($one | length) > 0 then $one else ([$l[].e[]] | unique) end)' 2>/dev/null)
    if [ -n "$got" ] && [ "$got" != "[]" ] && [ "$got" != null ]; then echo "$got"; return; fi
  fi
  echo "$fallback"
}

check_role() {
  has '(.name | type) == "string" and (.name | test("^[a-z][a-z0-9_]{0,19}$"))' || err "name must be lowercase letters, digits or _, starting with a letter, at most 20 characters"
  has '.kind == "interactive" or .kind == "headless"' || err "kind must be interactive or headless"
  # tool: which agent program runs the role; missing means claude, so every older role file keeps working.
  local tool=claude
  if has 'has("tool")'; then
    if has '.tool == "claude" or .tool == "codex"'; then tool=$(jq -r .tool "$file"); else err "tool must be claude or codex"; tool=claude; fi
  fi
  has '(.model | type) == "string" and (.model | length) > 0' || err "model is missing (opus, sonnet, fable or a full model name)"
  if [ "$tool" = codex ]; then
    local efforts; efforts=$(codex_efforts)
    jq -e --argjson e "$efforts" '.effort as $x | $e | index($x) != null' "$file" >/dev/null 2>&1 || err "effort must be $(jq -r 'join(", ")' <<< "$efforts") for this codex model"
    has '.permissionMode | IN("manual","acceptEdits","plan","bypassPermissions")' \
      || err "permissionMode is invalid for a codex role (manual, acceptEdits, plan, bypassPermissions)"
  else
    has '.effort | IN("low","medium","high","xhigh","max")' || err "effort must be low, medium, high, xhigh or max"
    has '.permissionMode | IN("acceptEdits","auto","bypassPermissions","manual","dontAsk","plan")' \
      || err "permissionMode is invalid (acceptEdits, auto, bypassPermissions, manual, dontAsk, plan)"
  fi
  if has '(.outputStyle | type) == "string" and (.outputStyle | test("\\S")) and (.outputStyle | test("[\\r\\n]") | not)'; then
    if [ "$tool" = codex ]; then
      has '.outputStyle | ascii_downcase | IN("default","concise")' || warn "outputStyle is ignored for a codex role"
    else
      style_known "$(jq -r .outputStyle "$file")" || warn "outputStyle \"$(jq -r .outputStyle "$file")\" is not a built-in style or a style file in ~/.claude/output-styles (it may live on another machine or in the project)"
    fi
  else
    err "outputStyle must be one line naming an output style (Concise, Explanatory, ... or your own)"
  fi
  if has 'has("thinking")'; then has '.thinking | IN("on","off")' || err "thinking must be on or off (leave it out for Claude Code's default)"; fi
  if has 'has("language")'; then
    has '(.language | type) == "string" and (.language | test("[\\r\\n]") | not)' || err "language must be one line naming the reply language (like turkish)"
  fi
  if [ "$tool" = codex ]; then
    has 'has("thinking") or has("language")' && warn "thinking and language are ignored for a codex role"
  elif has '.thinking == "off" and (.effort | IN("xhigh","max"))'; then
    warn "with thinking off some models refuse effort $(jq -r .effort "$file"); use high or lower"
  fi
  has '(.allowedTools | type) == "array"' || err "allowedTools must be a list"
  has '(.skills | type) == "array"' || err "skills must be a list"
  if [ "$tool" = codex ]; then
    has '(.skills | type) == "array" and (.skills | length) > 0' && warn "skills is ignored for a codex role"
    has '(.allowedTools | type) == "array" and (.allowedTools | length) > 0' && warn "allowedTools is ignored for a codex role"
    has 'has("advanced")' && warn "advanced is ignored for a codex role"
  fi
  has '(.instructionFile | type) == "string" and (.instructionFile | length) > 0' || err "instructionFile is missing"
  has '(.instructionFile | type) == "string" and (.instructionFile | contains("/") | not) and .instructionFile != "." and .instructionFile != ".."' \
    || err "instructionFile must be a plain file name next to the role file (no folders)"
  if has 'has("protocol")'; then has '.protocol | type == "boolean"' || err "protocol must be true or false (false = no working protocol appended)"; fi
  if has 'has("displayName")'; then
    has '(.displayName | type) == "string" and (.displayName | length) <= 40 and (.displayName | test("[\\r\\n]") | not)' \
      || err "displayName must be one line of at most 40 characters"
  fi
  if has 'has("advanced")'; then
    has '(.advanced | type) == "object"' || err "advanced must be an object (extra Claude settings)"
    has '[.advanced | .. | objects | has("env")] | any' && err "advanced must not contain env: do not put secrets in role files, define them in your terminal"
  fi
  if has 'has("maxBudgetUsd")'; then
    if has '.kind == "interactive"'; then
      warn "maxBudgetUsd only works in headless mode; it is ignored for interactive roles, track spend with session-report"
    else
      has '(.maxBudgetUsd | type) == "number" and .maxBudgetUsd > 0' || err "maxBudgetUsd must be a positive number"
    fi
  fi
}

if has 'has("repoPath")'; then
  check_project
elif has 'has("members")'; then
  check_team
elif has 'has("kind")'; then
  check_role
else
  err "cannot tell the file type (a project needs repoPath, a role needs kind)"
fi

[ "$errors" -eq 0 ]
