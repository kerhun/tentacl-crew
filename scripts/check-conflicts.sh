#!/usr/bin/env bash
# Refuses to run two tasks side by side when they touch the same file. Analysis tasks (kind: analysis) never conflict: they only read.
# Usage: check-conflicts.sh <card-a.md> <card-b.md> <project.json>
# A card lists its files under "files:" in its front matter (block list, [a, b] or a single path). Quotes, a leading "./" and a
# trailing "/" are ignored; a listed directory covers every file inside it.
# Exit: 0 no conflict, 1 conflict or unknown scope (CONFLICT: <file> lines on stdout), 2 usage error.
set -u
[ $# -eq 3 ] && [ -f "$1" ] && [ -f "$2" ] && [ -f "$3" ] || { echo "usage: check-conflicts.sh <card-a.md> <card-b.md> <project.json>" >&2; exit 2; }
a=$1; b=$2; project=$3

# Prints the "files:" entries of a card, normalised, one per line (front matter only, CRLF tolerated).
# Accepted like CardParser does: a block list, "files: [a, b]" and "files: a".
card_files() {
  tr -d '\r' < "$1" | awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---"    { exit }
    infm && /^files:/ {
      v = $0; sub(/^files:[[:space:]]*/, "", v)
      if (v ~ /^\[/) { sub(/^\[/, "", v); sub(/\][[:space:]]*$/, "", v); n = split(v, parts, ","); for (i = 1; i <= n; i++) print parts[i]; next }
      if (v != "") { print v; next }
      inlist = 1; next
    }
    infm && inlist && /^[[:space:]]*-[[:space:]]+/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); print; next }
    infm && inlist         { inlist = 0 }
  ' | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//; s#^\./##; s#/+\$##" | grep -v '^$'
}

# An analysis task (kind: analysis) changes nothing: it cannot conflict with any other task, and needs no scope.
kind_of() { tr -d '\r' < "$1" | awk 'NR == 1 && $0 == "---" { infm = 1; next } infm && $0 == "---" { exit } infm && /^kind:/ { sub(/^kind:[[:space:]]*/, ""); print; exit }'; }
[ "$(kind_of "$a")" = analysis ] || [ "$(kind_of "$b")" = analysis ] && exit 0

fa=$(card_files "$a"); fb=$(card_files "$b")
for pair in "$a:$fa" "$b:$fb"; do
  case "${pair#*:}" in
    "")        echo "ERROR: scope unknown for ${pair%%:*}: no files listed in its front matter" >&2; exit 1 ;;
  esac
done

conflict=0
# Same path, or one entry is a directory that contains the other.
while IFS= read -r x; do
  while IFS= read -r y; do
    if [ "$x" = "$y" ] || [ "${y#"$x"/}" != "$y" ] || [ "${x#"$y"/}" != "$x" ]; then
      echo "CONFLICT: $x"; [ "$x" != "$y" ] && echo "CONFLICT: $y"; conflict=1
    fi
  done <<< "$fb"
done <<< "$fa"

# Shared files match by base name, so "Localizable.xcstrings" and a full path count as the same file.
touches() { printf '%s\n' "$1" | while IFS= read -r f; do [ "$(basename "$f")" = "$(basename "$2")" ] && echo yes; done | head -1; }
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if [ -n "$(touches "$fa" "$s")" ] && [ -n "$(touches "$fb" "$s")" ]; then
    echo "CONFLICT: $s (shared file)"; conflict=1
  fi
done < <(jq -r '.sharedFiles[]?' "$project")

[ "$conflict" -eq 0 ]
