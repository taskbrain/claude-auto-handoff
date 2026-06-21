#!/usr/bin/env bash
# test_session_key_clear_stability.sh — /clear を跨いだ handoff 復元の end-to-end 回帰。
#
# 真のバグ: 実環境では CLAUDE_SESSION_ID は未設定で、ctx_session_key は
# CLAUDE_CODE_SESSION_ID (= 会話ごとの UUID = transcript ディレクトリ名) にフォールバック
# していた。/clear は新しい会話を開始し新 UUID を発行するため、/clear 前に
# slug-<旧UUID8> で書いた handoff を /clear 後に slug-<新UUID8> で読み、永遠に不一致になる。
# → compaction-resume.sh が handoff を見つけられず「空」になり手動コピペを強いられていた。
#
# 修正: ctx_session_key を TMUX_PANE 基軸 (slug-p<N>) にする。pane は /clear を跨いで不変
# かつ並行セッション間で一意。本テストは「同一 pane だが UUID が /clear で変わる」実環境を
# 再現し、修正前は赤・修正後は緑になることを保証する (既存 test_resume.sh は CLAUDE_SESSION_ID
# を固定し UUID 変化を再現しないため緑のまま見逃していた = テストギャップの補填)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
RESUME="${HERE}/../hooks/compaction-resume.sh"

TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"
mkdir -p "${TMP}/handoffs" "${TMP}/state"
MARK="MARKER_RESUME_OK_$$"

# === Phase 1: /clear 前 (会話 UUID = A、pane %9) に handoff を書き compacted を立てる ===
KEYA="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="sessionAAAAAAAA" TMUX_PANE="%9" ctx_session_key /x)"
printf '# HANDOFF\n## 1. CURRENT GOAL\n%s\n' "${MARK}" > "${TMP}/handoffs/${KEYA}.model.md"
: > "${TMP}/.compacted_${KEYA}"   # daemon が /clear 送出済みマーク

# === Phase 2: /clear 後 (会話 UUID = B に変化、同一 pane %9) に SessionStart 復元 ===
OUT_SAME="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="sessionBBBBBBBB" TMUX_PANE="%9" \
  bash "${RESUME}" <<<'{"source":"clear","cwd":"/x"}' 2>/dev/null || true)"

# 修正前: KEYA(uuid-A 基) ≠ 読込キー(uuid-B 基) → handoff 不在 → 空 (FAIL)
# 修正後: 両方 slug-p9 → 同一キー → handoff 本文が additionalContext に出る (PASS)
assert_contains "${OUT_SAME}" "${MARK}" "uuid 変化 + 同一 pane → handoff 復元"
assert_contains "${OUT_SAME}" "additionalContext" "復元時 additionalContext を返す"

# === 負例: /clear 後に別 pane %10 で起動 → 別セッションなので復元しない ===
OUT_DIFF="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="sessionCCCCCCCC" TMUX_PANE="%10" \
  bash "${RESUME}" <<<'{"source":"clear","cwd":"/x"}' 2>/dev/null || true)"
assert_eq "$(printf '%s' "${OUT_DIFF}" | grep -qF "${MARK}" && echo LEAK || echo OK)" "OK" \
  "別 pane では他セッションの handoff を復元しない"

rm -rf "${TMP}"
report
