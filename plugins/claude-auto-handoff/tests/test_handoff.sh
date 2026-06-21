#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
H="${HERE}/../hooks/cc-compaction-handoff.sh"
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"
# transcript を指定 (fixture)
export CC_COMPACTION_TRANSCRIPT="${HERE}/fixtures/sample.jsonl"
bash "${H}" "testsess" "/x" "60" "181503"
HF="${TMP}/handoffs/testsess.md"
assert_file_exists "${HF}"
BODY="$(cat "${HF}")"
assert_contains "${BODY}" "# HANDOFF" "ヘッダ"
assert_contains "${BODY}" "CURRENT GOAL" "セクション1"
assert_contains "${BODY}" "src/auth/login.ts" "開いてるファイル"
assert_contains "${BODY}" "NEXT STEPS" "セクション3"
rm -rf "${TMP}"
report
