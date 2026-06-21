#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
# decide_action <band> <prepared:0|1> <transcript> → COMPACT|NONE
. "${HERE}/../scripts/cc-compaction-daemon.sh" --source-only
EMPTY="$(mktemp)"
assert_eq "$(decide_action idle 1 "${EMPTY}")"     "NONE"    "idle"
assert_eq "$(decide_action prepare 1 "${EMPTY}")"  "NONE"    "prepare 帯は daemon 非介入 (Stop hook が準備)"
assert_eq "$(decide_action compact 0 "${EMPTY}")"  "NONE"    "compact ∧ 未prepared → 待機 (work 喪失防止)"
assert_eq "$(decide_action compact 1 "${EMPTY}")"  "COMPACT" "compact ∧ prepared → 圧縮 (本線)"
assert_eq "$(decide_action critical 0 "${EMPTY}")" "COMPACT" "critical → 圧縮 (prepared 不問の安全弁)"
# 400 orphan 署名は band/prepared に関わらず COMPACT
assert_eq "$(decide_action compact 0 "${HERE}/fixtures/orphan400.jsonl")" "COMPACT" "400署名→圧縮"
rm -f "${EMPTY}"
report
