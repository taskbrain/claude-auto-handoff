#!/usr/bin/env bash
# test_session_key.sh — ctx_session_key() の pane 基軸 session キー解決を検証。
# auto-compaction の state/handoff/flag キーが (a) 複数 co-located 同一 slug セッションで
# 衝突せず、かつ (b) /clear を跨いで安定 (同一 pane なら会話 UUID が変わっても同一キー)
# であることを担保する。← (b) が壊れていたのが handoff 復元不能の根本原因。
#
# 注: slug 解決を git 非依存・決定論にするため cwd=/x を使う。/x では cch_session_slug が
#     "unknown-session" に決定論的に落ちるため suffix を厳密一致で検証できる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"

# ps mock: 非 tmux の tty fallback を決定論化する (実 TTY 上で実行しても環境非依存にする)。
# MOCK_TTY 既定 '?' = 制御端末なし → slug 単独。MOCK_TTY=pts/N → slug-ttypts-N。
PSMOCK="$(mktemp -d)"
cat > "${PSMOCK}/ps" <<'PSM'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_TTY:-?}"
PSM
chmod +x "${PSMOCK}/ps"
export PATH="${PSMOCK}:${PATH}"

# /x の決定論 slug (= unknown-session)。
SLUG="$(CLAUDE_SESSION_ID="" cch_session_slug /x)"

# 1) CLAUDE_SESSION_ID 設定 + TMUX_PANE 無し → slug 単独 (slug = CLAUDE_SESSION_ID 全体)。
#    CLAUDE_SESSION_ID は cch_session_slug の最優先解決に使われ slug 自体になる。suffix は付かない。
unset TMUX_PANE
K1="$(CLAUDE_SESSION_ID="abcdef1234567890" CLAUDE_CODE_SESSION_ID="" ctx_session_key /x)"
assert_eq "${K1}" "abcdef1234567890" "CLAUDE_SESSION_ID 設定 + 非 pane → slug 単独"

# 2) ★会話 UUID は suffix に使わない (修正の核心)。CLAUDE_CODE_SESSION_ID 設定 + 非 pane → slug 単独。
#    旧実装は ${SLUG}-99887766 を返し /clear で UUID が変わると不一致になっていた。
unset TMUX_PANE
K2="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="zzzz99887766" ctx_session_key /x)"
assert_eq "${K2}" "${SLUG}" "会話 UUID は suffix に使わない (非 pane → slug 単独)"

# 3) TMUX_PANE 設定 → <slug>-p<N> (% 除去)。
K3="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" TMUX_PANE="%45" ctx_session_key /x)"
assert_eq "${K3}" "${SLUG}-p45" "TMUX_PANE → -p<N> (% 除去)"

# 4) 全 unset → slug のみ。
K4="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" TMUX_PANE="" ctx_session_key /x)"
assert_eq "${K4}" "${SLUG}" "全 unset → slug のみ"

# 5) ★/clear 跨ぎ安定: 同一 pane なら会話 UUID が変わっても同一キー (handoff 復元の前提)。
KA="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="uuidBEFORE01" TMUX_PANE="%9" ctx_session_key /x)"
KB="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="uuidAFTER999" TMUX_PANE="%9" ctx_session_key /x)"
assert_eq "${KA}" "${KB}" "同一 pane + UUID 変化 → 同一キー (/clear 安定)"
assert_eq "${KA}" "${SLUG}-p9" "同一 pane → slug-p<N>"

# 6) co-located 衝突回避は pane で担保: 別 pane → 別キー。
KC="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" TMUX_PANE="%9" ctx_session_key /x)"
KD="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" TMUX_PANE="%10" ctx_session_key /x)"
assert_eq "$([ "${KC}" != "${KD}" ] && echo DIFF || echo SAME)" "DIFF" "別 pane → 別キー (衝突回避)"
assert_eq "${KC%-*}" "${KD%-*}" "同一 slug を共有 (slug 部一致)"

# 7) CLAUDE_SESSION_ID は slug を駆動 (明示 override)。pane 在りで <CLAUDE_SESSION_ID>-p<N>。
K7="$(CLAUDE_SESSION_ID="primary777" CLAUDE_CODE_SESSION_ID="secondary888" TMUX_PANE="%3" ctx_session_key /x)"
assert_eq "${K7}" "primary777-p3" "CLAUDE_SESSION_ID が slug を駆動 + pane suffix"

# 8) 非 tmux + 制御端末あり → slug-tty<dev> (/ を - に正規化、Codex #2 の正常系固定)。
K8="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" TMUX_PANE="" MOCK_TTY="pts/7" ctx_session_key /x)"
assert_eq "${K8}" "${SLUG}-ttypts-7" "非 tmux + tty → slug-tty<dev> (/ 正規化)"

# 9) 非 tmux + tty 同一なら /clear 跨ぎ安定 (UUID 変化でも同一キー)。
K9A="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="uuidX1" TMUX_PANE="" MOCK_TTY="pts/7" ctx_session_key /x)"
K9B="$(CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="uuidY2" TMUX_PANE="" MOCK_TTY="pts/7" ctx_session_key /x)"
assert_eq "${K9A}" "${K9B}" "非 tmux + 同一 tty + UUID 変化 → 同一キー (/clear 安定)"

rm -rf "${PSMOCK}"
report
