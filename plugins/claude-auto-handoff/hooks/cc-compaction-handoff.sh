#!/usr/bin/env bash
# cc-compaction-handoff.sh <session> <cwd> <used_pct> <used_tokens> [transcript_path]
# transcript から 8 セクションの機械版 handoff を生成する (モデル自筆 model.md が無い緊急時の
# fallback スナップショット)。失敗は silent。
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
. "${HOOK_DIR}/_ctx_common.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

SESS="${1:-}"; CWD="${2:-$PWD}"; PCT="${3:-0}"; TOK="${4:-0}"
TRANSCRIPT="${5:-${CC_COMPACTION_TRANSCRIPT:-}}"
[ -n "${SESS}" ] || exit 0
ctx_debounce_ok "handoff_${SESS}" || exit 0   # 60s 窓で多重生成抑止
ctx_ensure_dirs

# transcript が未指定なら現セッションの最新 jsonl を推定 (本番は引数で渡る)
if [ -z "${TRANSCRIPT}" ]; then
    PROJ="${HOME}/.claude/projects/$(printf '%s' "${CWD}" | sed 's#/#-#g')"
    TRANSCRIPT="$(find "${PROJ}" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi

EXTRACT="$(python3 "${HOOK_DIR}/lib/transcript_extract.py" "${TRANSCRIPT}" 2>/dev/null || true)"
REQS="$(printf '%s\n' "${EXTRACT}" | sed -n 's/^REQUEST\t//p')"
FILES="$(printf '%s\n' "${EXTRACT}" | sed -n 's/^FILE\t//p')"
CMDS="$(printf '%s\n' "${EXTRACT}" | sed -n 's/^CMD\t//p')"
GOAL="$(printf '%s\n' "${REQS}" | tail -1)"
BRANCH="$(git -C "${CWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

HF="$(ctx_handoff_dir)/${SESS}.md"
{
  echo "# HANDOFF — ${SESS} (updated: ${TS}, ctx ${PCT}%, ~${TOK} tok, branch ${BRANCH})"
  echo
  echo "## 1. CURRENT GOAL"
  echo "${GOAL:-（直近の user 要求が抽出できませんでした。transcript を確認）}"
  echo
  echo "## 2. STATE / WHERE WE ARE"
  echo "- branch: ${BRANCH} / cwd: ${CWD}"
  echo "- context: ${PCT}% (~${TOK} tokens) — 自動ハンドオフ生成時点"
  echo
  echo "## 3. NEXT STEPS"
  echo "（圧縮後の自分へ: 下記 OPEN FILES と DECISIONS を確認し、CURRENT GOAL を継続せよ。"
  echo "  まず TEST STATE の smoke を実行してから新規変更に着手すること）"
  echo
  echo "## 4. OPEN FILES / REFS (復元ハンドル)"
  if [ -n "${FILES}" ]; then printf '%s\n' "${FILES}" | sed 's/^/- /'; else echo "- （編集ファイルなし）"; fi
  echo
  echo "## 5. DECISIONS MADE"
  echo "（transcript からの自動抽出は未対応。重要な決定はプロジェクトのメモ / git log を参照）"
  echo
  echo "## 6. GOTCHAS / UNRESOLVED BUGS"
  echo "（実行コマンド履歴・失敗を確認: 下記 CMD ログ）"
  if [ -n "${CMDS}" ]; then printf '%s\n' "${CMDS}" | sed 's/^/- cmd: /'; fi
  echo
  echo "## 7. TEST STATE"
  echo "（最後に実行したテストコマンドと結果を確認。再開時はまず smoke を実行）"
  echo
  echo "## 8. ENV / HOW TO RESUME"
  echo "- pwd: ${CWD}"
  echo "- 直近の user 要求 (新しい順):"
  printf '%s\n' "${REQS}" | sed 's/^/  - /'
} > "${HF}" 2>/dev/null || exit 0

# archive snapshot
cp "${HF}" "$(ctx_archive_dir)/${SESS}-$(date -u +%Y%m%dT%H%M%SZ).md" 2>/dev/null || true

exit 0
