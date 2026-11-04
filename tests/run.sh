#!/usr/bin/env bash
# Runs every tests/*.test.sh; exits non-zero if any fails.
cd "$(dirname "$0")" || exit 2
unset TENTACL_PM_KEY
rc=0
errs=$(mktemp -d)/out; trap 'rm -rf "$(dirname "$errs")"' EXIT
for t in *.test.sh; do
  [ -e "$t" ] || continue
  bash "$t" > "$errs.$t" 2>&1; trc=$?
  [ "$trc" -eq 0 ] || rc=1
  # a passing file prints one line (its last "-- N passed" line); a failing one prints everything
  if [ "$trc" -eq 0 ]; then echo "ok  $t  $(grep -E '^-- [0-9]+ passed' "$errs.$t" | tail -n 1)"; else echo "== $t"; cat "$errs.$t"; fi
  # a test that prints shell or jq errors is broken even when its checks say PASS
  if grep -qE "command not found|jq: (parse )?error|syntax error|unbound variable|No such file or directory: " "$errs.$t"; then
    echo "STRAY ERRORS in $t:"; grep -E "command not found|jq: (parse )?error|syntax error|unbound variable" "$errs.$t"; rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$rc"
