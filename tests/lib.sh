#!/usr/bin/env bash
# Small test helpers. Every test file sources this one.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
# The PM's own key must not leak into tests; tests that need it set it explicitly.
unset TENTACL_PM_KEY

# expect <name> <expected-exit> <expected-text-or-empty> <command...>
expect() {
  local name=$1 want=$2 needle=$3; shift 3
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL  $name: exit $rc, expected $want"; echo "      output: ${out:0:300}"; FAIL=$((FAIL+1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL  $name: output lacks '$needle'"; echo "      output: ${out:0:300}"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS  $name"; PASS=$((PASS+1))
}

finish() { echo "-- $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
