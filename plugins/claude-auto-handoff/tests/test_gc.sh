#!/usr/bin/env bash
# test_gc.sh — A3: age ベースの孤立ファイル GC。
# pane 基軸キーへの移行で旧 UUID キーのファイルが孤立する + そもそも age GC が無く
# ~/.claude/auto-compaction/ にゴミが蓄積していた。ctx_gc が mtime で stale を削除し、
# fresh と kill switch (DISABLED) は保持し、冪等であることを検証する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"

TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"
mkdir -p "${TMP}/state" "${TMP}/handoffs" "${TMP}/archive"

# fresh (now) / stale (各既定閾値を確実に超える古さ) を作成
# state: GC_STATE_DAYS=1
: > "${TMP}/state/fresh.json"
: > "${TMP}/state/stale.json";              touch -d '3 days ago'  "${TMP}/state/stale.json"
# handoffs: GC_HANDOFF_DAYS=7
: > "${TMP}/handoffs/fresh.model.md"
: > "${TMP}/handoffs/stale.model.md";       touch -d '10 days ago' "${TMP}/handoffs/stale.model.md"
: > "${TMP}/handoffs/stale.md";             touch -d '10 days ago' "${TMP}/handoffs/stale.md"
# markers: GC_MARKER_DAYS=1
: > "${TMP}/.compacted_fresh"
: > "${TMP}/.compacted_stale";              touch -d '3 days ago'  "${TMP}/.compacted_stale"
: > "${TMP}/.episode_stale";                touch -d '3 days ago'  "${TMP}/.episode_stale"
: > "${TMP}/.last_handoff_stale";           touch -d '3 days ago'  "${TMP}/.last_handoff_stale"
# archive: GC_ARCHIVE_DAYS=14
: > "${TMP}/archive/fresh.md"
: > "${TMP}/archive/stale.md";              touch -d '20 days ago' "${TMP}/archive/stale.md"
# DISABLED kill switch (古くても絶対残す)
: > "${TMP}/DISABLED";                      touch -d '30 days ago' "${TMP}/DISABLED"
# .last_gc は GC 自身の debounce マーカー (古くても残す = 自己削除で cadence を乱さない)
: > "${TMP}/.last_gc";                      touch -d '5 days ago'  "${TMP}/.last_gc"

ctx_gc

# stale 削除
assert_eq "$([ -e "${TMP}/state/stale.json" ] && echo SET || echo UNSET)" "UNSET" "stale state 削除"
assert_eq "$([ -e "${TMP}/handoffs/stale.model.md" ] && echo SET || echo UNSET)" "UNSET" "stale model handoff 削除"
assert_eq "$([ -e "${TMP}/handoffs/stale.md" ] && echo SET || echo UNSET)" "UNSET" "stale mech handoff 削除"
assert_eq "$([ -e "${TMP}/.compacted_stale" ] && echo SET || echo UNSET)" "UNSET" "stale compacted marker 削除"
assert_eq "$([ -e "${TMP}/.episode_stale" ] && echo SET || echo UNSET)" "UNSET" "stale episode marker 削除"
assert_eq "$([ -e "${TMP}/.last_handoff_stale" ] && echo SET || echo UNSET)" "UNSET" "stale debounce marker 削除"
assert_eq "$([ -e "${TMP}/archive/stale.md" ] && echo SET || echo UNSET)" "UNSET" "stale archive 削除"
# fresh 保持
assert_file_exists "${TMP}/state/fresh.json"
assert_file_exists "${TMP}/handoffs/fresh.model.md"
assert_file_exists "${TMP}/.compacted_fresh"
assert_file_exists "${TMP}/archive/fresh.md"
# DISABLED は絶対残す
assert_file_exists "${TMP}/DISABLED"
# .last_gc (GC 自身の debounce) は古くても残す
assert_file_exists "${TMP}/.last_gc"

# 冪等性: 2回目もエラーなく fresh を保持
ctx_gc
assert_file_exists "${TMP}/state/fresh.json"

# kill switch CC_HANDOFF_GC=off → 何も消さない
: > "${TMP}/state/stale2.json"; touch -d '3 days ago' "${TMP}/state/stale2.json"
CC_HANDOFF_GC=off ctx_gc
assert_file_exists "${TMP}/state/stale2.json"

rm -rf "${TMP}"
report
