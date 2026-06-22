#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"

# tmux mock:
#   list-panes -F '#{pane_id}'  (存在確認)         → env PANE_IDS (既定 "%9")
#   list-panes (3列 cwd 突合)                       → "%9 /x node"
#   capture-pane                                    → $CAP
#   send-keys                                       → ログ (SENDFAIL=1 で失敗)
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    # -F '#{pane_id}' (pane_id 単独) なら存在リストを返す。それ以外は cwd 突合用の3列。
    if printf '%s\n' "$@" | grep -qF '#{pane_id}' && ! printf '%s\n' "$@" | grep -qF '#{pane_current_path}'; then
      printf '%s\n' "${PANE_IDS:-%9}"
    else
      echo "%9 /x node"
    fi
    ;;
  capture-pane) printf '%s' "${CAP:-idle prompt >}";;
  send-keys)    if [ "${SENDFAIL:-0}" = 1 ]; then exit 1; fi; shift; echo "$*" >> "${TMUX_LOG}";;
esac
M
chmod +x "${TMOCK}/tmux"

mk() {  # <home> <band> [handoff:mech|model|both] [pane]
    mkdir -p "$1/state" "$1/handoffs"
    python3 -c "import json,sys;json.dump({'session_id':'wt-a','band':sys.argv[2],'cwd':'/x','used_pct':0,'used_tokens':0,'window_size':0,'ts':'t','pane':sys.argv[3]},open(sys.argv[1]+'/state/wt-a.json','w'))" "$1" "$2" "${4:-%9}"
    case "${3:-}" in
        mech)  printf 'mech handoff'  > "$1/handoffs/wt-a.md" ;;
        model) printf 'model handoff' > "$1/handoffs/wt-a.model.md" ;;
        both)  printf 'mech handoff'  > "$1/handoffs/wt-a.md"
               printf 'model handoff' > "$1/handoffs/wt-a.model.md" ;;
    esac
}
run() {  # <home> [capture] [sendfail] [pane_ids]
    export TMUX_LOG="$1/inject.log"; : > "${TMUX_LOG}"
    COOLDOWN_SECONDS=0 CAP="${2:-idle prompt >}" SENDFAIL="${3:-0}" PANE_IDS="${4:-%9}" \
        RESUME_DELAY_SECONDS=0 RESUME_MAX_WAIT_SECONDS=0 RESUME_REENTER_MAX=0 \
        PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once
    cat "${TMUX_LOG}"
}

# --- NEW: ハンドオフ厳格化 (詳細 model.md 必須で /clear) -----------------------
# 機械版 .md は transcript 機械抽出で薄く、それだけで /clear すると復元品質が低く文脈喪失を招く。
# tick の work喪失防止ガードを「model.md 非空でなければ /clear しない」に厳格化した。
# 機械版 .md だけでは撃たない (critical 安全弁も実質 model.md 必須になる)。

# 1) [NEW 核心] critical + 機械版 .md のみ (model.md 無) → /clear しない。
#    旧挙動では機械版だけで撃っていたが、薄い復元での文脈喪失を防ぐため厳格化。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical mech
assert_eq "$(run "${T}")" "" "critical + 機械版のみ (model.md無) → /clearしない (NEW 厳格化)"
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "UNSET" "機械版のみ → compacted も立たない"

# 1b) [NEW] critical + model.md (非空) → /clear する
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
assert_contains "$(run "${T}")" "/compact" "critical + model.md (非空) → /compact"

# 2) compact + prepared(model.md) → /clear
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" compact model
assert_contains "$(run "${T}")" "/compact" "compact∧prepared(model.md)→/compact"

# 3) compact + 未prepared(handoffなし) → 注入なし
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" compact
assert_eq "$(run "${T}")" "" "compact∧未prepared→注入なし"

# 4) compact + prepared + busy pane → 注入なし
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" compact model
assert_eq "$(run "${T}" 'generating… esc to interrupt')" "" "busy pane→注入なし"

# 5) compacted フラグ済み → 注入なし (resume 待ち・冪等)。NEW 厳格化に合わせ model.md を用意。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
: > "${T}/.compacted_wt-a"
assert_eq "$(run "${T}")" "" "compacted済→冪等(注入なし)"

# 6) 注入成功後に compacted フラグが立つ (model.md 必須)
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
run "${T}" >/dev/null
assert_file_exists "${T}/.compacted_wt-a"

# 7) [work喪失防止] critical だが handoff 皆無 → 注入なし
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical
assert_eq "$(run "${T}")" "" "critical∧handoff皆無→/clearしない(再注入源を待つ)"

# 8) [I2] send-keys 失敗 → 注入ログ空 かつ compacted を立てない (デッドロック防止)。model.md 必須。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
OUT="$(run "${T}" 'idle prompt >' 1)"
assert_eq "${OUT}" "" "send-keys 失敗 → ログ空"
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "UNSET" "送出失敗時は compacted を立てない"

# 9) [鮮度ゲート] stale state (mtime 古い=終了済セッション残骸) → critical+handoff でも触らない
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
touch -d '10 minutes ago' "${T}/state/wt-a.json"
assert_eq "$(run "${T}")" "" "stale state → daemon 触らない (stale 大量 /clear 防止)"
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "UNSET" "stale は compacted も立てない"

# 10) [鮮度ゲート] fresh state (mtime now) → 通常通り処理 (critical+model.md→/clear)
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
assert_contains "$(run "${T}")" "/compact" "fresh state → 通常処理"

# 11) [pane 直接ターゲット] 記録 pane が tmux に実在 → その pane を直接使用 (cwd fallback を経ない)
#     記録 pane=%7、存在リストにも %7 を含める。cwd 突合は %9 を返すため、送出先が %7 なら
#     直接ターゲット経路が成立したことの決定的証拠 (cwd fallback なら %9 になる)。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model "%7"
assert_contains "$(run "${T}" 'idle prompt >' 0 '%9
%7')" "%7 /compact" "記録 pane 実在 → %7 を直接ターゲット (cwd fallback %9 でない)"

# 12) [pane fallback] state の pane が空 → resolve_pane_by_cwd に fallback (cwd=/x→%9) で /clear
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model ""
assert_contains "$(run "${T}")" "%9 /compact" "pane 空 → cwd fallback (%9) で /compact"

# 13) [pane 不実在 fallback] 記録 pane が tmux に無い → cwd fallback (%9) で /clear
#     記録 pane=%99、存在リストには %9 のみ → 直接ターゲット不可 → cwd 突合に degrade
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model "%99"
assert_contains "$(run "${T}" 'idle prompt >' 0 '%9')" "%9 /compact" "記録 pane 不実在 → cwd fallback (%9) で /compact"

# 14) [NEW 補強] model.md + 機械版 .md 両方あり → /clear (model.md があれば撃つ)
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical both
assert_contains "$(run "${T}")" "/compact" "model.md + 機械版両方 → /compact (model.md 在り)"

# === I1: /compact 送出前の入力欄 bounded defer (ユーザー下書き clobber 防止) ===
# 入力欄 (───罫線間) にユーザーの下書きがある間は圧縮を defer (重ねて clobber しない)。ただし連続 defer
# が COMPACT_DEFER_MAX を超えたら下書きを犠牲にしても圧縮する (box false-positive 等で圧縮が恒久
# ブロック=overflow=stall方向に倒れるのを防ぐ。stall < clobber のユーザー安全原則)。
BOXUSER='hist
─────
❯ ユーザーが先に打った長めの下書きテキストです
─────
👤 footer'
# 15) 1回目: 入力欄に下書き → 圧縮 defer (注入なし) かつ compacted 非設定 (clobber 防止)、counter=1
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; export COMPACT_DEFER_MAX=2; mk "${T}" critical model
assert_eq "$(run "${T}" "${BOXUSER}")" "" "I1: 入力欄に下書き → 圧縮 defer (注入なし)"
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "UNSET" "I1: defer 中は compacted を立てない"
assert_eq "$(cat "${T}/.compact_defer_wt-a" 2>/dev/null)" "1" "I1: defer counter = 1"
# 16) 2回目: まだ上限(2)未満 → defer 継続、counter=2
assert_eq "$(run "${T}" "${BOXUSER}")" "" "I1: 2回目も defer (注入なし)"
assert_eq "$(cat "${T}/.compact_defer_wt-a" 2>/dev/null)" "2" "I1: defer counter = 2"
# 17) 3回目: 上限(2)到達 → 入力欄を C-u clear してから /compact 送出 (下書き連結を防ぎ実際に圧縮成立)
OUT17="$(run "${T}" "${BOXUSER}")"
assert_contains "${OUT17}" "/compact" "I1: defer 上限到達 → /compact (overflow/stall 防止)"
assert_contains "${OUT17}" "C-u" "I1: cap で C-u 入力欄 clear してから圧縮 (Codex I1/C2: 下書き連結=圧縮不発を防ぐ)"
unset COMPACT_DEFER_MAX
# 18) 空入力欄 (下書きなし) → defer せず即 /compact、counter も付かない
EMPTYBOX='hist
─────
❯
─────
👤 footer'
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
assert_contains "$(run "${T}" "${EMPTYBOX}")" "/compact" "I1: 空入力欄 → defer せず /compact"
assert_eq "$([ -e "${T}/.compact_defer_wt-a" ] && echo SET || echo UNSET)" "UNSET" "I1: 空入力欄 → defer counter 付かない"

rm -rf "${TMOCK}" "${T}"
report
