#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
H="${HERE}/../hooks/precompact-handoff.sh"
# 実運用の session id は UUID (≥8 char) のため、現実的な長さの id で suffix を検証する。
export CLAUDE_SESSION_ID="psess-1122334455"
# handoff は ctx_session_key (per-session ユニーク) で命名される。
SESS="$(ctx_session_key /x)"
J='{"session_id":"psess","transcript_path":"'"${HERE}/fixtures/sample.jsonl"'","trigger":"auto","cwd":"/x"}'

# 正常系: JSON は出力しない (customInstructions 撤去)。handoff は最終化される (backstop)。
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"
OUT="$(printf '%s' "$J" | bash "${H}")"
assert_eq "${OUT}" "" "JSON 出力なし (customInstructions 撤去で schema エラー回避)"
assert_file_exists "${TMP}/handoffs/${SESS}.md"

# kill switch: 何もしない (handoff も作らない)
TMP2="$(mktemp -d)"
OUT2="$(printf '%s' "$J" | CC_COMPACTION_HOME="${TMP2}" CC_HANDOFF_ENABLED=off bash "${H}")"
assert_eq "${OUT2}" "" "kill switch で no-op"
assert_eq "$([ -e "${TMP2}/handoffs/${SESS}.md" ] && echo SET || echo UNSET)" "UNSET" "kill switch で handoff 未生成"

rm -rf "${TMP}" "${TMP2}"
report
