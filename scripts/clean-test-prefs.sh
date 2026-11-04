#!/usr/bin/env bash
# One-time cleanup of the preference files unit tests used to leave in ~/Library/Preferences (N190).
# Usage: scripts/clean-test-prefs.sh [--apply] [--list] [--dir <prefs folder>] [--backup-dir <folder>]
#   (no flag)  dry run: prints the count per prefix and the total size, deletes nothing.
#   --apply    first writes <backup-dir>/prefs-backup-<date>.tar.gz of exactly those files, then deletes them, then prints what it removed.
#              Refuses while xcodebuild tests are running.
#   --list     prints the matching file names, one per line (scripts/app-test.sh counts them before and after a run).
# Env: PREFS_DIR / BACKUP_DIR work like the flags. Defaults: ~/Library/Preferences and ~/.cache/agent-panel.
# Only these names match (U = a uuid); anything else is never touched, among them agent-panel-demo.plist and other apps' files.
set -u
apply=""; list=""; dir="${PREFS_DIR:-$HOME/Library/Preferences}"; backup="${BACKUP_DIR:-$HOME/.cache/agent-panel}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --list) list=1 ;;
    --dir) dir=${2:?--dir needs a folder}; shift ;;
    --backup-dir) backup=${2:?--backup-dir needs a folder}; shift ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
  shift
done
[ -d "$dir" ] || { echo "no such folder: $dir"; exit 2; }

U='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# label|regex (whole file name)
patterns=(
  "agent-panel-tests-<uuid>|agent-panel-tests-$U\.plist"
  "agent-panel-key-tests-<uuid>|agent-panel-key-tests-$U\.plist"
  "agent-panel-tests-probe-<uuid>|agent-panel-tests-probe-$U\.plist"
  "finished-sort-tests-<uuid>|finished-sort-tests-$U\.plist"
  "notes-pad-tests-<uuid>|notes-pad-tests-$U\.plist"
  "mode-<uuid>|mode-$U\.plist"
  "stats-range-<uuid>|stats-range-$U\.plist"
  "RoundModelTests.<uuid>|RoundModelTests\.$U\.plist"
  "tentacl.uitest._<path>|tentacl\.uitest\._[A-Za-z0-9_]*\.plist"
  "fixed names|(agent-panel-tests-host|agent-panel-tests-git-suggestions|agent-panel-scroll-tests|finished-sort-tests)\.plist"
)

names=$(ls -f "$dir" 2>/dev/null)   # unsorted: fast on a folder with tens of thousands of files
matching() { printf '%s\n' "$names" | grep -E "^($1)\$" || true; }

if [ -n "$list" ]; then
  for p in "${patterns[@]}"; do matching "${p#*|}"; done
  exit 0
fi

all=$(mktemp); trap 'rm -f "$all"' EXIT
total=0; bytes=0
printf '%-36s %8s\n' prefix files
for p in "${patterns[@]}"; do
  m=$(matching "${p#*|}"); n=0
  if [ -n "$m" ]; then n=$(printf '%s\n' "$m" | wc -l | tr -d ' '); printf '%s\n' "$m" >> "$all"; fi
  printf '%-36s %8s\n' "${p%%|*}" "$n"; total=$((total + n))
done
if [ "$total" -gt 0 ]; then bytes=$(cd "$dir" && tr '\n' '\0' < "$all" | xargs -0 stat -f %b | awk '{s += $1 * 512} END {print s + 0}'); fi
printf '%-36s %8s  %s MB on disk\n' total "$total" "$((bytes / 1048576))"

if [ -z "$apply" ]; then echo "dry run: nothing deleted (--apply backs up, then deletes)"; exit 0; fi

if pgrep -fl 'xcodebuild.* test' >/dev/null 2>&1; then echo "refusing: xcodebuild tests are running; try again when they are done"; exit 1; fi
[ "$total" -gt 0 ] || { echo "nothing to remove"; exit 0; }
mkdir -p "$backup" || exit 2
tarball="$backup/prefs-backup-$(date +%Y-%m-%d).tar.gz"
[ ! -e "$tarball" ] || tarball="$backup/prefs-backup-$(date +%Y-%m-%d-%H%M%S).tar.gz"
tar -czf "$tarball" -C "$dir" -T "$all" || { echo "backup failed; nothing deleted"; rm -f "$tarball"; exit 1; }
echo "backup: $tarball"
(cd "$dir" && tr '\n' '\0' < "$all" | xargs -0 rm -f)
echo "removed $total files ($bytes bytes)"
