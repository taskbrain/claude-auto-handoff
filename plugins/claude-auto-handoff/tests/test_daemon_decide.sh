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
# 400 orphan 署名は band/prepared に関わらず COMPACT_RECOVER (回復経路)。
# ★orphan-400 (#40305) は in-place /compact では復旧不能 (要約 API 呼出自体が壊れた tool_result で
#   400 になり /compact 再送でも回復しない = 400→/compact→400 の stall ループ)。/clear のみが壊れた
#   履歴を捨てて確実に回復するため、回復経路は通常圧縮 (COMPACT) と区別し COMPACT_RECOVER を返す
#   (inject 側が COMPACTION_COMMAND に依らず /clear を強制する)。
assert_eq "$(decide_action compact 0 "${HERE}/fixtures/orphan400.jsonl")" "COMPACT_RECOVER" "400署名→COMPACT_RECOVER (orphan-400は/clear一択 #40305)"

# === #3: 400署名 line-count filter ===
# has_400_signature <tr> [sess]: sess 指定時、同一 transcript の『記録行数以降』のみで判定。ただし旧400抑止は
# 『記録後に transcript が成長した』(= /compact 要約 or 継続 turn が append した = 圧縮が効いた証拠) ときだけ
# 適用し、成長が無ければ (= 1M で /compact が空振りし何も append しない) marker を無視して全行再検出に倒す
# (空振り下で旧400を永久マスクすると低 band で band 経路も発火せずセッションが 400 で恒久 stall するのを防ぐ)。
HOMED="$(mktemp -d)"; export CC_COMPACTION_HOME="${HOMED}"
TR="$(mktemp)"
printf '%s\n' '{"isApiErrorMessage":true,"text":"API Error: 400 oops"}' > "${TR}"   # line1 = 旧400
printf 'filler\nfiller\nfiller\nfiller\n' >> "${TR}"                                  # 計5行
# A) marker 無し → 従来どおり検出 (後方互換)
assert_eq "$(has_400_signature "${TR}" && echo HIT || echo MISS)"          "HIT"  "#3: marker無し(2引数) → 400署名検出 (後方互換)"
assert_eq "$(has_400_signature "${TR}" "sessX" && echo HIT || echo MISS)"  "HIT"  "#3: marker不在+sess → 400署名検出 (degrade=検出側)"
# B) [圧縮成功] marker=5 記録後に要約3行 append (→8行)、新領域(6-8)に400無し → 旧400抑止 MISS
printf '%s\t%s' "${TR}" "5" > "${HOMED}/.compact_tr_lines_sessX"
printf 'summary\nsummary\nsummary\n' >> "${TR}"                                       # 計8行 (成長=圧縮成功の証拠)
assert_eq "$(has_400_signature "${TR}" "sessX" && echo HIT || echo MISS)"  "MISS" "#3: 圧縮成功(append有り) → 記録行以前の旧400は抑止"
# C) 新たな400を行9に追記 → 記録行(5)以降の新領域 → 検出 (新規エラーは拾う)
printf '%s\n' '{"isApiErrorMessage":true,"text":"API Error: 400 again"}' >> "${TR}"   # 計9行
assert_eq "$(has_400_signature "${TR}" "sessX" && echo HIT || echo MISS)"  "HIT"  "#3: 記録行以降の新規400は検出"
# D) [important: 空振り /compact] marker=現在行数(9), 以後 append 無し → 成長無し → marker無視で全行再検出 HIT
CUR="$(awk 'END{print NR}' "${TR}")"
printf '%s\t%s' "${TR}" "${CUR}" > "${HOMED}/.compact_tr_lines_sessX"
assert_eq "$(has_400_signature "${TR}" "sessX" && echo HIT || echo MISS)"  "HIT"  "#3 important: append無し(/compact空振り)は marker無視で再検出 (永久マスク=stall防止)"
# E) marker が別path → 無視して全行 check (degrade=検出側) → 検出
printf '%s\t%s' "/some/other/path.jsonl" "999" > "${HOMED}/.compact_tr_lines_sessX"
assert_eq "$(has_400_signature "${TR}" "sessX" && echo HIT || echo MISS)"  "HIT"  "#3: 別path marker → 無視して全行check (degrade=検出側)"
# F) decide_action が sess を透過し、圧縮成功(成長有り)後は旧400で再圧縮しない (→ NONE)
TRF="$(mktemp)"
printf '%s\n' '{"isApiErrorMessage":true,"text":"API Error: 400"}' > "${TRF}"; printf 'a\nb\nc\nd\n' >> "${TRF}"   # 5行 line1=400
printf '%s\t%s' "${TRF}" "5" > "${HOMED}/.compact_tr_lines_sessF"
printf 'summary\nsummary\nsummary\n' >> "${TRF}"                                      # 8行 (成長)
assert_eq "$(decide_action compact 0 "${TRF}" "sessF")" "NONE" "#3: decide_action sess透過 (圧縮成功後 旧400抑止)"
rm -f "${TRF}"
# G) [nit fix] 末尾改行なしの旧400 + 成長 → awk NR 記録で正しく抑止 (wc -l の off-by-one を回避)。
#    tick は awk NR で記録するため、改行欠落の最終行も数え start が旧400 を正しく除外する (wc -l だと
#    1 少なく数え start が旧400 にかかり再含有してしまう)。
TR2="$(mktemp)"
printf 'x\n{"isApiErrorMessage":true,"text":"API Error: 400"}' > "${TR2}"             # 2行(line2=旧400,末尾改行なし) awk NR=2 / wc -l=1
NR2="$(awk 'END{print NR}' "${TR2}")"
assert_eq "${NR2}" "2" "末尾改行なし: awk NR は最終行も数える (=2, wc -l は 1)"
printf '%s\t%s' "${TR2}" "${NR2}" > "${HOMED}/.compact_tr_lines_sessZ"
printf '\nsummary\nsummary\n' >> "${TR2}"                                             # 成長 (line2 に改行付与+2行 → awk NR=4)
assert_eq "$(has_400_signature "${TR2}" "sessZ" && echo HIT || echo MISS)" "MISS" "#3 nit: 末尾改行なし旧400 も awk行数記録+成長で抑止 (wc -l off-by-one 回避)"
rm -f "${TR2}"
unset CC_COMPACTION_HOME; rm -rf "${HOMED}" "${TR}"

# G) [minor1] ctx_defer_bump は書込不能 (親dir無し) で return 1。tick の caller は『bump 成功時のみ
#    defer』にしているため、ctx_home 不可書込時は counter が進まず defer が無期限化 (=圧縮恒久ブロック=
#    stall方向) に倒れるのを防ぎ、圧縮側に倒す。
( CC_COMPACTION_HOME="/nonexistent-cc-home-$$/x" ctx_defer_bump sessW ) >/dev/null 2>&1 \
    && BUMPRC=OK || BUMPRC=FAIL
assert_eq "${BUMPRC}" "FAIL" "minor1: ctx_defer_bump は書込不能で return 1 (defer 無期限化=stall を防ぐ)"

rm -f "${EMPTY}"
report
