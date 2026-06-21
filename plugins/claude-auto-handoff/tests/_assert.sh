#!/usr/bin/env bash
# 極小 bash アサーションヘルパ
_PASS=0; _FAIL=0
assert_eq()    { if [ "$1" = "$2" ]; then _PASS=$((_PASS+1)); else _FAIL=$((_FAIL+1)); echo "FAIL ${3:-}: expected[$2] got[$1]"; fi; }
assert_nonempty(){ if [ -n "$1" ]; then _PASS=$((_PASS+1)); else _FAIL=$((_FAIL+1)); echo "FAIL ${2:-}: empty"; fi; }
assert_file_exists(){ if [ -f "$1" ]; then _PASS=$((_PASS+1)); else _FAIL=$((_FAIL+1)); echo "FAIL: no file $1"; fi; }
assert_contains(){ if printf '%s' "$1" | grep -qF "$2"; then _PASS=$((_PASS+1)); else _FAIL=$((_FAIL+1)); echo "FAIL ${3:-}: [$1] !contains [$2]"; fi; }
report(){ echo "--- PASS=${_PASS} FAIL=${_FAIL} ---"; [ "${_FAIL}" -eq 0 ]; }
