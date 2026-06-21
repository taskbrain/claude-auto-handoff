#!/usr/bin/env bash
# cc-compaction-daemon.sh — per-session state を監視し tmux に圧縮を注入する。
# systemd --user 常駐 daemon。kill switch: CC_HANDOFF_DAEMON_ENABLED
# / ~/.claude/auto-compaction/DISABLED。`--source-only` で関数だけ読み込む (テスト用)。
set -u
DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck disable=SC1091
. "${DAEMON_DIR}/../hooks/_ctx_common.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "${DAEMON_DIR}/_cc_pane_resolve.sh" 2>/dev/null || true

# state_is_fresh <file> → 0(fresh) / 1(stale)。state の mtime が STATE_FRESH_SECONDS 以内なら
# fresh。live セッションは statusLine が頻繁に state を更新するため、古い state は終了済/放棄
# セッションの残骸 (旧ロジックの stale band 固着含む) とみなし daemon は一切触らない。
state_is_fresh() {
    [ -n "$(find "$1" -newermt "-${STATE_FRESH_SECONDS:-180} seconds" 2>/dev/null)" ]
}

# 400 orphan 署名検出: transcript 末尾付近に isApiErrorMessage + "API Error: 400"
has_400_signature() {
    local tr="$1"; [ -f "${tr}" ] || return 1
    tail -n 40 "${tr}" 2>/dev/null | grep -qF '"isApiErrorMessage":true' \
        && tail -n 40 "${tr}" 2>/dev/null | grep -qF 'API Error: 400'
}

# decide_action <band> <prepared:0|1> <transcript> → COMPACT|NONE
# Stage2 の圧縮コマンドは ${COMPACTION_COMMAND} (既定 /compact)。source=compact が曖昧さゼロの
# 復元信号で native 要約が安全網になる。1M で /compact が不発の場合のみ COMPACTION_COMMAND=/clear に
# フォールバック (復元は compaction-resume でフラグ非依存化済みのため /clear 経路でも成立)。
# 戻り値 COMPACT は「圧縮を実行する」の意 (送出コマンドは COMPACTION_COMMAND で決まる)。
#  - 400 orphan 署名 → COMPACT (band 不問の復旧)
#  - critical 帯 → COMPACT (prepared 不問の安全弁。resume は機械版 .md に fallback)
#  - compact 帯 ∧ prepared → COMPACT (本線。モデル自筆 model.md が揃ってから圧縮)
#  - それ以外 (idle/prepare/compact-未prepared) → NONE
decide_action() {
    local band="$1" prepared="${2:-0}" tr="${3:-}"
    if has_400_signature "${tr}"; then echo "COMPACT"; return; fi
    case "${band}" in
        critical) echo "COMPACT" ;;
        compact)  [ "${prepared}" = "1" ] && echo "COMPACT" || echo "NONE" ;;
        *)        echo "NONE" ;;
    esac
}

# 継続プロンプト (kick)。residual 検出と同一文字列を参照するため変数化。
CONTINUATION_PROMPT="直前の文脈は自動圧縮された。SessionStart で復元されたハンドオフ (この上に注入されている) を唯一の信頼源として、状態を 3-5 文で言い直してから作業を継続せよ。"
# 入力欄に継続プロンプトが居座っているか (= 未送信) を判定する部分文字列 (継続プロンプト末尾の一部)。
CONTINUATION_RESIDUAL_MARK="言い直してから作業を継続せよ"
# 継続プロンプト先頭の部分文字列。テキスト部分着地 (本文は着地済みだが末尾マーク未レンダリング) を
# 「ユーザー置換」と誤判定して未送信化するのを防ぐため、入力欄に継続プロンプトが (部分的にでも) 在る
# ことを先頭マークで検出する (code-reviewer I-1)。プロンプト冒頭で最初に描画される。
CONTINUATION_HEAD_MARK="直前の文脈は"

# input_box_region <capture_text> → stdout: 最後の 2 本の水平罫線 (───) の間の行 (= 入力ボックス)。
# Claude REPL は入力欄を ─── 罫線で上下に挟んでステータスフッターの直上に描画する。罫線が 2 本
# 未満なら入力欄を特定できないので何も出さない (caller は「未送信でない」と扱い無限 Enter を避ける)。
input_box_region() {
    awk '
        { lines[NR]=$0 }
        /───/ { r[++n]=NR }
        END {
            if (n < 2) exit 0
            lo=r[n-1]; hi=r[n]
            for (i=lo+1; i<hi; i++) print lines[i]
        }
    ' <<<"${1:-}"
}

# continuation_pending <capture_text> → 0(継続プロンプトが入力欄に居座り未送信 = Enter 必要) / 1。
# 純関数 (capture 文字列のみに依存)。堅牢性の核心:
#  ① 入力欄領域 (input_box_region) に限定 → 送信成功後に scrollback 履歴へ echo される同一文言を
#     「未送信」と誤認しない (whole-capture grep の誤検出を排除)。
#  ② 入力欄テキストとマークを whitespace 正規化してから部分一致 → REPL のワードラップ (長い多バイト
#     プロンプトの途中に改行/インデント空白を挿入) がマーク文字列を分断しても確実に一致する
#     (旧 tail-3 + 連続 grep -qF はワードラップで破綻し再 Enter が永久に発火しなかった = 実報告バグ)。
continuation_pending() {
    local box; box="$(input_box_region "${1:-}")"
    [ -n "${box}" ] || return 1
    local nbox nmark
    nbox="$(printf '%s' "${box}" | tr -d '[:space:]')"
    nmark="$(printf '%s' "${CONTINUATION_RESIDUAL_MARK}" | tr -d '[:space:]')"
    [ -n "${nmark}" ] || return 1
    case "${nbox}" in *"${nmark}"*) return 0 ;; *) return 1 ;; esac
}

# continuation_user_appended <capture_text> → 0(入力欄にユーザーが継続プロンプトの後ろへ追記した
#   と『積極的に』判定できた) / 1(それ以外)。
# 目的 (Codex Critical): 圧縮直後の settle / 追加 Enter 間隔の窓でユーザーが入力欄へ自分のテキストを
#   打ち始めた場合、Enter を撃つと『継続プロンプト + ユーザーの打ちかけ』を誤送信する。これを防ぐ。
# 判定: 入力欄の正規化テキストが継続プロンプト末尾マーク (= プロンプトの最終文) で終わらず、マークの
#   後ろにさらに文字が続く → ユーザー追記。マーク末尾 (句点許容) で終わる正常時は追記なし。マークが
#   無い (送信済/空/入力欄特定不能/capture 不能) ときは『追記』と断定しない (return 1) → caller は
#   送信を優先する (核心バグ=未送信の解消を最優先, best-effort)。Claude REPL は入力テキスト末尾に
#   カーソル文字を描画しないため、末尾一致判定は実機で安定する (実機 capture で確認済)。
continuation_user_appended() {
    local box; box="$(input_box_region "${1:-}")"
    [ -n "${box}" ] || return 1
    local nbox nmark
    nbox="$(printf '%s' "${box}" | tr -d '[:space:]')"
    nmark="$(printf '%s' "${CONTINUATION_RESIDUAL_MARK}" | tr -d '[:space:]')"
    [ -n "${nmark}" ] || return 1
    case "${nbox}" in
        *"${nmark}")   return 1 ;;   # マーク (プロンプト末尾) で終わる → 追記なし
        *"${nmark}。")  return 1 ;;   # マーク + 句点で終わる → 追記なし
        *"${nmark}"?*) return 0 ;;   # マークの後にさらに文字 → ユーザー追記 (誤送信回避)
        *)             return 1 ;;   # マーク無し → 追記とは断定しない (送信優先)
    esac
}

# input_box_has_user_text <capture_text> → 0(継続プロンプト投入『前』に入力欄が既に非空 = ユーザーが
#   先行入力している) / 1(空 or 特定不能 or capture 不能)。
# 目的 (Codex Critical 2): 圧縮直後にユーザーが入力欄へ打ち始めてから継続プロンプトを重ねて送ると
#   『ユーザーの打ちかけ + 継続プロンプト』になり末尾はプロンプトのため continuation_user_appended では
#   検出できない (prefix 型誤送信)。投入前に空入力欄を確認することで prefix 型を防ぐ。
# 判定: 入力欄正規化テキストの byte 長がプロンプト記号 (❯ ≈3byte) + 余裕 (既定 8) を超える → ユーザー
#   テキストあり。byte 長基準のためプロンプト記号やカーソル文字の版差に頑健で、空入力欄を「ユーザー
#   テキスト」と誤判定しない (誤判定すると投入を中止し未送信になるため送信側に倒す)。入力欄特定不能 /
#   capture 不能では非空と断定しない (return 1 → 投入を優先, best-effort)。
# ★閾値トレードオフ (意図的): 閾値を下げれば短い先行入力 ("ok" 等) も検出できるが、グリフ + カーソル
#   文字だけの空入力欄を「非空」と誤検出して投入を中止し『未送信』を招くリスクが増える。ユーザー原則
#   「未送信が最悪・誤送信は次善」に従い、未送信を避ける側 (高めの閾値) に倒す。結果、長い先行入力 (実害
#   のある composing 中メッセージ) は検出し、ごく短い先行入力 (無害な短トークンが復元指示の前に付くだけ)
#   は許容する。
input_box_has_user_text() {
    local box; box="$(input_box_region "${1:-}")"
    [ -n "${box}" ] || return 1
    local nb
    nb=$(printf '%s' "${box}" | tr -d '[:space:]' | wc -c)
    [ "${nb}" -gt "${INPUT_BOX_EMPTY_MAX_BYTES:-8}" ]
}

# continuation_box_has_head <capture_text> → 0(入力欄に継続プロンプト先頭マークが在る = 我々の
#   プロンプトが部分的にでも着地している) / 1(無い)。部分着地を「ユーザー置換」と誤判定しないため。
continuation_box_has_head() {
    local box; box="$(input_box_region "${1:-}")"
    [ -n "${box}" ] || return 1
    local nbox nhead
    nbox="$(printf '%s' "${box}" | tr -d '[:space:]')"
    nhead="$(printf '%s' "${CONTINUATION_HEAD_MARK}" | tr -d '[:space:]')"
    [ -n "${nhead}" ] || return 1
    case "${nbox}" in *"${nhead}"*) return 0 ;; *) return 1 ;; esac
}

# continuation_box_corrupted <capture_text> → 0(入力欄が『綺麗な継続プロンプトのみ』でないと積極的に
#   判定できた = 送信すると誤送信になる) / 1(綺麗な継続プロンプト or 空 or 特定不能 or 部分着地 = 送信
#   してよい)。初回 Enter を撃つ直前の最終ガード。誤送信の 2 形を積極検出する:
#   - suffix: 継続プロンプト末尾の後ろにユーザー追記 (continuation_user_appended)。
#   - replace: 入力欄に実質的なテキストがあるのに継続プロンプトの末尾マーク『も先頭マークも』含まない =
#     ユーザーが投入後にプロンプトを消して自分のテキストに置換した。先頭マークが在れば部分着地 (我々の
#     テキスト) であり置換でない → 汚染としない (部分着地を置換と誤判定して未送信化するのを防ぐ,
#     code-reviewer I-1。本修正は「誤送信回避より未送信回避を優先」のユーザー原則に従う)。
# 空入力欄 (テキスト未着地) / 入力欄特定不能 / capture 不能 は『汚染』と断定しない (return 1) → 送信を
#   優先する (核心バグ=未送信の解消を最優先, best-effort。空入力欄への単独 Enter は no-op で無害)。
continuation_box_corrupted() {
    local cap="${1:-}"
    continuation_user_appended "${cap}" && return 0   # suffix 追記
    # replace 置換: 実テキストあり ∧ 末尾マーク無し ∧ 先頭マークも無し (部分着地でない) → ユーザー置換
    if input_box_has_user_text "${cap}" \
        && ! continuation_pending "${cap}" \
        && ! continuation_box_has_head "${cap}"; then
        return 0
    fi
    return 1
}

# inject <pane> <action> → 0(送出成功) / 1(失敗)。圧縮コマンド (${COMPACTION_COMMAND}, 既定 /compact)
# 送出後に「ハンドオフから継続せよ」の kick を送る (SessionStart(source=compact|clear) が
# compaction-resume で handoff を先頭注入し、この kick が最初の turn を起動する)。
# ★圧縮コマンド本体の send-keys 成否を返す: 失敗を握り潰すと caller が compacted を誤って立て
#   resume 待ちデッドロックになる (I2)。kick は best-effort。
# ★大 context の圧縮リロード/要約は入力欄準備に時間がかかる: 待機を RESUME_DELAY_SECONDS で延長し、
#   入力欄準備 (pane idle) を poll してから継続プロンプトを送る。
# ★継続プロンプトの自動送信 (Part B 修正の核心): 長い多バイトのプロンプト + Enter を『同一 send-keys』で
#   送ると、REPL が連続バーストを bracketed-paste と解釈し末尾 Enter を貼り付け内の改行として吸収する
#   → テキストだけ入力欄に残り未送信 (ユーザー実報告 / 使い捨て tmux で実機再現)。対策は 2 段:
#     ① テキストと Enter を分離して送る (テキストのみ → settle → 単独 Enter)。単独 Enter は貼り付けの
#        一部でないため確実に送信を起動する。
#     ② 単発 Enter の取りこぼしに備え、入力欄 (───罫線間) に継続プロンプトが残る間 (continuation_pending)
#        最大 RESUME_REENTER_MAX 回まで追加 Enter を撃つ。残留消失 (= 送信成功で入力欄クリア) / busy
#        (= 送信成功で turn 進行中) / capture 不能 で停止。空入力欄への単独 Enter は no-op のため余剰
#        Enter は無害。
# submit_continuation_prompt <pane> → 継続プロンプトを入力欄へ投入し『送信まで』確定する。
#   ① テキストのみ送出 (Enter を束ねない)。長い多バイトのテキスト + Enter を同一 send-keys で送ると
#      REPL が bracketed-paste と解釈し末尾 Enter を貼り付け内の改行として吸収する → 未送信のまま
#      入力欄に残る (実機再現)。テキストと Enter を分離し、単独 Enter (貼り付けの一部でない) で送信を起動。
#   ① 投入前ガード (Codex Critical 2): 入力欄に既にユーザーのテキストがある (圧縮直後にユーザーが
#      打ち始めた) 場合、その上に継続プロンプトを重ねて投入 → Enter すると『ユーザーの打ちかけ +
#      継続プロンプト』を誤送信する (prefix 型)。空入力欄を確認できたときのみ投入する。capture 不能 /
#      入力欄特定不能では投入を優先 (best-effort)。
#   ② settle 後に最初の単独 Enter を送る。ただし settle 中にユーザーが入力欄へ追記したと『積極的に』
#      判定できた (continuation_user_appended) ときだけ抑止する (suffix 型誤送信を防ぐ, Codex Critical)。
#      capture 不能 / 入力欄特定不能では送信を優先する (核心バグ=未送信の解消が最優先, best-effort。
#      入力欄が罫線2本未満で特定できなくても初回 Enter は必ず送られる = Codex Important 3 を満たす)。
#   ③ 取りこぼしガード: 入力欄 (───罫線間) に継続プロンプトが残る間 (continuation_pending) 追加 Enter を
#      最大 RESUME_REENTER_MAX 回撃つ。残留消失 (= 送信成功で入力欄クリア) / ユーザー追記検出 / busy
#      (= 送信成功で turn 進行中) / capture 不能 で停止。空入力欄への単独 Enter は no-op のため余剰
#      Enter は無害。
submit_continuation_prompt() {
    local pane="$1" cap
    # ① 投入前ガード: 入力欄にユーザーの先行入力があれば重ね投入しない (prefix 型誤送信を防ぐ)。
    cap="$(tmux capture-pane -t "${pane}" -p 2>/dev/null || true)"
    if input_box_has_user_text "${cap}"; then return 0; fi
    tmux send-keys -t "${pane}" "${CONTINUATION_PROMPT}" 2>/dev/null || true
    sleep "${RESUME_SETTLE_SECONDS:-2}"
    # ② 初回 Enter 前の汚染ガード (suffix 追記 / replace 置換を積極検出した時のみ抑止 → 空入力欄/
    #    特定不能/capture 不能では送信優先 = 核心バグ=未送信の解消を最優先, Important 3 を満たす)。
    cap="$(tmux capture-pane -t "${pane}" -p 2>/dev/null || true)"
    if continuation_box_corrupted "${cap}"; then return 0; fi
    # 最初の送信 Enter (確実に 1 回; 分離 Enter で核心バグ=未送信を解消)。
    tmux send-keys -t "${pane}" Enter 2>/dev/null || true
    local i=0
    while [ "${i}" -lt "${RESUME_REENTER_MAX:-5}" ]; do
        sleep "${RESUME_SUBMIT_INTERVAL:-2}"
        cap="$(tmux capture-pane -t "${pane}" -p 2>/dev/null || true)"
        [ -n "${cap}" ] || break                  # capture 不能 → best-effort 終了 (Enter は既に送出済)
        continuation_pending "${cap}" || break     # 入力欄クリア = 送信成功 → 停止
        continuation_user_appended "${cap}" && break  # ユーザー追記検出 → 誤送信回避で停止
        pane_is_idle "${pane}" || break             # busy = 送信成功で turn 進行中 → 停止
        tmux send-keys -t "${pane}" Enter 2>/dev/null || true
        i=$((i+1))
    done
}

inject() {
    local pane="$1" action="$2"
    [ -n "${pane}" ] || return 1
    case "${action}" in
        COMPACT)
            # ★COMPACTION_COMMAND の値検証: ライブ pane に不正文字列 (typo/誤設定) を送ると
            #   prompt として解釈され誤作動しうる。許容は /compact|/clear のみ、それ以外は /compact に矯正。
            local cmd="${COMPACTION_COMMAND:-/compact}"
            case "${cmd}" in
                /compact|/clear) ;;
                *) printf '[cc-compaction-daemon] 無効な COMPACTION_COMMAND=[%s] → /compact に矯正\n' "${cmd}" >&2; cmd="/compact" ;;
            esac
            tmux send-keys -t "${pane}" "${cmd}" Enter 2>/dev/null || return 1
            # ★圧縮リロード完了待ち: 大 context のリロード/要約は入力欄準備に時間がかかる。
            #   /compact は LLM 要約のため /clear より長め。最低 RESUME_DELAY_SECONDS 待ち、その後
            #   pane idle (= 入力欄準備完了) を RESUME_MAX_WAIT_SECONDS まで poll してから継続プロンプトを
            #   送る。固定 sleep だけでは大 context で早すぎ、テキストが入力欄準備前に届き取りこぼす。
            #   timeout でも degrade で送る (送らないより送る)。
            sleep "${RESUME_DELAY_SECONDS:-12}"
            local waited="${RESUME_DELAY_SECONDS:-12}" maxw="${RESUME_MAX_WAIT_SECONDS:-90}"
            while [ "${waited}" -lt "${maxw}" ]; do
                pane_is_idle "${pane}" && break
                sleep 1; waited=$((waited+1))
            done
            submit_continuation_prompt "${pane}"
            return 0 ;;
    esac
    return 1
}

# 1 周期: 全 state を走査し判定 → 注入。
# ゲート: ¬compacted ∧ action≠NONE ∧ cooldown 経過 ∧ pane 解決 ∧ pane 現住人一致 ∧ pane idle。
# 注入後 compacted フラグを立て、SessionStart(clear) の resume が reset するまで再発火しない。
tick() {
    local sdir; sdir="$(ctx_state_dir)"
    [ -d "${sdir}" ] || return 0
    local f sess band cwd pane tr now last mark prepared action owner
    for f in "${sdir}"/*.json; do
        [ -f "${f}" ] || continue
        # ★鮮度ゲート: 古い state (終了済/放棄セッションの残骸) は触らない (stale 大量 /clear 防止)
        state_is_fresh "${f}" || continue
        IFS=$'\t' read -r sess band cwd pane <<<"$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['session_id'],d['band'],d['cwd'],d.get('pane',''),sep='\t')" "${f}" 2>/dev/null)"
        [ -n "${sess}" ] || continue
        # 既に圧縮送出済み (resume 待ち) → 何もしない。ただし inflight marker が COMPACTED_TTL_SECONDS を
        # 超えて残存し ∧ band がまだ idle に落ちていない (= 圧縮が効いていない) なら、SessionStart 不達
        # 等で圧縮が空振りしたとみなしフラグを clear して再評価する。送出後フラグを立てる設計上、
        # SessionStart(compact|clear) の resume が来ないと恒久 skip = 以降一切自動圧縮されない沈黙劣化に
        # なるのを防ぐ (デュアルレビュー must-fix)。圧縮成功時は新セッションの statusLine が band=idle を
        # 書くため band!=idle が空振りの判別子になる。
        if ctx_flag_isset compacted "${sess}"; then
            if ctx_flag_stale compacted "${sess}" "${COMPACTED_TTL_SECONDS:-600}" && [ "${band}" != "idle" ]; then
                ctx_flag_clear compacted "${sess}"
                printf '[cc-compaction-daemon] stale compacted inflight cleared: sess=%s band=%s (圧縮空振り疑い→再評価)\n' "${sess}" "${band}" >&2
            else
                continue
            fi
        fi
        # prepared 判定 (model.md 鮮度)
        if ctx_prepared_for_episode "${sess}"; then prepared=1; else prepared=0; fi
        # transcript 推定 (400 検出用)
        tr="$(ls -t "${HOME}/.claude/projects/$(printf '%s' "${cwd}" | sed 's#/#-#g')"/*.jsonl 2>/dev/null | head -1)"
        action="$(decide_action "${band}" "${prepared}" "${tr}")"
        [ "${action}" = "NONE" ] && continue
        # ★work喪失防止 (ハンドオフ厳格化): 詳細な model.md が非空でなければ圧縮しない。
        #   機械版 .md は transcript 機械抽出で薄く、それだけで圧縮すると復元品質が低く文脈
        #   喪失を招く。詳細自筆 model.md (Stage1 ctx-prepare-stop が prepare 帯から書く) がある
        #   ときだけ圧縮する。副作用: decide_action の critical 安全弁 (prepared 不問 COMPACT) も
        #   この tick ガードにより実質 model.md 必須になる (critical でも model.md 無ければ圧縮
        #   せず context 保持。薄い復元で文脈喪失するより安全側)。
        # ★空白/改行のみ model.md を「準備済」と誤認しない (resume の ctx_file_has_text 判定と統一)。
        #   [ -s ] (サイズ>0) だと whitespace-only でも圧縮し、resume 側は空扱い→ fallback で文脈喪失。
        if ! ctx_file_has_text "$(ctx_handoff_dir)/${sess}.model.md"; then
            continue
        fi
        # cooldown
        mark="$(ctx_home)/.lastinject_${sess}"; now="$(date +%s)"
        last="$(cat "${mark}" 2>/dev/null || echo 0)"
        [ $((now - last)) -lt "${COOLDOWN_SECONDS:-120}" ] && continue
        # ★ペイン解決: ctx-monitor が state に記録した TMUX_PANE を直接ターゲットする
        #   (co-located 同一 cwd セッションで cwd 突合が別ペインに /clear 誤爆するのを防ぐ)。
        #   記録 pane が tmux に実在するときのみ採用、無ければ従来の cwd 突合に fallback。
        if [ -n "${pane}" ] && command -v tmux >/dev/null 2>&1 \
            && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "${pane}"; then
            :
        else
            pane="$(resolve_pane_by_cwd "${cwd}")"
        fi
        [ -n "${pane}" ] || continue
        # ★pane 再利用誤爆防止: 解決 pane の現住人 (state/*.json で同 pane を記録した最新の
        #   セッション) が別セッションなら、この state は再利用された古い残骸 → /clear しない。
        #   pane が別セッションに再利用された後に古い state が残ると、daemon が古い state の
        #   記録 pane を撃ち現住人 (別セッション) を誤爆するのを防ぐ。
        owner="$(ctx_pane_owner "${sdir}" "${pane}")"
        if [ -n "${owner}" ] && [ "${owner}" != "${sess}" ]; then
            continue
        fi
        # ペインが生成中 (busy) なら注入しない (turn 完了=idle を待つ)
        pane_is_idle "${pane}" || continue
        # ★compacted は送出『前』に立てる。SessionStart(compact|clear) の resume が後で reset する
        #   ため、送出後に立てると reset より遅く立って消えず、次 episode の圧縮を恒久ブロックする
        #   deadlock になる (旧バグ)。送出前に立てれば resume が確実に消し次 episode が回る。復元は
        #   フラグ非依存化済み (compaction-resume) なので、早期 set は復元レースを生まない。
        ctx_flag_set compacted "${sess}"
        if inject "${pane}" "${action}"; then
            echo "${now}" > "${mark}"
        else
            # 送出失敗時はフラグを戻す (I2: 立てっぱなしは resume 待ちデッドロック)
            ctx_flag_clear compacted "${sess}"
        fi
    done
}

run_loop() {
    while true; do
        [ "${CC_HANDOFF_DAEMON_ENABLED:-false}" = "true" ] || { sleep 30; continue; }
        [ -f "$(ctx_home)/DISABLED" ] && { sleep 30; continue; }
        tick
        # ★日次 GC (A3): 孤立 state/handoff/marker/archive を age out (1日1回 debounce)。
        ctx_debounce_ok_window "gc" 86400 && ctx_gc
        sleep "${DAEMON_INTERVAL_SECONDS:-20}"
    done
}

case "${1:-}" in
    --source-only) return 0 2>/dev/null || exit 0 ;;
    --once) tick ;;
    --gc) ctx_gc ;;
    *) run_loop ;;
esac
