#!/usr/bin/env bash
# pane 再利用時の誤復元防止 (世代マーカー) — デュアルレビュー must-fix 1 の回帰テスト。
#
# pane 基軸キー (slug-p<N>) は同一 pane を順次使う別セッション間で共有される。前占有者が書いた
# fresh handoff が残っているとき、新占有者の SessionStart(startup) → 手動 /clear/compact で
# 旧占有者の作業が誤復元されてしまう (鮮度ゲートは「30分以内の pane 再利用」を防げない)。
# 修正: startup|resume で世代マーカー (.gen_<sess>) を touch し、復元は handoff.mtime >= gen.mtime を
# 要求する。前占有者の handoff (gen より古い) は復元されない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
H="${HERE}/../hooks/compaction-resume.sh"

export CLAUDE_SESSION_ID="rsess"
export TMUX_PANE="%77"
SESS="$(ctx_session_key /x)"   # rsess-p77
FALLBACK_MARK="自動ハンドオフが空でした"

run_resume() { printf '{"source":"%s","cwd":"/x"}' "$1" | bash "${H}"; }

# === ケース1: pane 再利用 → 旧 handoff は復元されない ===========================
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
# 前占有者の handoff (fresh だが 5 秒前に書かれた = この後の startup より古い)
printf '# HANDOFF\n## 1. CURRENT GOAL\nPREV_OCCUPANT_WORK\n' > "${TMP}/handoffs/${SESS}.model.md"
touch -d '5 seconds ago' "${TMP}/handoffs/${SESS}.model.md"
# 新占有者プロセスが起動 → startup で世代マーカーを touch (now)
run_resume startup >/dev/null
# 新占有者が手動 /clear → 旧占有者の handoff は復元されてはならない
OUT="$(run_resume clear)"
NEG="$(printf '%s' "${OUT}" | grep -cF "PREV_OCCUPANT_WORK" || true)"
assert_eq "${NEG}" "0" "pane 再利用: startup 後の /clear で旧占有者の handoff は復元しない"
assert_contains "${OUT}" "${FALLBACK_MARK}" "pane 再利用: 旧 handoff 不可視 → 空ガイダンスに degrade"
# 世代マーカーが startup で作られている
assert_file_exists "${TMP}/.gen_${SESS}"

# === ケース2: 同一セッション (自分の handoff = gen より新しい) → 復元する ========
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
# 自セッションが startup → 世代マーカー touch (古い時刻に固定)
run_resume startup >/dev/null
touch -d '2 minutes ago' "${TMP}/.gen_${SESS}"
# その後に自分で handoff を書く (gen より新しい)
printf '# HANDOFF\n## 1. CURRENT GOAL\nMY_OWN_WORK\n' > "${TMP}/handoffs/${SESS}.model.md"
OUT="$(run_resume compact)"
assert_contains "${OUT}" "MY_OWN_WORK" "同一セッション: 自分の handoff (gen より新) は復元する"

# === ケース3: 世代マーカー無し (旧来/未 startup) → 従来どおり復元 (後方互換) ======
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF\n## 1. CURRENT GOAL\nNO_GEN_RESTORE\n' > "${TMP}/handoffs/${SESS}.model.md"
# startup を踏まず直接 compact (gen マーカー不在)
OUT="$(run_resume compact)"
assert_contains "${OUT}" "NO_GEN_RESTORE" "世代マーカー無し → 従来どおり復元 (後方互換)"

# === ケース4: 非 tmux (tty キー) でも世代マーカーが stamp され誤復元を防ぐ (follow-up gap 修正) ==
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
unset TMUX_PANE
SESS_NT="$(ctx_session_key /x)"   # 非 tmux キー (tty or slug 単独)
printf '# HANDOFF\n## 1. CURRENT GOAL\nPREV_TTY_WORK\n' > "${TMP}/handoffs/${SESS_NT}.model.md"
touch -d '5 seconds ago' "${TMP}/handoffs/${SESS_NT}.model.md"
# 新占有者プロセスが startup → 非 tmux でも世代マーカーが touch される
printf '{"source":"startup","cwd":"/x"}' | bash "${H}" >/dev/null
assert_file_exists "${TMP}/.gen_${SESS_NT}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
NEG="$(printf '%s' "${OUT}" | grep -cF "PREV_TTY_WORK" || true)"
assert_eq "${NEG}" "0" "非tmux: startup 後の /clear で旧 tty 占有者の handoff は復元しない"

rm -rf "${TMP}"
report
