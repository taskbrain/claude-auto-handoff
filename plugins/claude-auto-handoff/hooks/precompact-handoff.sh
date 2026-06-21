#!/usr/bin/env bash
# precompact-handoff.sh — PreCompact hook (async backstop)。不意の native /compact 時に
# 機械版 handoff を最終化するだけ (モデル自筆 model.md が無い緊急時の保険)。
#
# ★customInstructions 出力は撤去済み: 現行 Claude Code では PreCompact の
#   hookSpecificOutput.customInstructions は schema 検証に通らず弾かれる (実機確認済)。
#   要約整形は CLAUDE.md の `# Compact instructions` で行う (公式手段)。本 hook は
#   handoff スナップショットの最終化のみを行い、JSON は出力しない。失敗は silent。
set -u
[ "${CC_HANDOFF_ENABLED:-on}" = "off" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
. "${HOOK_DIR}/_ctx_common.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

RAW="$(cat 2>/dev/null || true)"
read -r SID TRANSCRIPT CWD <<<"$(python3 - "${RAW}" <<'PY' 2>/dev/null || true
import json,sys
try: p=json.loads(sys.argv[1])
except Exception: p={}
print(p.get("session_id","") or "_", p.get("transcript_path","") or "_", p.get("cwd","") or "_")
PY
)"
[ "${CWD}" = "_" ] && CWD="${PWD}"
# handoff ファイルは ctx_session_key (per-session ユニーク) で命名し、Stop/resume と一致させる。
SESS="$(ctx_session_key "${CWD}")"; [ -n "${SESS}" ] || SESS="${SID}"
[ "${TRANSCRIPT}" = "_" ] && TRANSCRIPT=""

# handoff を同期的に最終化 (snapshot が要約に間に合うように)。これが唯一の役割。
# customInstructions は出力しない (現行版で弾かれるため。要約整形は CLAUDE.md
# `# Compact instructions` が公式手段)。
if [ -x "${HOOK_DIR}/cc-compaction-handoff.sh" ]; then
    CC_COMPACTION_HOME="$(ctx_home)" "${HOOK_DIR}/cc-compaction-handoff.sh" \
        "${SESS}" "${CWD}" "pre" "0" "${TRANSCRIPT}" >/dev/null 2>&1 || true
fi
exit 0
