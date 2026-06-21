#!/usr/bin/env bash
# test_daemon_inject.sh — inject() の継続プロンプト自動送信 (Part B 修正)。
# 根因 (使い捨て tmux + claude REPL で実機再現): 長い多バイトの継続プロンプト + Enter を『同一
# send-keys』で送ると、REPL が連続バーストを bracketed-paste と解釈し末尾 Enter を貼り付け内の改行
# として吸収 → テキストだけ入力欄に残り未送信 (ユーザー実報告)。さらに旧 residual 検出 (tail-3 +
# 連続 grep -qF) は入力欄のワードラップで分断され再 Enter が永久に発火しなかった。
# 修正: ① テキストと Enter を分離送出 (テキストのみ → settle → 単独 Enter) ② 入力欄 (───罫線間) に
# 継続プロンプトが残る間 (continuation_pending) 追加 Enter を撃つ。残留消失/busy/capture 不能で停止。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"
MARK="言い直してから作業を継続せよ"

# ============================================================================
# (A) 純関数: input_box_region / continuation_pending
#     実機 capture の構造 (入力欄を ─── 罫線で挟みフッター直上に描画) を合成で再現。
# ============================================================================
. "${DAEMON}" --source-only

# input_box_region: 最後の 2 本の罫線の間 (= 入力欄) を返す
BOX="$(input_box_region "history hi
─────────────
❯ wrapped line one
  ${MARK}
─────────────
👤 footer")"
assert_contains "${BOX}" "${MARK}" "input_box_region が罫線間の入力欄を抽出"
assert_eq "$(printf '%s' "${BOX}" | grep -cF '👤')" "0" "input_box_region はフッター (罫線外) を含めない"
assert_eq "$(input_box_region "罫線なしの平文")" "" "罫線 2 本未満 → 入力欄を特定できず空"

# continuation_pending: 入力欄に居座る = 0(pending) / それ以外 = 1
# ① ワードラップで途中に改行+インデント空白が入っても whitespace 正規化で検出 (旧 tail-3 の破綻克服)
assert_eq "$(continuation_pending "x
─────
❯ 直前の文脈は…状態を 3-5
  文で${MARK}。
─────
👤 f" && echo Y || echo N)" "Y" "ワードラップした入力欄の継続プロンプトを pending 検出"
# ② 送信成功で入力欄は空 '❯ '、文言は履歴 (罫線の外/上) のみ → not-pending (履歴混入を誤検出しない)
assert_eq "$(continuation_pending "❯ 直前の文脈は…${MARK}。
─────
❯
─────
👤 f" && echo Y || echo N)" "N" "送信済 (空入力欄+履歴に文言) は not-pending"
# ③ 罫線が無い capture → not-pending (入力欄特定不能で無限 Enter を避ける)
assert_eq "$(continuation_pending "app ❯ idle" && echo Y || echo N)" "N" "罫線なし → not-pending"
# ④ 空 capture → not-pending
assert_eq "$(continuation_pending "" && echo Y || echo N)" "N" "空 capture → not-pending"

# continuation_user_appended (Codex Critical): 入力欄が継続プロンプト末尾マークの後ろに更に文字を
# 持つ = ユーザー追記。マーク末尾 (句点許容) で終わる正常時は追記なし。マーク無し/特定不能は送信優先。
# ⓐ 正常 (マーク+句点で終わる) → 追記なし
assert_eq "$(continuation_user_appended "h
─────
❯ 直前の文脈は…
  文で${MARK}。
─────
👤 f" && echo Y || echo N)" "N" "入力欄がマーク末尾で終わる → 追記なし (送信可)"
# ⓑ ユーザーが末尾に追記 → 追記あり (Enter 抑止)
assert_eq "$(continuation_user_appended "h
─────
❯ 直前の文脈は…
  文で${MARK}。これは私の打ちかけメモ
─────
👤 f" && echo Y || echo N)" "Y" "マークの後ろにユーザーテキスト → 追記検出 (誤送信回避)"
# ⓒ 送信済 (空入力欄、文言は履歴) → 追記とは断定しない (送信優先側)
assert_eq "$(continuation_user_appended "❯ 直前の…${MARK}。
─────
❯
─────
👤 f" && echo Y || echo N)" "N" "送信済 (空入力欄) → 追記断定せず"
# ⓓ 入力欄特定不能 (罫線なし) → 追記断定しない (初回 Enter は送信優先 = Codex Important 3)
assert_eq "$(continuation_user_appended "app ❯ idle" && echo Y || echo N)" "N" "罫線なし → 追記断定せず (送信優先)"

# input_box_has_user_text (Codex Critical 2nd): 継続プロンプト投入『前』に入力欄が非空 (ユーザー先行
# 入力) かを byte 長で頑健検出。空入力欄/特定不能/capture 不能は『非空でない』(送信優先側)。
# ⓔ 空入力欄 (プロンプト記号のみ) → ユーザーテキスト無し
assert_eq "$(input_box_has_user_text "h
─────
❯
─────
👤 f" && echo Y || echo N)" "N" "空入力欄 (❯ のみ) → 先行入力なし (投入可)"
# ⓕ ユーザーが先に長めのテキストを打っている → 先行入力あり (投入中止)
assert_eq "$(input_box_has_user_text "h
─────
❯ ユーザーが先に打った下書き
─────
👤 f" && echo Y || echo N)" "Y" "ユーザー先行入力 → 検出 (prefix 型誤送信を回避)"
# ⓖ 入力欄特定不能 (罫線なし) → 非空と断定しない (投入優先 = 未送信回避)
assert_eq "$(input_box_has_user_text "app ❯ idle" && echo Y || echo N)" "N" "罫線なし → 先行入力断定せず (投入優先)"
# ⓗ 空 capture → 非空と断定しない
assert_eq "$(input_box_has_user_text "" && echo Y || echo N)" "N" "空 capture → 先行入力断定せず"

# continuation_box_corrupted (初回 Enter 直前の最終ガード): 入力欄が綺麗な継続プロンプトのみ『でない』
# と積極判定 = 送信すると誤送信。suffix 追記 / replace 置換 を積極検出。空/特定不能は送信優先 (return 1)。
PROMPT_BOX="h
─────
❯ 直前の文脈は…
  文で${MARK}。
─────
👤 f"
# ⓘ 綺麗な継続プロンプトのみ → 汚染なし (送信可)
assert_eq "$(continuation_box_corrupted "${PROMPT_BOX}" && echo Y || echo N)" "N" "綺麗な継続プロンプト → 汚染なし (送信可)"
# ⓙ suffix 追記 → 汚染
assert_eq "$(continuation_box_corrupted "h
─────
❯ 直前の文脈は…
  文で${MARK}。ユーザー追記
─────
👤 f" && echo Y || echo N)" "Y" "suffix 追記 → 汚染検出 (送信抑止)"
# ⓚ replace 置換 (実テキストありマーク無し) → 汚染
assert_eq "$(continuation_box_corrupted "h
─────
❯ ユーザーがプロンプトを消して打った自分のテキスト
─────
👤 f" && echo Y || echo N)" "Y" "replace 置換 (マーク無しの実テキスト) → 汚染検出 (送信抑止)"
# ⓛ 空入力欄 (テキスト未着地等) → 汚染と断定しない (送信優先・空欄 Enter は no-op)
assert_eq "$(continuation_box_corrupted "h
─────
❯
─────
👤 f" && echo Y || echo N)" "N" "空入力欄 → 汚染断定せず (送信優先)"
# ⓜ 入力欄特定不能 → 汚染と断定しない (送信優先 = Important 3)
assert_eq "$(continuation_box_corrupted "app ❯ idle" && echo Y || echo N)" "N" "罫線なし → 汚染断定せず (送信優先)"
# ⓝ [I-1 修正の核心] テキスト部分着地 (先頭マークあり・末尾マーク未到達) → 汚染としない (送信優先)。
#    replace 置換 (先頭マークも無し) と区別し、部分着地を未送信化しない。
assert_eq "$(continuation_box_corrupted "h
─────
❯ 直前の文脈は自動圧縮された。SessionStart で復元され
─────
👤 f" && echo Y || echo N)" "N" "部分着地 (先頭マークあり/末尾マーク未到達) → 汚染とせず送信 (未送信化を防ぐ)"

# continuation_box_has_head: 入力欄に継続プロンプト先頭マークが在るか (部分着地判定用)
assert_eq "$(continuation_box_has_head "h
─────
❯ 直前の文脈は自動圧縮された。SessionStart で…
─────
👤 f" && echo Y || echo N)" "Y" "先頭マークあり → has_head"
assert_eq "$(continuation_box_has_head "h
─────
❯ ユーザーの全く別のテキスト
─────
👤 f" && echo Y || echo N)" "N" "先頭マーク無し (置換) → not has_head"

# ============================================================================
# (A2) 実描画構造 fixture (code-reviewer I-1): Claude REPL は起動バナーを角丸枠 ╭───╮ で、内側に
#      列区切り ──── を、入力欄を平罫線 ───── で描く。これら複数の ─── が入力欄の『上』に在っても、
#      入力欄は常に最下部 (フッターの直上) のため『最後の 2 本の罫線』= 入力欄を正しく抽出できる
#      ことを実構造で固定する (角丸 ╭╰ と awk /───/ の整合)。実機 capture (使い捨て tmux + 実 claude)
#      で同一構造を確認済。PII を含めず両リポ共用。
REAL_PENDING="$(cat <<'SCREEN'
╭─── Claude Code v2.1.185 ──────────────────────────────────────────────────╮
│                 Welcome back user!                 │ Tips for getting     │
│                       ▐▛███▜▌                      │ ──────────────────── │
│                      ▝▜█████▛▘                     │ What's new           │
╰───────────────────────────────────────────────────────────────────────────╯

❯ Reply with exactly one word: PINGA

● Acknowledged.

─────────────────────────────────────────────────────────────────────────────
❯ 直前の文脈は自動圧縮された。SessionStart で復元されたハンドオフ
  (この上に注入されている) を唯一の信頼源として、状態を 3-5
  文で言い直してから作業を継続せよ。
─────────────────────────────────────────────────────────────────────────────
   👤 user │ [Model] 📁 work
  ⏵⏵ bypass permissions on (shift+tab to cycle)
SCREEN
)"
assert_eq "$(continuation_pending "${REAL_PENDING}" && echo Y || echo N)" "Y" "角丸バナー+内側罫線が上部に在っても入力欄(平罫線間)の継続プロンプトを pending 検出"

REAL_DONE="$(cat <<'SCREEN'
╭─── Claude Code v2.1.185 ──────────────────────────────────────────────────╮
│                 Welcome back user!                 │ ──────────────────── │
╰───────────────────────────────────────────────────────────────────────────╯

❯ 直前の文脈は自動圧縮された。SessionStart で復元されたハンドオフ
  (この上に注入されている) を唯一の信頼源として、状態を 3-5
  文で言い直してから作業を継続せよ。

● セッション状態の確認です。

─────────────────────────────────────────────────────────────────────────────
❯
─────────────────────────────────────────────────────────────────────────────
   👤 user │ [Model] 📁 work
  ⏵⏵ bypass permissions on (shift+tab to cycle)
SCREEN
)"
assert_eq "$(continuation_pending "${REAL_DONE}" && echo Y || echo N)" "N" "角丸バナー+履歴に文言が在っても送信済(空入力欄)は not-pending (履歴混入を誤検出しない)"

# ============================================================================
# (B) inject 統合: screen 遷移モック
#     send-keys: SEND_LOG に記録。単独 Enter (`-t <pane> Enter`) は ENTER_CNT を増やす。
#     capture-pane: ENTER_CNT >= SUBMIT_AFTER で「送信済 screen」、未満で「未送信 screen」を返す
#                   (= K 回目の単独 Enter で送信が通る挙動を再現)。CAPFAIL=1 で空、SENDFAIL=1 で
#                   /compact 送出のみ失敗。
# ============================================================================
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  send-keys)
    shift
    # /compact 本体の送出失敗注入 (記録前に exit → ログに残さない)
    if [ "${SENDFAIL:-0}" = 1 ] && printf '%s' "$*" | grep -qF '/compact'; then exit 1; fi
    printf '%s\n' "$*" >> "${SEND_LOG}"
    # 継続プロンプト本文 (マーク含む & 末尾 Enter 無し) の送出を記録 → 以降 capture は投入後 screen を返す
    if printf '%s' "$*" | grep -qF "${MARK_ENV}" && ! printf '%s' "$*" | grep -qE ' Enter$'; then
      : > "${TEXT_SENT}"
    fi
    # 単独 Enter (`-t <pane> Enter`) を計数
    if printf '%s' "$*" | grep -qE '^-t [^ ]+ Enter$'; then
      n=$(cat "${ENTER_CNT}" 2>/dev/null || echo 0); echo $((n+1)) > "${ENTER_CNT}"
    fi
    ;;
  capture-pane)
    [ "${CAPFAIL:-0}" = 1 ] && exit 0   # 空出力 = capture 不能
    # テキスト投入前は『投入前 screen』(既定 空入力欄)、投入後は ENTER_CNT 次第で PEND/DONE。
    if [ ! -e "${TEXT_SENT}" ]; then printf '%b' "${SCREEN_PRETEXT}"; exit 0; fi
    n=$(cat "${ENTER_CNT}" 2>/dev/null || echo 0)
    if [ "${n}" -ge "${SUBMIT_AFTER:-1}" ]; then printf '%b' "${SCREEN_SUBMITTED}"; else printf '%b' "${SCREEN_PENDING}"; fi
    ;;
esac
M
chmod +x "${TMOCK}/tmux"
printf '#!/usr/bin/env bash\n:\n' > "${TMOCK}/sleep"; chmod +x "${TMOCK}/sleep"

# 投入前 screen (空入力欄) / 未送信 screen (継続プロンプトが居座る) / 送信済 screen (空入力欄+文言は履歴)
EMPTY='hist\n─────\n❯ \n─────\n👤 footer'
PEND='hist\n─────\n❯ 直前の文脈は…\n  '"${MARK}"'。\n─────\n👤 footer'
PEND_BUSY='hist\n─────\n❯ 直前の文脈は…\n  '"${MARK}"'。\n─────\ngenerating… esc to interrupt'
DONE='❯ 直前の文脈は…'"${MARK}"'。\n─────\n❯ \n─────\n👤 footer'
# ユーザーが settle 中に入力欄へ追記した screen (継続プロンプト末尾マークの後ろに自分のテキスト)
PEND_APPENDED='hist\n─────\n❯ 直前の文脈は…\n  '"${MARK}"'。これは私の打ちかけメモ\n─────\n👤 footer'
# ユーザーが投入前に既に打っている screen (投入前 capture で検出すべき)
USERTEXT='hist\n─────\n❯ ユーザーが先に打った長めの下書きテキストです\n─────\n👤 footer'
# ユーザーが投入後 settle 中に継続プロンプトを消して自分のテキストに置換した screen (replace 型)
REPLACED='hist\n─────\n❯ ユーザーがプロンプトを消して打った置換テキスト\n─────\n👤 footer'
# テキスト部分着地 screen (先頭マークあり・末尾マーク未到達): replace と誤判定せず送信すべき (I-1)
PARTIAL='hist\n─────\n❯ 直前の文脈は自動圧縮された。SessionStart で復元され\n─────\n👤 footer'

run_inject() {  # <home> <submit_after> <reenter_max> <sendfail> <capfail> [pending_screen] [pretext_screen]
    local home="$1"
    SEND_LOG="${home}/send.log"; ENTER_CNT="${home}/enter.cnt"; : > "${SEND_LOG}"; : > "${ENTER_CNT}"
    rm -f "${home}/text_sent"
    PATH="${TMOCK}:${PATH}" SEND_LOG="${SEND_LOG}" ENTER_CNT="${ENTER_CNT}" TEXT_SENT="${home}/text_sent" \
        MARK_ENV="${MARK}" SCREEN_PRETEXT="${7:-${EMPTY}}" \
        SCREEN_PENDING="${6:-${PEND}}" SCREEN_SUBMITTED="${DONE}" \
        SUBMIT_AFTER="$2" SENDFAIL="${4:-0}" CAPFAIL="${5:-0}" REENTER="$3" bash -c '
            . "'"${DAEMON}"'" --source-only
            RESUME_DELAY_SECONDS=0; RESUME_MAX_WAIT_SECONDS=0
            RESUME_SETTLE_SECONDS=0; RESUME_SUBMIT_INTERVAL=0
            RESUME_REENTER_MAX="${REENTER}"
            inject "%5" COMPACT
        '
    return $?
}
loneenters() { grep -cE '^-t [^ ]+ Enter$' "$1/send.log"; }   # 単独 Enter の回数

# 1) テキストと Enter は分離して送る (核心の回帰ガード)。継続プロンプト行に末尾 Enter が無いこと。
T="$(mktemp -d)"; run_inject "${T}" 1 5 0 0 >/dev/null
PROMPTLINE="$(grep -F "${MARK}" "${T}/send.log" | head -1)"
assert_nonempty "${PROMPTLINE}" "継続プロンプトのテキストが送出される"
assert_eq "$(printf '%s' "${PROMPTLINE}" | grep -cE ' Enter$' )" "0" "継続プロンプトは Enter を束ねず単体送出 (paste 吸収回避)"
assert_eq "$(grep -cE '^-t [^ ]+ Enter$' "${T}/send.log")" "1" "テキストとは別に単独 Enter を送出"

# 2) 1 回目の単独 Enter で送信成功 → 追加 Enter なし (単独 Enter = 1 回)。
T="$(mktemp -d)"; run_inject "${T}" 1 5 0 0 >/dev/null
assert_eq "$(loneenters "${T}")" "1" "1 回目の Enter で送信成功 → 単独 Enter は 1 回 (余剰なし)"

# 3) 1 回目が取りこぼされ 2 回目で送信成功 → 単独 Enter は 2 回 (取りこぼしガードが効く)。
T="$(mktemp -d)"; run_inject "${T}" 2 5 0 0 >/dev/null
assert_eq "$(loneenters "${T}")" "2" "1 回目取りこぼし → 2 回目で確定 (単独 Enter 2 回)"

# 4) 永久に残留 (送信が通らない) → 単独 Enter は 1(初回)+RESUME_REENTER_MAX で打ち切り (無限ループ防止)。
T="$(mktemp -d)"; run_inject "${T}" 999 3 0 0 >/dev/null
assert_eq "$(loneenters "${T}")" "4" "残留持続 → 1+REENTER_MAX(3)=4 で打ち切り (bounded)"

# 5) busy (esc to interrupt) かつ残留 → 追加 Enter を撃たない (turn 中の誤 Enter 防止)。初回 Enter のみ。
T="$(mktemp -d)"; run_inject "${T}" 999 5 0 0 "${PEND_BUSY}" >/dev/null
assert_eq "$(loneenters "${T}")" "1" "busy 中は追加 Enter なし (初回 Enter のみ)"

# 6) capture 不能 → 初回 Enter は送出済 (分離修正で核心バグは解消)、ループは即停止。inject は成功。
T="$(mktemp -d)"; run_inject "${T}" 999 5 0 1 >/dev/null; RC=$?
assert_eq "${RC}" "0" "capture 不能でも inject 成功 (best-effort)"
assert_eq "$(loneenters "${T}")" "1" "capture 不能 → 初回 Enter のみ (分離送出で送信は起動済)"

# 7) /compact 本体送出失敗 → return 1 (caller のデッドロック防止)。
T="$(mktemp -d)"; run_inject "${T}" 1 5 1 0 >/dev/null; RC=$?
assert_eq "${RC}" "1" "/compact 送出失敗 → return 1"

# 8) /compact + 継続プロンプトの送出順序 (圧縮コマンド → テキスト → Enter)。
T="$(mktemp -d)"; run_inject "${T}" 1 5 0 0 >/dev/null
assert_eq "$(sed -n '1p' "${T}/send.log")" "-t %5 /compact Enter" "1 行目 = /compact Enter"
assert_eq "$(sed -n '2p' "${T}/send.log" | grep -cF "${MARK}")" "1" "2 行目 = 継続プロンプト本文"
assert_eq "$(sed -n '3p' "${T}/send.log")" "-t %5 Enter" "3 行目 = 単独 Enter"

# 9) [Codex Critical / suffix] ユーザーが settle 中に追記 → 初回 Enter を抑止 (打ちかけ誤送信を防ぐ)。
#    入力欄が PEND_APPENDED (マークの後にユーザーテキスト) の間、単独 Enter は 0 回。
T="$(mktemp -d)"; run_inject "${T}" 999 5 0 0 "${PEND_APPENDED}" >/dev/null
assert_eq "$(loneenters "${T}")" "0" "ユーザー追記(suffix)検出 → 初回 Enter 抑止 (単独 Enter 0 回・誤送信なし)"
# テキスト自体は送出されている (入力欄投入は行うが Enter は撃たない)。
assert_eq "$(grep -cF "${MARK}" "${T}/send.log")" "1" "テキスト投入は行う (Enter のみ抑止)"

# 10) [Codex Critical / prefix] ユーザーが投入『前』に既に打っている → 継続プロンプトを重ねず投入中止。
#     投入前 screen = USERTEXT。テキスト投入も Enter も 0 (prefix 型誤送信を回避)。
T="$(mktemp -d)"; run_inject "${T}" 1 5 0 0 "${PEND}" "${USERTEXT}" >/dev/null
assert_eq "$(grep -cF "${MARK}" "${T}/send.log")" "0" "ユーザー先行入力 → 継続プロンプトを投入しない (重ね送信回避)"
assert_eq "$(loneenters "${T}")" "0" "ユーザー先行入力 → 単独 Enter 0 回 (誤送信なし)"
# /compact 自体は送出される (圧縮は行う; 誤送信回避は継続プロンプト投入のみ)。
assert_eq "$(grep -cF '/compact' "${T}/send.log")" "1" "/compact は送出 (圧縮は実行)"

# 11) [replace] 投入後 settle 中にユーザーが継続プロンプトを消して自分のテキストに置換 → 初回 Enter 抑止。
#     投入後 screen = REPLACED (マーク無しの実テキスト)。テキスト投入は行うが単独 Enter は 0 回。
T="$(mktemp -d)"; run_inject "${T}" 999 5 0 0 "${REPLACED}" >/dev/null
assert_eq "$(loneenters "${T}")" "0" "replace 置換検出 → 初回 Enter 抑止 (ユーザーテキストを誤送信しない)"
assert_eq "$(grep -cF "${MARK}" "${T}/send.log")" "1" "テキスト投入は行う (置換は投入後・Enter のみ抑止)"

# 12) [I-1 修正] テキスト部分着地 (先頭マークあり・末尾マーク未到達) → replace と誤判定せず初回 Enter を送る。
#     投入後 screen = PARTIAL。未送信化を防ぐため初回 Enter は必ず送出 (単独 Enter ≥ 1)。
T="$(mktemp -d)"; run_inject "${T}" 999 5 0 0 "${PARTIAL}" >/dev/null
assert_eq "$(loneenters "${T}")" "1" "部分着地 → 初回 Enter を送出 (replace 誤判定で未送信化しない)"

rm -rf "${TMOCK}" "${T}"
report
