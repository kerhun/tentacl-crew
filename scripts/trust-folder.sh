#!/usr/bin/env bash
# Tells Claude Code that a folder is trusted, so an agent started in it does not stop at "Do you trust the files in this folder?".
# Usage: trust-folder.sh <absolute folder>
# Sets projects[<folder>].hasTrustDialogAccepted = true in Claude's own config (~/.claude.json) and keeps everything else in it.
# The old file is copied to <file>.tentacl-backup first; a file that is not valid JSON is never touched.
# Env: AGENT_PANEL_CLAUDE_JSON (default ~/.claude.json).
# The flag is read back after the write and written once more when it is missing.
# Exit: 0 done; 1 the config could not be used or written; 2 usage.
set -u
dir=${1:-}
case "$dir" in /*) ;; *) echo "ERROR: the folder must be an absolute path" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "ERROR: $dir is not a folder" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)
cfg=${AGENT_PANEL_CLAUDE_JSON:-$HOME/.claude.json}

apply() {
  local src tmp
  if [ -f "$cfg" ]; then
    jq empty "$cfg" 2>/dev/null || { echo "ERROR: $cfg is not valid JSON, so it was left as it is" >&2; return 1; }
    cp -p "$cfg" "$cfg.tentacl-backup" || { echo "ERROR: could not back up $cfg" >&2; return 1; }
    src=$cfg
  else
    src=/dev/null
  fi
  tmp=$(mktemp "$cfg.XXXXXX") || { echo "ERROR: could not write next to $cfg" >&2; return 1; }
  if [ "$src" = /dev/null ]; then echo '{}' | jq --arg p "$dir" '.projects[$p].hasTrustDialogAccepted = true' > "$tmp"
  else jq --arg p "$dir" '.projects = (.projects // {}) | .projects[$p].hasTrustDialogAccepted = true' "$cfg" > "$tmp"; fi || { rm -f "$tmp"; echo "ERROR: could not update $cfg" >&2; return 1; }
  if [ -f "$cfg" ]; then chmod "$(stat -f %Lp "$cfg" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null; else chmod 600 "$tmp"; fi
  mv "$tmp" "$cfg" || { rm -f "$tmp"; echo "ERROR: could not write $cfg" >&2; return 1; }
}
trusted() { jq -e --arg p "$dir" '.projects[$p].hasTrustDialogAccepted == true' "$cfg" >/dev/null 2>&1; }

# A running Claude session may rewrite the file between our read and our write and drop the flag: read it back, retry once.
apply || exit 1
trusted && exit 0
apply || exit 1
trusted || { echo "ERROR: the trust flag could not be confirmed in $cfg (another process keeps rewriting it)" >&2; exit 1; }
