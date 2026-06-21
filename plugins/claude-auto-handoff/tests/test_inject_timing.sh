#!/usr/bin/env bash
# test_inject_timing.sh — Part B: inject() の継続プロンプト自動送信の堅牢化。
# (a) residual_in_tail 純関数 (b) 残留が続く間 最大 RESUME_REENTER_MAX まで再 Enter (cap)
# (c) 残留が消えたら途中で停止 (break-on-gone) (d) 残留無しは即停止
# (e) /clear リロード待ち poll が busy の間待機し idle で継続プロンプトを送る。
# capture-pane は CAPSEQ ファイルの行を 1 呼び出しずつ返すカウンタモックで制御する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"
MARK="言い直してから作業を継続せよ"

# --- (a) residual_in_tail 純関数 -------------------------------------------------
. "${DAEMON}" --source-only
assert_eq "$(residual_in_tail "a
b
app ❯ ${MARK}" && echo Y || echo N)" "Y" "末尾3行に残留 → Y"
assert_eq "$(residual_in_tail "${MARK}
l2
l3
l4" && echo Y || echo N)" "N" "末尾3行の外 (履歴) のみ → N"
assert_eq "$(residual_in_tail "app ❯ ready" && echo Y || echo N)" "N" "残留無し → N"
assert_eq "$(residual_in_tail "" && echo Y || echo N)" "N" "空 capture → N"

# --- カウンタモック (capture-pane が CAPSEQ を 1 行/呼び出しで返す) ---------------
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

# run_inject_seq <home> <max> <maxw> <delay>  (CAPSEQ は呼び出し側が ${HOME_DIR}/capseq に用意)
run_inject_seq() {
    local home="$1" max="$2" maxw="$3" delay="$4"
    : > "${home}/send.log"; : > "${home}/sleep.log"; : > "${home}/cnt"
    PATH="${TMOCK}:${PATH}" \
        SEND_LOG="${home}/send.log" SLEEP_LOG="${home}/sleep.log" \
        CNT="${home}/cnt" CAPSEQ="${home}/capseq" \
        MAXR="${max}" MAXW="${maxw}" DELAY="${delay}" bash -c '
            . "'"${DAEMON}"'" --source-only
            RESUME_DELAY_SECONDS="${DELAY}"
            RESUME_MAX_WAIT_SECONDS="${MAXW}"
            RESUME_REENTER_MAX="${MAXR}"
            inject "%5" COMPACT
        '
}

# (b) 残留が続く → 最大 RESUME_REENTER_MAX 回まで再 Enter (cap)。poll は no-op (maxw=delay)。
T="$(mktemp -d)"; printf 'app ❯ %s\n' "${MARK}" > "${T}/capseq"   # 全 capture が残留+idle
run_inject_seq "${T}" 3 1 1
# send-keys = /clear + 継続プロンプト + Enter×3 = 5
assert_eq "$(grep -c . "${T}/send.log")" "5" "残留持続 → 再 Enter は RESUME_REENTER_MAX(3) で打ち切り"

# (c) 残留が途中で消える → そこで停止 (break-on-gone)。capseq: 残留×2 → ready。
T="$(mktemp -d)"; printf 'app ❯ %s\napp ❯ %s\napp ❯ ready\n' "${MARK}" "${MARK}" > "${T}/capseq"
run_inject_seq "${T}" 5 1 1
# iter1: cap=残留, idle-check=残留 → Enter ; iter2: cap=ready → break。Enter×1。
assert_eq "$(grep -c . "${T}/send.log")" "3" "残留消失で停止 (Enter×1、max 未到達)"

# (d) 残留無し → 再 Enter ゼロ (即停止)。
T="$(mktemp -d)"; printf 'app ❯ ready\n' > "${T}/capseq"
run_inject_seq "${T}" 3 1 1
assert_eq "$(grep -c . "${T}/send.log")" "2" "残留無し → 再 Enter ゼロ (/clear + 継続プロンプトのみ)"

# (e) poll-for-ready: busy×2 → idle で継続プロンプト送出。maxw>delay で poll が回る。
T="$(mktemp -d)"
printf 'generating… esc to interrupt\ngenerating… esc to interrupt\napp ❯ ready\n' > "${T}/capseq"
run_inject_seq "${T}" 1 10 1
# busy の間 poll が sleep し、idle 後に継続プロンプトを送る (send-keys に MARK が乗る)
assert_contains "$(cat "${T}/send.log")" "${MARK}" "poll が idle 待ち後に継続プロンプトを送出"
# poll で最低 2 回 (busy×2) の sleep が発生している
assert_eq "$([ "$(grep -c '^1$' "${T}/sleep.log")" -ge 2 ] && echo Y || echo N)" "Y" "busy の間 poll が待機 (sleep≥2)"

rm -rf "${TMOCK}" "${T}"
report
