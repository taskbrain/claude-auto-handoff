#!/usr/bin/env bash
# test_inject_timing.sh — inject() の圧縮後タイミング制御。
# (a) 圧縮リロード待ちの poll: 入力欄準備 (pane idle) を待ってから継続プロンプトを送る。
#     pane が busy (esc to interrupt) の間 poll が sleep し、idle になってからテキストを送出する。
# (b) settle: テキスト送出と最初の単独 Enter の間に RESUME_SETTLE_SECONDS の待機を入れる
#     (多バイト貼り付けの着地前に Enter を撃って partial-submit するのを防ぐ)。
# capture-pane は CAPSEQ ファイルの行を 1 呼び出しずつ返すカウンタモックで poll 遷移を制御する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"
MARK="言い直してから作業を継続せよ"

# カウンタモック: capture-pane が CAPSEQ を 1 行/呼び出しで返す (poll の busy→idle 遷移を再現)。
# send-keys は SEND_LOG に、sleep は SLEEP_LOG に記録 (実待機しない)。
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  send-keys) shift; printf '%s\n' "$*" >> "${SEND_LOG}";;
  capture-pane)
    n=$(cat "${CNT}" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "${n}" > "${CNT}"
    line="$(sed -n "${n}p" "${CAPSEQ}" 2>/dev/null)"
    [ -z "${line}" ] && line="$(tail -1 "${CAPSEQ}" 2>/dev/null)"
    printf '%s\n' "${line}";;
esac
M
chmod +x "${TMOCK}/tmux"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "${SLEEP_LOG}"\n' > "${TMOCK}/sleep"
chmod +x "${TMOCK}/sleep"

run_inject_seq() {  # <home> <reenter_max> <maxw> <delay> <settle>
    local home="$1"
    : > "${home}/send.log"; : > "${home}/sleep.log"; : > "${home}/cnt"
    PATH="${TMOCK}:${PATH}" \
        SEND_LOG="${home}/send.log" SLEEP_LOG="${home}/sleep.log" \
        CNT="${home}/cnt" CAPSEQ="${home}/capseq" \
        MAXR="$2" MAXW="$3" DELAY="$4" SETTLE="$5" bash -c '
            . "'"${DAEMON}"'" --source-only
            RESUME_DELAY_SECONDS="${DELAY}"
            RESUME_MAX_WAIT_SECONDS="${MAXW}"
            RESUME_SETTLE_SECONDS="${SETTLE}"
            RESUME_SUBMIT_INTERVAL=1
            RESUME_REENTER_MAX="${MAXR}"
            inject "%5" COMPACT
        '
}

# (a) poll-for-ready: busy×2 → idle。maxw>delay で poll が回る。idle 後に継続プロンプト本文を送る。
#     capseq の前半 (poll 用) は busy、idle になってから本文送出 → 残り capseq は loop 用に ❯ idle。
T="$(mktemp -d)"
printf 'generating… esc to interrupt\ngenerating… esc to interrupt\napp ❯ idle\napp ❯ idle\n' > "${T}/capseq"
run_inject_seq "${T}" 0 10 1 0
assert_contains "$(cat "${T}/send.log")" "${MARK}" "poll が idle 待ち後に継続プロンプト本文を送出"
# busy の間 poll が待機 (RESUME_DELAY=1 の初回 + busy×2 で 1 秒待機が 3 回以上)
assert_eq "$([ "$(grep -c '^1$' "${T}/sleep.log")" -ge 2 ] && echo Y || echo N)" "Y" "busy の間 poll が待機 (sleep≥2)"

# (b) settle: テキスト送出後・最初の Enter 前に RESUME_SETTLE_SECONDS=4 の待機が入る。
T="$(mktemp -d)"
printf 'app ❯ idle\n' > "${T}/capseq"   # poll 即 idle (リロード待ち無し)
run_inject_seq "${T}" 0 0 0 4
assert_contains "$(cat "${T}/sleep.log")" "4" "テキスト送出後に settle (RESUME_SETTLE_SECONDS=4) が入る"

# (c) 送出順: /compact Enter → 本文(テキストのみ) → 単独 Enter。本文行に Enter を束ねない。
T="$(mktemp -d)"
printf 'app ❯ idle\n' > "${T}/capseq"
run_inject_seq "${T}" 0 0 0 0
assert_eq "$(sed -n '1p' "${T}/send.log")" "-t %5 /compact Enter" "1 行目 = /compact Enter"
assert_eq "$(sed -n '2p' "${T}/send.log" | grep -cE ' Enter$')" "0" "2 行目 (本文) は Enter を束ねない"
assert_eq "$(sed -n '3p' "${T}/send.log")" "-t %5 Enter" "3 行目 = 単独 Enter"

rm -rf "${TMOCK}" "${T}"
report
