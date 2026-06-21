#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
H="${HERE}/../hooks/ctx-prepare-stop.sh"
export CLAUDE_SESSION_ID="stopsess"
# state/handoff/flag は ctx_session_key (per-session ユニーク) で命名される。
# cwd=/x の決定論キー (CLAUDE_SESSION_ID 設定時 = <slug>-<uid 末尾8>)。
SESS="$(ctx_session_key /x)"

mk_state() {  # <home> <sess-key> <band>
    mkdir -p "$1/state" "$1/handoffs"
    printf '{"band":"%s"}' "$3" > "$1/state/$2.json"
}
run() { printf '{"cwd":"/x","stop_hook_active":%s}' "$1" | bash "${H}"; }

# 1) band=prepare / 未準備 → decision:block + 自筆パス + reference-only 指示
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" prepare
OUT="$(run false)"
assert_contains "${OUT}" "block" "prepare 帯 → block 発火"
assert_contains "${OUT}" "${T}/handoffs/${SESS}.model.md" "自筆パス埋め込み (ctx_session_key)"
assert_contains "${OUT}" "reference-only" "reference-only 前置き指示"
assert_contains "${OUT}" "8 セクション" "8セクション指示"

# 2) stop_hook_active=true → loop guard で再 block しない
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" prepare
assert_eq "$(run true)" "" "stop_hook_active → 再 block なし"

# 3) 当 episode 自筆済み (model.md 非空・episode stamp なし) → no block
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" prepare
printf 'handoff body' > "${T}/handoffs/${SESS}.model.md"
assert_eq "$(run false)" "" "prepared 済 → no block"

# 4) compacted フラグ (daemon /clear 送出済み・resume 待ち) → no block
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" compact
: > "${T}/.compacted_${SESS}"
assert_eq "$(run false)" "" "compacted → no block"

# 5) band=idle → no block
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" idle
assert_eq "$(run false)" "" "idle → no block"

# 6) debounce: 同 episode 2 回目は再注入抑制
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" prepare
OUT1="$(run false)"; assert_contains "${OUT1}" "block" "初回 block"
OUT2="$(run false)"; assert_eq "${OUT2}" "" "debounce 窓内 → 再注入なし"

# 7) kill switch
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_state "${T}" "${SESS}" prepare
assert_eq "$(CC_HANDOFF_ENABLED=off run false)" "" "kill switch で no-op"

rm -rf "${T}"
report
