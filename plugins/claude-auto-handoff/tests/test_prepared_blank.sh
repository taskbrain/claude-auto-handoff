#!/usr/bin/env bash
# test_prepared_blank.sh — #3 (Codex 指摘): whitespace-only model.md を「準備済」とみなさない。
# daemon の /clear ガード (tick) と ctx_prepared_for_episode を [-s] から ctx_file_has_text に
# 統一したことの回帰。[-s] (サイズ>0) は空白/改行のみを非空と誤判定し、daemon が /clear した後
# resume 側は空扱い→ fallback で肝心の文脈を失う、という不整合を塞ぐ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
SESS="blanktest"

# whitespace/改行のみ (サイズ>0) → 準備済でない
printf '   \n\t\n  \n' > "${TMP}/handoffs/${SESS}.model.md"
ctx_prepared_for_episode "${SESS}" && R=PREPARED || R=NOT
assert_eq "${R}" "NOT" "whitespace-only model.md → 準備済でない ([-s] 誤判定の回帰)"

# 0 バイト → 準備済でない
: > "${TMP}/handoffs/${SESS}.model.md"
ctx_prepared_for_episode "${SESS}" && R=PREPARED || R=NOT
assert_eq "${R}" "NOT" "空 model.md → 準備済でない"

# 本文あり + episode stamp 無 → 準備済
printf '# H\n## 1. CURRENT GOAL\nreal goal\n' > "${TMP}/handoffs/${SESS}.model.md"
ctx_prepared_for_episode "${SESS}" && R=PREPARED || R=NOT
assert_eq "${R}" "PREPARED" "本文あり model.md → 準備済"

rm -rf "${TMP}"
report
