#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
H="${HERE}/../hooks/compaction-resume.sh"
export CLAUDE_SESSION_ID="rsess"
unset TMUX_PANE   # 既定は非 pane (slug 単独キー)。pane 依存ケースは各所で明示設定し期待キーを再計算する。
# handoff/flag は ctx_session_key (pane 基軸 per-session ユニーク) で命名される。
SESS="$(ctx_session_key /x)"

# 1) daemon 起因 clear (compacted フラグ立ち) + model.md → 再注入 (model 優先) + RESUME + REMINDER
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF model\n## 1. CURRENT GOAL\nMODEL_GOAL_X\n' > "${TMP}/handoffs/${SESS}.model.md"
printf '# HANDOFF mech\n## 1. CURRENT GOAL\nMECH_GOAL_Y\n'   > "${TMP}/handoffs/${SESS}.md"
: > "${TMP}/.compacted_${SESS}"   # daemon が /clear 送出済みを示す
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "additionalContext" "再注入 JSON"
assert_contains "${OUT}" "MODEL_GOAL_X" "model.md を優先"
NEG="$(printf '%s' "${OUT}" | grep -cF "MECH_GOAL_Y" || true)"
assert_eq "${NEG}" "0" "機械版 GOAL は注入されない (model 優先)"
assert_contains "${OUT}" "RESUME 手順" "RESUME 手順を付与"
assert_contains "${OUT}" "REMINDER" "末尾ゴール復唱"
# resume 後: compacted reset、model.md は iterative update 用に保持
assert_eq "$([ -e "${TMP}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "resume で compacted clear"
assert_file_exists "${TMP}/handoffs/${SESS}.model.md"

# 2) 明示 /compact (source=compact) は compacted 不要で再注入 (機械版 fallback)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF mech\n## 1. CURRENT GOAL\nMECH_ONLY\n' > "${TMP}/handoffs/${SESS}.md"
OUT="$(printf '{"source":"compact","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "MECH_ONLY" "/compact は機械版 fallback を再注入"

# 3) 手動 /clear (compacted 無し, fresh handoff 本文あり) → 再注入する (フラグ非依存化後の挙動)。
#    旧 I3 (手動 /clear はクリーン開始で再注入しない) を反転。実運用は /clear して復元を期待するため、
#    fresh handoff があれば source=clear でも復元する。episode reset は引き続き走り model.md は保持。
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF\n## 1. CURRENT GOAL\nMANUAL_CLEAR_GOAL\n' > "${TMP}/handoffs/${SESS}.model.md"; : > "${TMP}/.episode_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "additionalContext" "手動 /clear (fresh handoff) → 再注入する"
assert_contains "${OUT}" "MANUAL_CLEAR_GOAL" "手動 /clear → handoff 本文を再注入"
assert_eq "$([ -e "${TMP}/.episode_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "手動 /clear でも episode reset"
assert_file_exists "${TMP}/handoffs/${SESS}.model.md"

# 4) startup/resume は no-op
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf 'x' > "${TMP}/handoffs/${SESS}.model.md"; : > "${TMP}/.compacted_${SESS}"
assert_eq "$(printf '{"source":"startup","cwd":"/x"}' | bash "${H}")" "" "startup は no-op"
assert_eq "$(printf '{"source":"resume","cwd":"/x"}' | bash "${H}")" "" "resume は no-op"

# --- 修正③: handoff 空/不在の no-op fallback ガイダンス -----------------------
# handoff が空/不在で source=compact|clear のとき、silent no-op だと文脈ゼロで再開し
# 別タスクを始めてしまう。最小ガイダンスを additionalContext で出す。
FALLBACK_MARK="自動ハンドオフが空でした"

# 5) handoff 不在 + source=clear → fallback ガイダンスを出す
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "additionalContext" "handoff不在(clear) → fallback JSON"
assert_contains "${OUT}" "${FALLBACK_MARK}" "handoff不在(clear) → 空ハンドオフ警告"
assert_contains "${OUT}" "進行中メモ" "fallback は進行中メモの確認を促す"
assert_contains "${OUT}" "git log" "fallback は git log の確認を促す"

# 6) handoff 不在 + source=compact → fallback ガイダンスを出す
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
OUT="$(printf '{"source":"compact","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "${FALLBACK_MARK}" "handoff不在(compact) → 空ハンドオフ警告"

# 7) handoff 空 (0 バイト model.md + 機械版不在) + source=clear → fallback
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
: > "${TMP}/handoffs/${SESS}.model.md"   # 0 バイト = 空
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "${FALLBACK_MARK}" "handoff空(clear) → fallback"

# 8) source=startup/resume → fallback も出さない (従来 no-op を厳守)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
assert_eq "$(printf '{"source":"startup","cwd":"/x"}' | bash "${H}")" "" "startup は fallback も出さない"
assert_eq "$(printf '{"source":"resume","cwd":"/x"}' | bash "${H}")" "" "resume は fallback も出さない"

# 9) handoff 存在 (通常ケース) → 本文を出し、fallback 警告は出さない (境界固定)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF model\n## 1. CURRENT GOAL\nREAL_GOAL\n' > "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "REAL_GOAL" "handoff存在 → 本文を再注入"
NEG="$(printf '%s' "${OUT}" | grep -cF "${FALLBACK_MARK}" || true)"
assert_eq "${NEG}" "0" "handoff存在時は fallback 警告を出さない"

# --- I-1b: SessionStart 自 state 即書き --------------------------------------
# pane 再利用直後、新住人が statusLine 発火する前の初回窓で古い残骸が現住人を僭称し
# 誤爆される。SessionStart の全 source で、自 state が未生成のときだけ自 pane を
# band=idle で即記録し、現住人突合の材料を先に置く。
# 制約: 既存 state があれば触らない (statusLine の band を idle で潰さない)。
#       TMUX_PANE 未設定なら書かない。idle band なので daemon は action=NONE で無害。
# 読み出しヘルパ (state json の任意フィールド)
state_field() {  # <state_path> <field>
    python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null
}

# 10) source=clear + TMUX_PANE + 自 state 無 → idle で自 state が書かれ pane 記録
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
export TMUX_PANE="%77"
SESS_P="$(ctx_session_key /x)"   # pane 基軸キー (= rsess-p77)。hook も同 TMUX_PANE でこのキーを使う。
printf '{"source":"clear","cwd":"/x"}' | bash "${H}" >/dev/null
STATE="${TMP}/state/${SESS_P}.json"
assert_file_exists "${STATE}"
assert_eq "$(state_field "${STATE}" band)" "idle" "自 state は band=idle で書かれる"
assert_eq "$(state_field "${STATE}" pane)" "%77" "自 state は自 pane (TMUX_PANE) を記録"
assert_eq "$(state_field "${STATE}" session_id)" "${SESS_P}" "自 state の session_id = ctx_session_key"
unset TMUX_PANE

# 11) 既存 state (band=compact) あり → 触らない (band 維持、idle で潰さない)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs" "${TMP}/state"
export TMUX_PANE="%77"
SESS_P="$(ctx_session_key /x)"   # rsess-p77
python3 -c "import json;json.dump({'session_id':'${SESS_P}','band':'compact','cwd':'/x','used_pct':60,'used_tokens':0,'window_size':0,'ts':'t','pane':'%77'},open('${TMP}/state/${SESS_P}.json','w'))"
printf '{"source":"clear","cwd":"/x"}' | bash "${H}" >/dev/null
assert_eq "$(state_field "${TMP}/state/${SESS_P}.json" band)" "compact" "既存 state あり → band 維持 (触らない)"
unset TMUX_PANE

# 12) source=startup でも自 state が書かれる (case ガードより前で実行)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
export TMUX_PANE="%88"
SESS_P="$(ctx_session_key /x)"   # rsess-p88
printf '{"source":"startup","cwd":"/x"}' | bash "${H}" >/dev/null
STATE="${TMP}/state/${SESS_P}.json"
assert_file_exists "${STATE}"
assert_eq "$(state_field "${STATE}" band)" "idle" "startup でも自 state を idle で書く"
assert_eq "$(state_field "${STATE}" pane)" "%88" "startup でも自 pane を記録"
unset TMUX_PANE

# 13) TMUX_PANE 未設定 → 自 state を書かない
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
unset TMUX_PANE
printf '{"source":"clear","cwd":"/x"}' | bash "${H}" >/dev/null
assert_eq "$([ -e "${TMP}/state/${SESS}.json" ] && echo SET || echo UNSET)" "UNSET" "TMUX_PANE 未設定 → 自 state 書かない"


# --- M-3: handoff 空白/改行のみを空扱い --------------------------------------
# [ -s ] (サイズ>0) は空白/改行のみを非空と誤判定する。ctx_file_has_text (strip 後非空判定)
# を使い、空白のみ handoff は空扱いして fallback ガイダンスを出す。
FALLBACK_MARK_M3="自動ハンドオフが空でした"

# 14) 空白/改行のみ model.md (機械版不在) + source=clear → 空扱いで fallback
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '   \n\t\n  \n' > "${TMP}/handoffs/${SESS}.model.md"   # 空白/改行のみ (サイズ>0)
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "${FALLBACK_MARK_M3}" "空白のみ handoff → 空扱いで fallback ガイダンス"

# 15) 空白のみ model.md だが機械版に本文あり (compacted 立ち) → 機械版を再注入 (空扱いの否定)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '   \n  \n' > "${TMP}/handoffs/${SESS}.model.md"   # 空白のみ → 空扱い
printf '# HANDOFF mech\n## 1. CURRENT GOAL\nMECH_RECOVER\n' > "${TMP}/handoffs/${SESS}.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "MECH_RECOVER" "空白 model.md → 機械版 (本文あり) に fallback して再注入"
NEG="$(printf '%s' "${OUT}" | grep -cF "${FALLBACK_MARK_M3}" || true)"
assert_eq "${NEG}" "0" "機械版に本文あり → 空ハンドオフ警告は出さない"

# 16) 本文ありの通常 model.md (境界固定: 空白判定が本文を誤って空扱いしない)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF model\n## 1. CURRENT GOAL\nNONBLANK_GOAL\n' > "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "NONBLANK_GOAL" "本文ある model.md → 通常通り再注入 (空扱いしない)"

rm -rf "${TMP}"
report
