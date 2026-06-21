#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"
mkdir -p "${TMP}/handoffs"
S="flagsess"

# --- flag set/clear/isset ---
out=$(ctx_flag_isset compacted "${S}" && echo SET || echo UNSET); assert_eq "${out}" "UNSET" "初期 unset"
ctx_flag_set compacted "${S}"
out=$(ctx_flag_isset compacted "${S}" && echo SET || echo UNSET); assert_eq "${out}" "SET" "set 後"
ctx_flag_clear compacted "${S}"
out=$(ctx_flag_isset compacted "${S}" && echo SET || echo UNSET); assert_eq "${out}" "UNSET" "clear 後"

# --- prepared-for-episode (mtime 比較) ---
out=$(ctx_prepared_for_episode "${S}" && echo PREP || echo NO); assert_eq "${out}" "NO" "model.md 無 → not prepared"
ctx_episode_stamp "${S}"
sleep 1
printf 'x' > "${TMP}/handoffs/${S}.model.md"
out=$(ctx_prepared_for_episode "${S}" && echo PREP || echo NO); assert_eq "${out}" "PREP" "model.md > episode → prepared"

# episode 跨ぎ: reset → 新 stamp が旧 model.md より新しい → not prepared (iterative UPDATE を要求)
ctx_episode_reset "${S}"
sleep 1
ctx_episode_stamp "${S}"
out=$(ctx_prepared_for_episode "${S}" && echo PREP || echo NO); assert_eq "${out}" "NO" "新 episode stamp > 旧 model.md → not prepared"
# model.md は reset を跨いで保持される (iterative update 用)
assert_file_exists "${TMP}/handoffs/${S}.model.md"

# --- episode_reset が compacted / prepare_prompted を clear ---
ctx_flag_set compacted "${S}"; ctx_flag_set prepare_prompted "${S}"
ctx_episode_reset "${S}"
o1=$(ctx_flag_isset compacted "${S}" && echo SET || echo UNSET); assert_eq "${o1}" "UNSET" "reset で compacted clear"
o2=$(ctx_flag_isset prepare_prompted "${S}" && echo SET || echo UNSET); assert_eq "${o2}" "UNSET" "reset で prepare_prompted clear"

rm -rf "${TMP}"
report
