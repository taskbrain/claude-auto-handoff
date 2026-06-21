#!/usr/bin/env bash
# test_pane_reuse_reset.sh — Critical (Codex 指摘): pane 再利用時の stale state 誤爆防止。
# pane 基軸キーは同一 pane を順次使う別セッションでキーを共有する。前占有者が compact state +
# fresh model.md + compacted/episode フラグを残したまま、同一 pane で新 Claude が startup すると、
# 同一 slug-pN キーのため daemon が「fresh な compact state + prepared」と判断し新占有者に /clear を
# 誤爆しうる (旧 UUID キーは偶然これを防いでいた)。
# 修正: SessionStart(source=startup|resume) は新規/再 attach プロセスなので、この pane-key の state を
# idle に「上書き」し episode/compacted/prepare_prompted を切る (clean start)。
# source=clear (継続セッション = /clear 復元) はこの reset 経路に来ず、既存 state を保つ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
RESUME="${HERE}/../hooks/compaction-resume.sh"
export CLAUDE_SESSION_ID="reuse"; export TMUX_PANE="%9"
SESS="$(ctx_session_key /x)"
state_field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null; }

seed_stale() {  # 前占有者の残骸を作る (compact state + fresh model.md + 全フラグ)
    mkdir -p "${TMP}/state" "${TMP}/handoffs"
    python3 -c "import json;json.dump({'session_id':'${SESS}','band':'compact','cwd':'/x','used_pct':60,'used_tokens':0,'window_size':0,'ts':'t','pane':'%9'},open('${TMP}/state/${SESS}.json','w'))"
    printf '# H\n## 1. CURRENT GOAL\nOLD_OCCUPANT_GOAL\n' > "${TMP}/handoffs/${SESS}.model.md"
    : > "${TMP}/.compacted_${SESS}"; : > "${TMP}/.episode_${SESS}"; : > "${TMP}/.prepare_prompted_${SESS}"
}

# 1) source=startup → 新占有者: state を idle に上書き + フラグ全切り (daemon 誤爆防止)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; seed_stale
printf '{"source":"startup","cwd":"/x"}' | bash "${RESUME}" >/dev/null
assert_eq "$(state_field "${TMP}/state/${SESS}.json" band)" "idle" "startup: stale compact state を idle に上書き"
assert_eq "$([ -e "${TMP}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "startup: compacted フラグ切り"
assert_eq "$([ -e "${TMP}/.episode_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "startup: episode フラグ切り"
assert_eq "$([ -e "${TMP}/.prepare_prompted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "startup: prepare_prompted フラグ切り"

# 2) source=resume も同様に reset (別セッションを同一 pane で resume したケース)
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; seed_stale
printf '{"source":"resume","cwd":"/x"}' | bash "${RESUME}" >/dev/null
assert_eq "$(state_field "${TMP}/state/${SESS}.json" band)" "idle" "resume: stale state を idle に上書き"
assert_eq "$([ -e "${TMP}/.compacted_${SESS}" ] && echo SET || echo UNSET)" "UNSET" "resume: compacted フラグ切り"

# 3) source=clear (継続セッション) → startup reset しない (既存 state の band を維持)。
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"; seed_stale
printf '{"source":"clear","cwd":"/x"}' | bash "${RESUME}" >/dev/null
assert_eq "$(state_field "${TMP}/state/${SESS}.json" band)" "compact" "clear: 継続セッションは band 維持 (startup reset 非対象)"

rm -rf "${TMP}"
report
