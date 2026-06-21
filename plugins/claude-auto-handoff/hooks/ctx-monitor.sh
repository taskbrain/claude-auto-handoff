#!/usr/bin/env bash
# ctx-monitor.sh — statusLine から委譲され、used_percentage を読んで per-session
# state を書く (副作用のみ。描画はしない)。失敗は silent (statusLine を壊さない)。
#
# ★配線: 本スクリプトは settings.json には登録しない。hook は token 量を受け取れず
#   statusLine だけが context_window.used_percentage を持つため、~/.claude/statusline.sh
#   の委譲ブロックから起動する。host 共有ファイルのため本番配線は手動 (deferred)。
#   手順: README.md の「statusLine 配線」節を参照。
#   配線前は PreCompact(L2)/SessionStart(L3) のみ稼働し、L0/L1 常時 handoff は未起動。
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
. "${HOOK_DIR}/_ctx_common.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

RAW="$(cat 2>/dev/null || true)"
[ -n "${RAW}" ] || exit 0

IFS=$'\t' read -r SID PCT TOK WIN CWD <<<"$(python3 - "${RAW}" <<'PY' 2>/dev/null || true
import json,sys
try: p=json.loads(sys.argv[1])
except Exception: p={}
cw=p.get("context_window",{}) or {}
cu=p.get("current_usage",{}) or {}
pct=cw.get("used_percentage")
win=cw.get("context_window_size") or 0
tok=(cu.get("input_tokens",0) or 0)+(cu.get("cache_read_input_tokens",0) or 0)+(cu.get("cache_creation_input_tokens",0) or 0)
sid=p.get("session_id","") or ""
cwd=(p.get("workspace",{}) or {}).get("current_dir","") or ""
# used_percentage が無ければ tokens/window から算出
if pct is None and win:
    pct=round(tok*100.0/win,1)
# 実 payload に current_usage が無い場合、used_percentage×window から導出
# (1M 窓の絶対 token cap レッグを生かすため)
if (not tok) and pct is not None and win:
    tok = int(float(pct) * win / 100)
print(f"{sid}\t{pct if pct is not None else 0}\t{tok}\t{win}\t{cwd}")
PY
)"

[ -n "${CWD}" ] || CWD="${PWD}"
# session キーは ctx_session_key (per-session ユニーク: slug + uid/pane suffix)。
# cch_session_slug の slug 単独だと co-located 同一 slug セッションが state を共有・衝突するため。
SESS="$(ctx_session_key "${CWD}")"
[ -n "${SESS}" ] || SESS="${SID:-unknown-session}"
PANE="${TMUX_PANE:-}"

BAND="$(classify_band "${PCT:-0}" "${TOK:-0}")"
ctx_ensure_dirs
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# 共通 writer (compaction-resume の自記録と同一フォーマット、重複排除)。
ctx_write_state "${SESS}" "${PCT:-0}" "${TOK:-0}" "${WIN:-0}" "${BAND}" "${CWD}" "${TS}" "${PANE}"

# episode lifecycle: 非idle で stamp (冪等・climb 跨ぎで不変)、idle で全フラグ reset。
# stamp は prepared 判定 (model.md 鮮度) の基準時刻になる。
case "${BAND}" in
    idle) ctx_episode_reset "${SESS}" ;;
    *)    ctx_episode_stamp "${SESS}" ;;
esac

# prepare 以上なら機械版 handoff writer を非同期起動 (描画/圧縮を遅延させない)。
# これは Stage1 のモデル自筆 model.md が無い場合の fallback スナップショット。
case "${BAND}" in
    prepare|compact|critical)
        if [ "${CC_HANDOFF_ENABLED:-on}" != "off" ] && [ -x "${HOOK_DIR}/cc-compaction-handoff.sh" ]; then
            ( CC_COMPACTION_HOME="$(ctx_home)" "${HOOK_DIR}/cc-compaction-handoff.sh" \
                "${SESS}" "${CWD}" "${PCT:-0}" "${TOK:-0}" >/dev/null 2>&1 & ) || true
        fi
        ;;
esac
exit 0
