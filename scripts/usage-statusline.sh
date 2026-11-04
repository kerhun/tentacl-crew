#!/usr/bin/env bash
# Claude Code status line command: records the plan usage Claude Code reports and prints it as a short line.
# Reads the status line JSON on stdin, writes it (plus the time it was seen) atomically to <usage folder>/<session_id>.json and prints
# e.g. "5h 23% · week 41%" (a window Claude Code did not report is left out). Never calls any network endpoint.
# Usage: usage-statusline.sh [role-statusline-command]   (that command runs first, with the same input; its first line is printed before ours)
# Env: AGENT_PANEL_USAGE (default ~/Library/Application Support/Tentacl/usage; keep in step with UsageReader.defaultRoot).
USAGE=${AGENT_PANEL_USAGE:-$HOME/Library/Application Support/Tentacl/usage}
input=$(cat)
mine=""
[ -n "${1:-}" ] && mine=$(printf '%s' "$input" | bash -c "$1" 2>/dev/null | head -n 1)

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
case "$sid" in
  ""|*[!A-Za-z0-9_-]*) ;;   # no usable id: print only
  *)
    if mkdir -p "$USAGE" 2>/dev/null; then
      tmp=$(mktemp "$USAGE/.tmp.XXXXXX" 2>/dev/null) &&
        { printf '%s' "$input" | jq -c --argjson now "$(date +%s)" '. + {seen_at: $now}' > "$tmp" 2>/dev/null && mv "$tmp" "$USAGE/$sid.json" || rm -f "$tmp"; }
    fi ;;
esac

ours=$(printf '%s' "$input" | jq -r '
  [ (.rate_limits.five_hour.used_percentage // empty | "5h \(. | round)%"),
    (.rate_limits.seven_day.used_percentage // empty | "week \(. | round)%") ] | join(" · ")' 2>/dev/null)
if [ -n "$mine" ] && [ -n "$ours" ]; then printf '%s | %s\n' "$mine" "$ours"
elif [ -n "$mine" ]; then printf '%s\n' "$mine"
elif [ -n "$ours" ]; then printf '%s\n' "$ours"; fi
exit 0
