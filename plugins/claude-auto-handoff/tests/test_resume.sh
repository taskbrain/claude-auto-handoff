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

# --- P1b: NEXT STEPS 薄さ警告 (Stage3 additionalContext, warn-only) ----------
# model.md の NEXT STEPS 節が薄い (具体的な次の一手が無い) と、復帰後の最初の turn が漠然となる。
# ctx_handoff_next_steps_thin で薄さを検出し additionalContext に補強ガイダンスを追加する。
# ★圧縮は止めない (純テキスト注入、stall risk ゼロ)。見出し不在/ファイル不在は薄いと断定しない。
NS_MARK="NEXT STEPS 補強"

# 17) ヘルパ単体: 薄い NEXT STEPS (短い1行) → thin(0)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '## 2. STATE\nいろいろ詳細な状態がここに書かれている長い本文。\n## 3. NEXT STEPS\n1. 続き\n## 4. OPEN FILES\n/x/y\n' > "${TMP}/thin.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/thin.md" && echo THIN || echo OK)" "THIN" "P1b: 短い NEXT STEPS → thin"
# 18) ヘルパ単体: 十分な NEXT STEPS (長い本文) → not thin(1)
printf '## 3. NEXT STEPS\n1. まず対象ファイルを読み込んで現在の状態を把握する\n2. 次に実装を進めてテストを通す\n3. 最後に全体を確認してレビューに出す\n## 4. OPEN FILES\n' > "${TMP}/fat.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/fat.md" && echo THIN || echo OK)" "OK" "P1b: 十分な NEXT STEPS → not thin"
# 19) ヘルパ単体: NEXT STEPS 見出し不在 → 薄いと断定しない (not thin)
printf '## 1. CURRENT GOAL\nやること\n## 2. STATE\n状態\n' > "${TMP}/noheading.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/noheading.md" && echo THIN || echo OK)" "OK" "P1b: 見出し不在 → 薄いと断定しない (誤警告回避)"
# 20) ヘルパ単体: ファイル不在 → not thin
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/nope.md" && echo THIN || echo OK)" "OK" "P1b: ファイル不在 → 薄いと断定しない"
# 21) ヘルパ単体: 番号付きリストは本文として数える (見出し境界は #/罫線のみ → リストで切らない)
printf '## 3. NEXT STEPS\n1. 最初のステップでまず対象ファイルを読み込んで状態を把握する\n2. 次のステップで実装を進めてテストを通す\n3. 最後に全体を確認してレビューに出す\n## 4. X\n' > "${TMP}/listy.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/listy.md" && echo THIN || echo OK)" "OK" "P1b: 番号付きリストは本文として数える (1. で切らない)"
# 22) ヘルパ単体: min_chars 引数で閾値を上書きできる
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/fat.md" 99999 && echo THIN || echo OK)" "THIN" "P1b: min_chars 引数で閾値上書き (大きすれば thin 判定)"
# 22b) 散文で 'NEXT STEPS' に言及しても見出し行のみを見出しと認識し実節 (充実) を測る (false THIN を出さない)
printf '## 2. STATE\nここで状態を説明する。詳細は後述の NEXT STEPS 節を参照すること。\n## 3. NEXT STEPS\n1. まず対象を読み込んで状態を把握する\n2. 実装してテストを通す\n3. レビューに出す\n## 4. X\n' > "${TMP}/prose.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/prose.md" && echo THIN || echo OK)" "OK" "P1b minor: 散文の 'NEXT STEPS' 言及を見出し誤認しない"
# 22c) 散文言及のみ (実見出し無し) → 薄いと断定しない (not thin)
printf '## 1. GOAL\nやること\n## 2. STATE\n後で NEXT STEPS を埋める予定。\n' > "${TMP}/prose_only.md"
assert_eq "$(ctx_handoff_next_steps_thin "${TMP}/prose_only.md" && echo THIN || echo OK)" "OK" "P1b minor: 散文言及のみ (実見出し無し) → 薄いと断定しない"
# 22d) 非数値 min_chars (誤設定) → 安全側 (not thin = 警告抑制)
assert_eq "$(NEXT_STEPS_MIN_CHARS=abc ctx_handoff_next_steps_thin "${TMP}/thin.md" && echo THIN || echo OK)" "OK" "P1b minor: 非数値 NEXT_STEPS_MIN_CHARS → not thin (安全側)"

# 23) 統合: 薄い NEXT STEPS の handoff + source=clear → additionalContext に補強ガイダンス
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF\n## 1. CURRENT GOAL\nTHIN_NS_GOAL\n## 3. NEXT STEPS\n1. 続き\n## 4. OPEN FILES\n/x\n' > "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "THIN_NS_GOAL" "P1b統合: 本文は再注入される"
assert_contains "${OUT}" "${NS_MARK}" "P1b統合: 薄い NEXT STEPS → 補強ガイダンスを additionalContext に追加"

# 24) 統合: 十分な NEXT STEPS の handoff → 補強ガイダンスは出さない (境界固定)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
printf '# HANDOFF\n## 1. CURRENT GOAL\nFAT_NS_GOAL\n## 3. NEXT STEPS\n1. まず実装してテストを通す\n2. 次にレビューに出す\n3. 最後にドキュメントを更新する\n## 4. OPEN FILES\n' > "${TMP}/handoffs/${SESS}.model.md"
: > "${TMP}/.compacted_${SESS}"
OUT="$(printf '{"source":"clear","cwd":"/x"}' | bash "${H}")"
assert_contains "${OUT}" "FAT_NS_GOAL" "P1b統合: 本文は再注入される (十分ケース)"
NEG="$(printf '%s' "${OUT}" | grep -cF "${NS_MARK}" || true)"
assert_eq "${NEG}" "0" "P1b統合: 十分な NEXT STEPS → 補強ガイダンスを出さない"

rm -rf "${TMP}"
report
