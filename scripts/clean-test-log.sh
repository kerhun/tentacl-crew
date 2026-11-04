#!/usr/bin/env bash
# One-time cleanup of the lines unit tests wrote into the real action log before the tests were isolated (N221).
# Usage: scripts/clean-test-log.sh <log> [--apply] [--sample <n>]
#   (no flag)  dry run: prints the count per rule and a sample of the lines it would remove; writes nothing.
#   --apply    first copies <log> to <log>.bak-<date>, then writes the cleaned log atomically (temp file + mv).
# Only lines that match a rule below are removed (the whole line, optional "[project] " tag allowed); everything else stays.
#   merged-T1   "merged T1 <40-hex sha> (script)": merge-task.sh test runs, card T1 in a temp repo (tags [tmp], [recipe-box])
#   answered-B1 "answered B1 (w2:p1)": answer tests on fixture card B1 and pane w2:p1 (real panes are w2:pA, w2:pB, ...)
set -u
log=""; apply=""; sample=5
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --sample) sample=${2:?--sample needs a number}; shift ;;
    -*) echo "unknown argument: $1"; exit 2 ;;
    *) [ -z "$log" ] || { echo "only one log file"; exit 2; }; log=$1 ;;
  esac
  shift
done
[ -n "$log" ] || { echo "usage: clean-test-log.sh <log> [--apply] [--sample <n>]"; exit 2; }
[ -f "$log" ] || { echo "no such file: $log"; exit 2; }

TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'; TAG='(\[[^] ]+\] )?'
# label|regex (whole line)
patterns=(
  "merged-T1|^$TS ${TAG}merged T1 [0-9a-f]{40} \(script\)\$"
  "answered-B1|^$TS ${TAG}answered B1 \(w2:p1\)\$"
)
any=$(printf '%s\n' "${patterns[@]}" | sed 's/^[^|]*|//' | paste -sd'|' -)
hits=$(mktemp); trap 'rm -f "$hits" "${tmp:-}"' EXIT
total=0
printf '%-16s %8s\n' rule lines
for p in "${patterns[@]}"; do
  n=$(grep -cE "${p#*|}" "$log" || true); printf '%-16s %8s\n' "${p%%|*}" "$n"; total=$((total + n))
done
printf '%-16s %8s  of %s lines\n' total "$total" "$(wc -l < "$log" | tr -d ' ')"
grep -E "$any" "$log" > "$hits" || true
if [ "$total" -gt 0 ]; then echo "sample:"; head -n "$sample" "$hits" | sed 's/^/  /'; fi

if [ -z "$apply" ]; then echo "dry run: nothing written (--apply backs up, then removes)"; exit 0; fi
[ "$total" -gt 0 ] || { echo "nothing to remove"; exit 0; }
bak="$log.bak-$(date +%Y-%m-%d)"
[ ! -e "$bak" ] || bak="$log.bak-$(date +%Y-%m-%d-%H%M%S)"
cp -p "$log" "$bak" || { echo "backup failed; log unchanged"; exit 1; }
echo "backup: $bak"
tmp=$(mktemp "$log.XXXXXX") || { echo "cannot write next to the log"; exit 1; }
grep -vE "$any" "$log" > "$tmp"; [ $? -le 1 ] || { echo "filter failed; log unchanged"; exit 1; }
chmod --reference="$log" "$tmp" 2>/dev/null || chmod "$(stat -f %Lp "$log")" "$tmp"
mv "$tmp" "$log" && echo "removed $total lines"
