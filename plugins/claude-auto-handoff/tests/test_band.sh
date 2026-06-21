#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
# classify_band <used_pct> [used_tokens]  → idle|prepare|compact|critical
# 2段 cadence: %基準のみ (絶対トークン cap は撤去)。第2引数は後方互換で受容するが band に影響しない。
assert_eq "$(classify_band 10)"  "idle"     "10%"
assert_eq "$(classify_band 49)"  "idle"     "49% (prepare 直前)"
assert_eq "$(classify_band 50)"  "prepare"  "50% (準備帯下限)"
assert_eq "$(classify_band 54)"  "prepare"  "54% (準備帯)"
assert_eq "$(classify_band 55)"  "compact"  "55% (圧縮帯下限)"
assert_eq "$(classify_band 77)"  "compact"  "77% (圧縮帯)"
assert_eq "$(classify_band 78)"  "critical" "78% (critical 天井)"
assert_eq "$(classify_band 95)"  "critical" "95%"
# 第2引数 (tok) は %基準では無視される (1M 窓で 20%/900k は idle のまま)
assert_eq "$(classify_band 20 900000)" "idle"    "tok 無視 (pct基準)"
assert_eq "$(classify_band 51 0)"      "prepare" "tok=0 でも pct で判定"
# 端値・空入力堅牢性
assert_eq "$(classify_band 50.9)" "prepare"  "小数 pct は切り捨て"
assert_eq "$(classify_band '')"   "idle"     "空 pct → idle"
report
