#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
PY="${HERE}/../hooks/lib/transcript_extract.py"
FIX="${HERE}/fixtures/sample.jsonl"
OUT="$(python3 "${PY}" "${FIX}")"
assert_contains "${OUT}" "Add input validation" "user request 抽出"
assert_contains "${OUT}" "src/auth/login.ts" "編集ファイル抽出"
# 最終 assistant の usage 合算 = 3 + 181000 + 500 = 181503
assert_contains "${OUT}" "181503" "used_tokens 合算"
assert_contains "${OUT}" "pytest" "CMD 抽出"
# harness 注入文 (skill base directory 等) は GOAL/REQUEST に採用しない
assert_eq "$(printf '%s' "${OUT}" | grep -c 'Base directory')" "0" "harness注入文除外"
report
