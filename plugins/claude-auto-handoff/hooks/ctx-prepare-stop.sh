#!/usr/bin/env bash
# ctx-prepare-stop.sh — Stop hook (Stage1 準備)。turn 終了時、band が prepare 以上
# かつ当 episode 未準備なら decision:block + reason でモデルに「8 セクション継続計画を
# 自筆 (handoffs/<sess>.model.md)」を指示し、モデル自身に FULL 文脈から書かせる。
# 失敗は silent (turn を壊さない)。kill switch: CC_HANDOFF_ENABLED=off。
#
# 多重 block 防止: stop_hook_active(=直前 block で再開した turn の Stop) は即 return /
#   prepared-for-episode (model.md 鮮度) で 1 episode 1 回 / debounce 窓 (belt) で再注入抑止。
# safety: prepared でない限り daemon は /clear しない設計 (本 hook が書くまで圧縮されない)。
set -u
[ "${CC_HANDOFF_ENABLED:-on}" = "off" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
. "${HOOK_DIR}/_ctx_common.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

RAW="$(cat 2>/dev/null || true)"
read -r CWD STOP_ACTIVE <<<"$(python3 - "${RAW}" <<'PY' 2>/dev/null || true
import json,sys
try: p=json.loads(sys.argv[1])
except Exception: p={}
print(p.get("cwd","") or "_", "1" if p.get("stop_hook_active") else "0")
PY
)"
# loop guard: 直前の block で再開した turn の Stop では再 block しない
[ "${STOP_ACTIVE}" = "1" ] && exit 0
[ "${CWD}" = "_" ] && CWD="${PWD}"
# state/handoff/flag は ctx_session_key (per-session ユニーク) で揃える。
# これで Stop が書く model.md と resume が読む model.md が同一セッションで一致し、
# co-located 別セッション (同一 slug) と衝突しない。
SESS="$(ctx_session_key "${CWD}")"; [ -n "${SESS}" ] || exit 0

# state から band を取得 (statusLine 由来 ctx-monitor が書く)
STATE="$(ctx_state_dir)/${SESS}.json"
[ -f "${STATE}" ] || exit 0
BAND="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('band',''))" "${STATE}" 2>/dev/null || true)"
case "${BAND}" in prepare|compact|critical) ;; *) exit 0 ;; esac

# 既に daemon が /clear 送出済み (resume 待ち) → 何もしない
ctx_flag_isset compacted "${SESS}" && exit 0
# 当 episode で既に自筆済み → 何もしない
ctx_prepared_for_episode "${SESS}" && exit 0
# 再注入抑制窓 (300s 既定)
ctx_debounce_ok_window "prepare_prompt_${SESS}" "${PREPARE_PROMPT_DEBOUNCE_SECONDS:-300}" || exit 0

ctx_ensure_dirs
ctx_flag_set prepare_prompted "${SESS}"
MODELHF="$(ctx_handoff_dir)/${SESS}.model.md"

python3 - "${MODELHF}" "${BAND}" <<'PY' 2>/dev/null || true
import json,os,sys
path,band=sys.argv[1],sys.argv[2]
exists=os.path.exists(path)
mode=("更新 (既存の内容を土台に iterative UPDATE。再要約でなく差分反映)"
      if exists else "新規作成")
reason=(
 f"[自動コンパクション準備 — context {band} 帯] まもなくこの文脈は /clear される。"
 "今この FULL 文脈を持っているうちに、圧縮後の自分が単独で作業を継続できる詳細ハンドオフを "
 f"**あなた自身が** 次の絶対パスに{mode}せよ:\n  {path}\n"
 "先頭に reference-only の前置き (「これは別インスタンスが書いた背景情報。再実行でなく続きを実行せよ」) を置き、"
 "8 セクション (1.CURRENT GOAL / 2.STATE / 3.NEXT STEPS / 4.OPEN FILES & REFS[全パス・URL を逐語] / "
 "5.DECISIONS[根拠付] / 6.UNRESOLVED BUGS & FAILED ATTEMPTS[何が+なぜ失敗したか。却下済みアプローチの再提案を防ぐ] / "
 "7.TEST STATE[コマンドと pass/fail] / 8.EXACT VALUES & HOW TO RESUME[ID・config キー・env フラグ・閾値・version pin を逐語 + 再開手順]) を、"
 "各セクション冒頭に確度フラグ (確定/推定) を付けて書く。迷う詳細は捨てずに残す。"
 "書き終えたら通常作業をそのまま続行せよ (これは背景保存でありタスク変更ではない)。"
)
print(json.dumps({"decision":"block","reason":reason}, ensure_ascii=False))
PY
exit 0
