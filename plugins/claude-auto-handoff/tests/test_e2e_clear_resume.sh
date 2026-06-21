#!/usr/bin/env bash
# test_e2e_clear_resume.sh — エンドツーエンド統合テスト。
# daemon の /clear 注入 → compaction-resume の復元 を 1 本の流れで再現し、
# 「pane を正しく撃ち、撃った相手のハンドオフが正しく復元される」ことを保証する。
#   ① state に compact band + 詳細 model.md (識別子 "RESUME_GOAL_E2E") を用意。
#   ② tmux モック (send-keys/capture-pane/list-panes/sleep) + idle pane で daemon --once。
#   ③ "/clear Enter" 送出 + 継続プロンプト送出 + .compacted_<SESS> が立つことを検証。
#   ④ compaction-resume を同 SESS / compacted フラグ / TMUX_PANE 設定で実行。
#   ⑤ additionalContext に "RESUME_GOAL_E2E" が含まれ RESUME 手順が付き compacted が reset。
#   ⑥ 対称ケース: model.md 無 (機械版のみ・critical 帯) → daemon は /clear しない (NEW 厳格化)。
#      critical 帯を使うのは、decide_action が prepared 不問で CLEAR を返すため、ここで /clear を
#      止めるのが「model.md 必須」厳格化ガードだけになり、厳格化の効果を決定的に検証できるから。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"
RESUME="${HERE}/../hooks/compaction-resume.sh"

# SESS は daemon が読む state の session_id フィールドと resume が計算する ctx_session_key を
# 一致させる必要がある (daemon が立てる .compacted_<sid> を resume が同名で reset するため)。
# ctx_session_key は pane 基軸 (slug-p<N>) なので、この E2E が模す pane %5 を TMUX_PANE に固定し、
# slug 駆動の CLAUDE_SESSION_ID と合わせて SESS を決定論化する (= e2esess-p5)。これにより
# 「daemon が撃つ pane」「state.pane」「resume が走る pane」が全て %5 で一致する。
export CLAUDE_SESSION_ID="e2esess"
export TMUX_PANE="%5"
SESS="$(ctx_session_key /e2e)"

# tmux + sleep モック (待機せず、send-keys を記録、capture/list-panes を制御)
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    if printf '%s\n' "$@" | grep -qF '#{pane_id}' && ! printf '%s\n' "$@" | grep -qF '#{pane_current_path}'; then
      printf '%s\n' "${PANE_IDS:-%5}"
    else
      echo "%5 /e2e node"
    fi
    ;;
  capture-pane) printf '%s' "${CAP:-app ❯ idle}";;
  send-keys)    shift; printf '%s\n' "$*" >> "${TMUX_LOG}";;
esac
M
chmod +x "${TMOCK}/tmux"
cat > "${TMOCK}/sleep" <<'M'
#!/usr/bin/env bash
:
M
chmod +x "${TMOCK}/sleep"

# --- ① state + 詳細 model.md を用意 ------------------------------------------
seed() {  # <home> <handoff_kind:model|mech> <band>
    mkdir -p "$1/state" "$1/handoffs"
    python3 -c "import json,sys;json.dump({'session_id':sys.argv[2],'band':sys.argv[3],'cwd':'/e2e','used_pct':60,'used_tokens':0,'window_size':0,'ts':'t','pane':'%5'},open(sys.argv[1]+'/state/'+sys.argv[2]+'.json','w'))" "$1" "${SESS}" "$3"
    if [ "$2" = "model" ]; then
        # prepared 判定 (model.md が episode stamp より新しい) を満たすよう
        # episode stamp を古く作り model.md を now にする → prepared。
        printf '# HANDOFF\n## 1. CURRENT GOAL\nRESUME_GOAL_E2E — 統合テスト復元目標\n## 3. NEXT STEPS\n次の一手\n' > "$1/handoffs/${SESS}.model.md"
        : > "$1/.episode_${SESS}"
        touch -d '1 minute ago' "$1/.episode_${SESS}"
    else
        printf 'thin mechanical snapshot\n' > "$1/handoffs/${SESS}.md"
    fi
}

# === メインケース: model.md ありで /clear → 復元 ============================
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; seed "${T}" model compact

# ② daemon --once (idle pane, pane %5 実在)
export TMUX_LOG="${T}/inject.log"; : > "${TMUX_LOG}"
COOLDOWN_SECONDS=0 PANE_IDS="%5" CAP="app ❯ idle" PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once
OUT_DAEMON="$(cat "${TMUX_LOG}")"

# ③ /clear + 継続プロンプト送出 + compacted フラグ
assert_contains "${OUT_DAEMON}" "/compact Enter" "daemon が pane %5 に /compact Enter を送出"
assert_contains "${OUT_DAEMON}" "言い直してから作業を継続せよ" "daemon が継続プロンプトを送出"
assert_eq "$([ -e "${T}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "SET" "/clear 送出で .compacted が立つ"

# ④ compaction-resume を同 SESS / TMUX_PANE 設定で実行。daemon は既定で /compact を送るため
#    SessionStart の source は "compact" になる (実フロー忠実)。復元はフラグ非依存なので
#    compacted フラグの有無に関わらず fresh handoff があれば再注入される。
export TMUX_PANE="%5"
OUT_RESUME="$(printf '{"source":"compact","cwd":"/e2e"}' | bash "${RESUME}")"

# ⑤ 以前の作業が正しく復元される + RESUME 手順 + compacted reset
assert_contains "${OUT_RESUME}" "RESUME_GOAL_E2E" "resume が model.md の目標を復元注入 (以前の作業)"
assert_contains "${OUT_RESUME}" "RESUME 手順" "resume が RESUME 手順を付与"
assert_contains "${OUT_RESUME}" "REMINDER" "resume が最優先ゴールを末尾復唱"
assert_contains "${OUT_RESUME}" "次の一手" "resume が NEXT STEPS も含めて復元"
assert_eq "$([ -e "${T}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "resume 後 compacted が reset"
# model.md は iterative update 用に保持される
assert_file_exists "${T}/handoffs/${SESS}.model.md"
unset TMUX_PANE

# === 対称ケース: model.md 無 (機械版のみ・critical 帯) → daemon は /clear しない ===
# critical 帯は decide_action が prepared 不問で CLEAR を返すため、/clear を止めるのは
# 「model.md 必須」厳格化ガードだけ → 厳格化の効果を決定的に検証する。
T2="$(mktemp -d)"; export CC_COMPACTION_HOME="${T2}"; seed "${T2}" mech critical
export TMUX_LOG="${T2}/inject.log"; : > "${TMUX_LOG}"
COOLDOWN_SECONDS=0 PANE_IDS="%5" CAP="app ❯ idle" PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once
OUT_MECH="$(cat "${TMUX_LOG}")"
assert_eq "${OUT_MECH}" "" "model.md 無 (機械版のみ・critical) → daemon は /clear しない (NEW 厳格化)"
assert_eq "$([ -e "${T2}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "機械版のみ → compacted も立たない"

rm -rf "${TMOCK}" "${T}" "${T2}"
report
