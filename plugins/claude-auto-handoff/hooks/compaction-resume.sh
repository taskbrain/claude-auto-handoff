#!/usr/bin/env bash
# compaction-resume.sh — SessionStart hook (Stage3 復帰)。source=compact/clear のとき、
# モデル自筆 handoff (handoffs/<sess>.model.md) を優先し (無ければ機械版 .md)、
# additionalContext で先頭再注入する。末尾に RESUME 手順 + ゴール復唱 (lost-in-the-middle 対策)。
# 併せて episode/compacted/prepare_prompted フラグを reset し次サイクルを clean に
# (model.md は iterative update 用に保持)。source=startup/resume では再注入は no-op。
# ★handoff が空/不在の場合 (model.md も機械版 .md も使えない) は silent no-op にせず、
#   最小ガイダンスを additionalContext で出す (文脈ゼロで別タスクを始めるのを防ぐ)。
# ★I-1b: SessionStart の全 source で、自 state が未生成のときだけ自 pane を band=idle で
#   即記録する (pane 再利用直後、新住人が statusLine 発火する前の初回窓で古い残骸が現住人を
#   僭称し誤爆されるのを塞ぐ。daemon の現住人突合 ctx_pane_owner の材料を先に置く)。
#   既存 state があれば触らない (statusLine の band を idle で潰さない)。
#   残存限界: 同一 tmux pane を kill せず順次 claude 起動し、この SessionStart hook が
#   走るより前の極短窓は state ベース突合では塞げない (完全根治には REPL 単位の所有印が必要)。
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
. "${HOOK_DIR}/_ctx_common.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
# kill switch: 機能全体 (生成 + 復元) を無効化。README の CC_HANDOFF_ENABLED と整合させる。
[ "${CC_HANDOFF_ENABLED:-on}" = "off" ] && exit 0

RAW="$(cat 2>/dev/null || true)"
read -r SRC CWD <<<"$(python3 - "${RAW}" <<'PY' 2>/dev/null || true
import json,sys
try: p=json.loads(sys.argv[1])
except Exception: p={}
print(p.get("source","") or "_", p.get("cwd","") or "_")
PY
)"
[ "${CWD}" = "_" ] && CWD="${PWD}"
# state/handoff/flag は ctx_session_key (per-session ユニーク) で揃える。
# Stop が書く model.md と同一キーで読むことで co-located 別セッションと衝突しない。
SESS="$(ctx_session_key "${CWD}")"; [ -n "${SESS}" ] || exit 0

# ★I-1b + pane 再利用ガード: SessionStart で自 state を記録する。pane 基軸キーは同一 pane を
#   順次使う別セッションでキーを共有するため、source で「新規/再 attach プロセス」と「継続
#   セッション」を区別して扱う。
#   - source=startup|resume (= 新規 Claude プロセス。この pane の新占有者かもしれない):
#     前占有者が残した compact/critical state + fresh model.md + フラグを daemon が新占有者に
#     /clear 撃つのを防ぐため、この pane-key の episode/compacted/prepare_prompted を切り、state を
#     idle で「上書き」する (clean start)。/clear 復元 (source=clear) はこの分岐に来ない。
#   - source=compact|clear (継続セッション): 既存 state は触らない (statusLine band を idle で
#     潰さない)。未生成のときだけ idle 記録 (新住人 statusLine 発火前の初回窓の僭称防止)。
# ★世代マーカーは startup|resume (新プロセス起動) で tmux/非tmux 問わず touch する。以降の復元は
#   handoff.mtime >= gen.mtime を要求し、pane 再利用 (tmux) / tty 再利用 (非tmux) いずれでも前占有者の
#   handoff を誤復元しない (デュアルレビュー must-fix + follow-up)。ctx_generation_stamp は SESS のみ
#   依存のため TMUX_PANE 不要。state 即記録は daemon の pane 突合材料なので tmux 経路のみ (下記)。
case "${SRC}" in
    startup|resume) ctx_ensure_dirs; ctx_generation_stamp "${SESS}" ;;
esac
if [ -n "${TMUX_PANE:-}" ]; then
    case "${SRC}" in
        startup|resume)
            ctx_episode_reset "${SESS}"
            ctx_ensure_dirs
            ctx_write_state "${SESS}" 0 0 0 idle "${CWD}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TMUX_PANE}"
            ;;
        *)
            if [ ! -f "$(ctx_state_dir)/${SESS}.json" ]; then
                ctx_ensure_dirs
                ctx_write_state "${SESS}" 0 0 0 idle "${CWD}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TMUX_PANE}"
            fi
            ;;
    esac
fi

case "${SRC}" in compact|clear) ;; *) exit 0 ;; esac

# モデル自筆 (.model.md) を優先、無ければ機械版 (.md)
MODELHF="$(ctx_handoff_dir)/${SESS}.model.md"
MECHHF="$(ctx_handoff_dir)/${SESS}.md"
HF=""
# M-3: 本文の実在判定は ctx_file_has_text (strip 後非空) で行う。[ -s ]/[ -f ] は
# 空白/改行のみの handoff を非空と誤判定するため使わない。
# A2: さらに鮮度ゲート (ctx_file_has_fresh_text) を併用する。pane 基軸キーは同一 pane を
#   順次使う別セッション間で共有されうるため、何時間も前の死んだ占有者の handoff を
#   誤復元しないよう mtime が HANDOFF_RESTORE_FRESH_SECONDS (既定 1800s) 以内のものだけ採用。
#   古い handoff は本文有りでも「使えない」扱いとし、下の HAVE_BODY=0 経路で空ガイダンスを出す。
# ★世代ガード (ctx_handoff_after_generation): pane 基軸キーは同一 pane を順次使う別セッション間で
#   共有されうるため、鮮度内でも「前占有者が startup 前に書いた handoff」は復元しない。startup|resume
#   で touch した gen マーカー以降に書かれた handoff (= 現世代) だけを採用する。gen マーカー不在は
#   後方互換で許可 (従来どおり復元)。
FRESH="${HANDOFF_RESTORE_FRESH_SECONDS:-1800}"
if ctx_file_has_fresh_text "${MODELHF}" "${FRESH}" && ctx_handoff_after_generation "${MODELHF}" "${SESS}"; then HF="${MODELHF}"
elif ctx_file_has_fresh_text "${MECHHF}" "${FRESH}" && ctx_handoff_after_generation "${MECHHF}" "${SESS}"; then HF="${MECHHF}"; fi

# 使える (非空 ∧ 鮮度内 ∧ 現世代) handoff があるか。HF が立っていればそれが唯一の判定。
# 無ければ (不在/空/stale/前世代) HAVE_BODY=0 経路で空ガイダンスを出す。
HAVE_BODY=0
[ -n "${HF}" ] && HAVE_BODY=1

# ★復元はフラグ非依存。L59 の case で SRC は既に compact|clear に限定済みのため、fresh handoff (HF)
#   があれば常に再注入する。compacted フラグは『復元信号』には使わない (daemon の再発火ガード専用)。
#   旧実装は compacted フラグを併用したが、daemon はフラグを inject 完了後 (= 圧縮コマンド送出の
#   約12秒後) に立てるため、SessionStart がフラグを読む時点では未設定で再注入が永久に skip される
#   TOCTOU レースがあった (根因)。source 自体が「圧縮された」確実な信号なので、フラグでの再確認は
#   不要かつ有害。手動 /clear も fresh handoff があれば復元する (真にクリーン開始したい場合は handoff
#   を消すか DISABLED。実運用は /clear して復元を期待するため復元側に倒す)。鮮度ゲート
#   (ctx_file_has_fresh_text) と pane 再利用ガード (startup/resume の episode_reset) が誤復元を防ぐ。
if [ -n "${HF}" ]; then
python3 - "${HF}" <<'PY' 2>/dev/null || true
import json,sys
body=open(sys.argv[1],errors="replace").read()
goal=""
lines=body.splitlines()
for i,l in enumerate(lines):
    if "CURRENT GOAL" in l:
        for j in range(i+1,min(i+5,len(lines))):
            if lines[j].strip():
                goal=lines[j].strip(); break
        break
ctx=("[auto-compaction 復帰] 直前にこのセッションは自動コンパクションで /clear された。"
     "下記は圧縮直前に保全された詳細ハンドオフ (あなた自身またはバックストップが作成)。"
     "これを唯一の信頼できる文脈源として、再実行でなく『続き』を実行せよ。\n\n"
     + body +
     "\n\n---\n[RESUME 手順] ① このハンドオフを読了 → ② 現在地を 3-5 文で言い直す "
     "→ ③ NEXT STEPS の先頭(次の一手)を確認 → ④ TEST STATE の smoke を実行してから着手。"
     + ("\n[REMINDER] 最優先ゴール: " + goal if goal else ""))
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":ctx}}, ensure_ascii=False))
PY
elif [ "${HAVE_BODY}" = "0" ]; then
# ★handoff 空/不在の no-op fallback: 文脈ゼロで再開し別タスクを始めるのを防ぐ最小ガイダンス。
#   source は case ガードで compact|clear に限定済 (startup/resume はここに来ない)。
python3 - <<'PY' 2>/dev/null || true
import json
ctx=("⚠️ 自動ハンドオフが空でした。直前の作業文脈は復元されていません。"
     "新しい作業を始める前に、プロジェクトの進行中メモ (TODO / handoff ノート等) や "
     "直近の git log を確認し、直前に何をしていたかを特定してから継続してください。"
     "安易に別タスクを始めないこと。")
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":ctx}}, ensure_ascii=False))
PY
fi

# 圧縮サイクルを締めて次を clean に (model.md は保持、episode/compacted/prompted を reset)
ctx_episode_reset "${SESS}"
exit 0
