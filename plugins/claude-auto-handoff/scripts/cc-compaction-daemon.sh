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
# residual 検出に使う部分文字列 (継続プロンプト末尾の一部)。
CONTINUATION_RESIDUAL_MARK="言い直してから作業を継続せよ"

# residual_in_tail <capture_text> → 0(末尾3行=入力欄相当に継続プロンプト文言が残留) / 1。
# 純関数 (capture 文字列のみに依存) でテスト容易。Claude REPL は送信済みプロンプトを画面履歴に
# 表示するため whole-capture でなく末尾3行に限定し、正常時 (送信成功で履歴に残るだけ) の不要
# Enter を防ぐ。
residual_in_tail() {
    local tail3; tail3="$(printf '%s' "${1:-}" | tail -3)"
    [ -n "${tail3}" ] && printf '%s' "${tail3}" | grep -qF "${CONTINUATION_RESIDUAL_MARK}"
}

# inject <pane> <action> → 0(送出成功) / 1(失敗)。圧縮コマンド (${COMPACTION_COMMAND}, 既定 /compact)
# 送出後に「ハンドオフから継続せよ」の kick を送る (SessionStart(source=compact|clear) が
# compaction-resume で handoff を先頭注入し、この kick が最初の turn を起動する)。
# ★圧縮コマンド本体の send-keys 成否を返す: 失敗を握り潰すと caller が compacted を誤って立て
#   resume 待ちデッドロックになる (I2)。kick は best-effort。
# ★大 context の圧縮リロード/要約は入力欄準備に時間がかかる: 待機を RESUME_DELAY_SECONDS で延長し、
#   kick 後に capture-pane で継続プロンプト文言が入力欄に残留 (= Enter 取りこぼし) していれば
#   best-effort で Enter を再確定する。
# ★M-1: 残留判定は capture 末尾3行 (入力欄相当) に限定する。Claude REPL は送信済みプロンプトを
#   画面履歴に表示するため、whole-capture では正常時も文言が残り不要 Enter を撃つ。さらに
#   再 Enter 直前に pane_is_idle を再確認し、busy (ユーザー割り込み中) なら撃たない。
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
            # ★圧縮リロード完了待ち (Part B): 大 context のリロード/要約は入力欄準備に時間がかかる。
            #   /compact は LLM 要約のため /clear より長め。最低 RESUME_DELAY_SECONDS 待ち、その後
            #   pane idle (= 入力欄準備完了) を RESUME_MAX_WAIT_SECONDS まで poll してから継続プロンプトを
            #   送る。固定 sleep だけでは大 context で早すぎ、プロンプト+Enter が入力欄準備前に届き
            #   取りこぼす。timeout でも degrade で送る (送らないより送る)。
            sleep "${RESUME_DELAY_SECONDS:-12}"
            local waited="${RESUME_DELAY_SECONDS:-12}" maxw="${RESUME_MAX_WAIT_SECONDS:-90}"
            while [ "${waited}" -lt "${maxw}" ]; do
                pane_is_idle "${pane}" && break
                sleep 1; waited=$((waited+1))
            done
            tmux send-keys -t "${pane}" "${CONTINUATION_PROMPT}" Enter 2>/dev/null || true
            # ★Enter 取りこぼしガード (Part B): 継続プロンプトが入力欄 (末尾3行) に残留し pane が
            #   idle の間、最大 RESUME_REENTER_MAX 回 Enter を再確定する。残留消失 (= 送信成功) /
            #   busy で停止。capture-pane / tmux 不在は best-effort で握り潰す (break)。
            local i=0 cap
            while [ "${i}" -lt "${RESUME_REENTER_MAX:-3}" ]; do
                sleep 1
                cap="$(tmux capture-pane -t "${pane}" -p 2>/dev/null || true)"
                if residual_in_tail "${cap}" && pane_is_idle "${pane}"; then
                    tmux send-keys -t "${pane}" Enter 2>/dev/null || true
                else
                    break
                fi
                i=$((i+1))
            done
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
