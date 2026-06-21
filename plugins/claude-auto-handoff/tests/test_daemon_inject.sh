#!/usr/bin/env bash
# 修正①: inject() の /clear 後の待機可変化 + 継続プロンプト残留時の Enter 再確定。
# 大 context の /clear リロード完了前にプロンプト+Enter が届くと Enter が取りこぼされ
# テキストだけ入力欄に残る (ユーザー実報告)。待機を CLEAR_RESUME_DELAY_SECONDS で延長し、
# capture-pane に継続プロンプト文言が残留していれば best-effort で Enter を再送する。
# M-1: 残留判定を capture 末尾3行 (入力欄相当) に限定し、再 Enter 直前に pane_is_idle を
#      再確認する (送信済みプロンプトが画面履歴に残る正常時の不要 Enter / busy 中の誤 Enter を防ぐ)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"

# tmux + sleep mock:
#   sleep <N>           → 実待機せず N を SLEEP_LOG に記録 (待機可変化の検証用)
#   send-keys           → 引数を SEND_LOG に記録 (SENDFAIL=1 で /clear 本体だけ失敗)
#   capture-pane        → $CAP (残留文言注入用、CAPFAIL=1 で失敗=best-effort 経路)
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    if [ "${SENDFAIL:-0}" = 1 ]; then
      # 圧縮コマンド本体 (引数に "/compact") のみ失敗させる
      printf '%s\n' "$@" | grep -qF '/compact' && exit 1
    fi
    shift; printf '%s\n' "$*" >> "${SEND_LOG}";;
  capture-pane)
    [ "${CAPFAIL:-0}" = 1 ] && exit 1
    printf '%b' "${CAP:-}";;
esac
M
chmod +x "${TMOCK}/tmux"
cat > "${TMOCK}/sleep" <<'M'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${SLEEP_LOG}"
M
chmod +x "${TMOCK}/sleep"

# inject を直接呼ぶ (--source-only で関数だけ読み込む)
# CAP は printf '%b' で展開されるため \n でマルチライン入力欄を表現できる。
run_inject() {  # <home> <cap> <sendfail> <capfail> <delay>
    SEND_LOG="$1/send.log"; SLEEP_LOG="$1/sleep.log"; : > "${SEND_LOG}"; : > "${SLEEP_LOG}"
    export SEND_LOG SLEEP_LOG
    # 注意: _ctx_common.sh が auto_compaction.conf を source し env を上書きするため、
    # RESUME_DELAY_SECONDS は daemon source 後 (inject 呼出直前) に設定して
    # conf 既定 (12) の clobber を上書きする (call-time の ${VAR:-12} が拾う)。
    PATH="${TMOCK}:${PATH}" CAP="${2:-}" SENDFAIL="${3:-0}" CAPFAIL="${4:-0}" \
        DELAY="${5:-5}" bash -c '
            . "'"${DAEMON}"'" --source-only
            RESUME_DELAY_SECONDS="${DELAY}"
            # 既存 8 ケースは「単発 re-Enter」セマンティクスを検証する。Part B の poll / multi-retry
            # は test_inject_timing.sh で検証するため、ここでは poll を no-op (maxw=DELAY) かつ
            # 再 Enter を最大 1 回に固定し、従来アサーション (send-keys 2/3 回) を保つ。
            RESUME_MAX_WAIT_SECONDS="${DELAY}"
            RESUME_REENTER_MAX=1
            inject "%5" COMPACT
        '
    return $?
}

# 1) 待機が CLEAR_RESUME_DELAY_SECONDS 設定値で効く (既定 5 でなく明示 3)
T="$(mktemp -d)"
run_inject "${T}" "" 0 0 3 >/dev/null
assert_contains "$(cat "${T}/sleep.log")" "3" "圧縮後の待機が RESUME_DELAY_SECONDS=3 で効く"

# 2) 残留文言が末尾3行にあり (入力欄) + idle → 追加の Enter send-keys が呼ばれる
T="$(mktemp -d)"
run_inject "${T}" "app ❯ 言い直してから作業を継続せよ" 0 0 5 >/dev/null
# /clear + 継続プロンプト + 追加 Enter の計3回 send-keys
SENDS="$(grep -c . "${T}/send.log")"
assert_eq "${SENDS}" "3" "残留 (末尾3行) + idle → 追加 Enter で send-keys 3 回"
# 最後の行は単独 Enter (継続プロンプト文言を含まない、mock は '-t <pane>' 前置で記録)
LAST="$(tail -1 "${T}/send.log")"
assert_eq "${LAST}" "-t %5 Enter" "残留時の再確定は単独 Enter"

# 3) 残留なし (capture が idle プロンプトのみ) → 追加 Enter は呼ばれない (send-keys 2 回)
T="$(mktemp -d)"
run_inject "${T}" "app ❯ ready" 0 0 5 >/dev/null
SENDS="$(grep -c . "${T}/send.log")"
assert_eq "${SENDS}" "2" "残留なし → 追加 Enter なし (send-keys 2 回)"

# 4) capture 失敗 (best-effort) → 握り潰し、/clear+継続プロンプトは送出、戻り値 0
T="$(mktemp -d)"
run_inject "${T}" "" 0 1 5 >/dev/null; RC=$?
assert_eq "${RC}" "0" "capture 失敗でも inject は成功 (best-effort)"
assert_contains "$(cat "${T}/send.log")" "/compact" "capture 失敗でも /compact は送出"

# 5) /clear 本体送出失敗 → 戻り値 1 (caller がデッドロックしないよう失敗を返す)
T="$(mktemp -d)"
run_inject "${T}" "" 1 0 5 >/dev/null; RC=$?
assert_eq "${RC}" "1" "/compact 送出失敗 → return 1"

# --- M-1: 入力欄限定 (末尾3行) + idle 再確認 -----------------------------------

# 6) 文言が末尾3行の外 (画面履歴) のみ → 再 Enter なし (send-keys 2 回)。
#    送信済みプロンプトが履歴に残る正常時を模す。末尾3行は idle プロンプトのみ。
T="$(mktemp -d)"
run_inject "${T}" "言い直してから作業を継続せよ\nout1\nout2\nout3\napp ❯ ready" 0 0 5 >/dev/null
SENDS="$(grep -c . "${T}/send.log")"
assert_eq "${SENDS}" "2" "文言が末尾3行外 (履歴) のみ → 再 Enter なし (send-keys 2 回)"

# 7) 末尾3行に残留かつ idle → 再 Enter (send-keys 3 回)。
T="$(mktemp -d)"
run_inject "${T}" "old history line\nfiller\napp ❯ 言い直してから作業を継続せよ" 0 0 5 >/dev/null
SENDS="$(grep -c . "${T}/send.log")"
assert_eq "${SENDS}" "3" "末尾3行に残留 + idle → 再 Enter (send-keys 3 回)"

# 8) capture に "esc to interrupt" (busy) → 残留あっても再 Enter なし (send-keys 2 回)。
#    ユーザー割り込み中に空 Enter を撃ち込まない (pane_is_idle 再確認)。
T="$(mktemp -d)"
run_inject "${T}" "言い直してから作業を継続せよ\ngenerating… esc to interrupt" 0 0 5 >/dev/null
SENDS="$(grep -c . "${T}/send.log")"
assert_eq "${SENDS}" "2" "busy (esc to interrupt) → 残留あっても再 Enter なし (send-keys 2 回)"

rm -rf "${TMOCK}" "${T}"
report
