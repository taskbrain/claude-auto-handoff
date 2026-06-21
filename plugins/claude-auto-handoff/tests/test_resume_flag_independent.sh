#!/usr/bin/env bash
# 復元のフラグ非依存性 — /clear 後 handoff 復元 TOCTOU レースの回帰テスト。
#
# 本番では daemon が圧縮コマンド (/compact|/clear) を送出した『後』に compacted フラグを立てる
# (inject 完了 = 送出の約12秒後)。一方 SessionStart(source=compact|clear) は送出の数秒後に発火し
# compaction-resume がフラグを読む。つまり SessionStart 時点では compacted フラグは『無い』。
# この観測条件 (fresh handoff あり ∧ compacted フラグ無し) で復元が成立しなければならない。
#
# 旧実装は復元を `[ "$SRC" = "compact" ] || ctx_flag_isset compacted` でガードしていたため、
# source=clear + フラグ無し で再注入が永久に skip された (根因)。本テストの source=clear ケースが
# その赤を再現する。source=compact ケースは退行ガード (元から通るが今後も通り続けること)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
H="${HERE}/../hooks/compaction-resume.sh"

export CLAUDE_SESSION_ID="rsess"
export TMUX_PANE="%77"
SESS="$(ctx_session_key /x)"   # pane 基軸キー (= rsess-p77)。hook も同 TMUX_PANE でこのキーを使う。

# fresh な model.md を置く。compacted フラグは『立てない』(= 本番の送出前タイミングを再現)。
place_handoff() {
    TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; mkdir -p "${TMP}/handoffs"
    printf '# HANDOFF\n## 1. CURRENT GOAL\nfinish_the_widget\n' > "${TMP}/handoffs/${SESS}.model.md"
}
run_resume() { printf '{"source":"%s","cwd":"/x"}' "$1" | bash "${H}"; }

# 1) source=compact + fresh handoff + フラグ無し → 再注入 (退行ガード)
place_handoff
OUT="$(run_resume compact)"
assert_contains "${OUT}" "additionalContext" "compact: 再注入 JSON が出る"
assert_contains "${OUT}" "finish_the_widget" "compact: handoff 本文が再注入される"

# 2) source=clear + fresh handoff + フラグ無し → 再注入 (THE RED: 旧実装はここで再注入しない)
place_handoff
OUT="$(run_resume clear)"
assert_contains "${OUT}" "additionalContext" "clear(フラグ無): 再注入 JSON が出る"
assert_contains "${OUT}" "finish_the_widget" "clear(フラグ無): handoff 本文が再注入される"

# 3) source=clear + fresh handoff + フラグ無し でも model.md は iterative update 用に保持
assert_file_exists "${TMP}/handoffs/${SESS}.model.md"

unset TMUX_PANE
rm -rf "${TMP}"
report
