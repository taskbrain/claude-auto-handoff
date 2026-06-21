#!/usr/bin/env bash
# test_resume_freshness.sh — A2: 復元の鮮度ガード (pane 再利用の誤復元対策)。
# pane 基軸キーは同一 pane を順次使う別セッション間でキーを共有しうるため、何時間も前の
# 死んだ占有者の handoff を誤復元する危険がある。正当な /clear 復元は handoff が直近
# (prepare band の各 Stop で再書込) なので、復元は handoff mtime が
# HANDOFF_RESTORE_FRESH_SECONDS (既定 1800s=30分) 以内のときだけ行い、古い ghost は
# 復元せず空ガイダンスにフォールバックする。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
RESUME="${HERE}/../hooks/compaction-resume.sh"
export CLAUDE_SESSION_ID="frsh"; export TMUX_PANE="%7"
SESS="$(ctx_session_key /x)"
MARK="FRESH_MARK_$$"
FALLBACK="自動ハンドオフが空でした"

# A) 鮮度内 handoff (now) + compacted → 復元する
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# H\n## 1. CURRENT GOAL\n%s\n' "${MARK}" > "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${RESUME}")"
assert_contains "${OUT}" "${MARK}" "鮮度内 handoff → 復元"

# B) stale handoff (1時間前 > 1800s) + compacted → 復元しない (ghost 防止) + 空ガイダンス
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# H\n## 1. CURRENT GOAL\n%s\n' "${MARK}" > "${TMP}/handoffs/${SESS}.model.md"
touch -d '1 hour ago' "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${RESUME}")"
assert_eq "$(printf '%s' "${OUT}" | grep -qF "${MARK}" && echo LEAK || echo OK)" "OK" "stale handoff → 復元しない (ghost 防止)"
assert_contains "${OUT}" "${FALLBACK}" "stale handoff → 空ガイダンスにフォールバック"

# C) source=compact でも stale は復元しない (鮮度ガードは compacted/compact 共通)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# H\n## 1. CURRENT GOAL\n%s\n' "${MARK}" > "${TMP}/handoffs/${SESS}.model.md"
touch -d '1 hour ago' "${TMP}/handoffs/${SESS}.model.md"
OUT="$(printf '{"source":"compact","cwd":"/x"}' | bash "${RESUME}")"
assert_eq "$(printf '%s' "${OUT}" | grep -qF "${MARK}" && echo LEAK || echo OK)" "OK" "stale handoff (compact) → 復元しない"

rm -rf "${TMP}"
report
