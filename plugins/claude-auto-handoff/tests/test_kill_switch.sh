#!/usr/bin/env bash
# CC_HANDOFF_ENABLED=off が compaction-resume (復元) を無効化することを検証 (Codex 指摘 Blocker)。
# README は CC_HANDOFF_ENABLED=off を「機能全体 (生成 + 復元) を無効化」と説明するため、復元 hook も
# これを honor しなければならない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
RESUME="${HERE}/../hooks/compaction-resume.sh"

export CLAUDE_SESSION_ID="ksess"
unset TMUX_PANE
SESS="$(ctx_session_key /x)"

TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF\n## 1. CURRENT GOAL\nKILL_TEST_GOAL\n' > "${TMP}/handoffs/${SESS}.model.md"

# 1) CC_HANDOFF_ENABLED=off → 復元しない (出力空)
OUT="$(printf '{"source":"compact","cwd":"/x"}' | CC_HANDOFF_ENABLED=off bash "${RESUME}")"
assert_eq "${OUT}" "" "CC_HANDOFF_ENABLED=off → compaction-resume は復元しない"

# 2) 既定 (on) → 復元する (対照: kill switch が無ければ復元される fresh handoff)
OUT2="$(printf '{"source":"compact","cwd":"/x"}' | bash "${RESUME}")"
assert_contains "${OUT2}" "KILL_TEST_GOAL" "既定 (on) なら復元する (対照)"

rm -rf "${TMP}"
report
