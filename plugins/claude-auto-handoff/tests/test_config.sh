#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
CONF="${HERE}/../hooks/auto_compaction.conf"
assert_file_exists "${CONF}"
# conf は `: "${VAR:=default}"` (env override 可) になったため、呼び出し元 env の汚染で既定値
# 検証が揺れないよう、source 前に対象キーを unset する (Codex 指摘の Minor)。
unset PREPARE_PCT COMPACT_PCT CRITICAL_PCT DEBOUNCE_SECONDS PREPARE_PROMPT_DEBOUNCE_SECONDS \
      DAEMON_INTERVAL_SECONDS COOLDOWN_SECONDS CLEAR_RESUME_DELAY_SECONDS CLEAR_RESUME_MAX_WAIT_SECONDS \
      RESUME_DELAY_SECONDS RESUME_MAX_WAIT_SECONDS COMPACTION_COMMAND COMPACTED_TTL_SECONDS COMPACT_DEFER_MAX \
      RESUME_REENTER_MAX RESUME_SETTLE_SECONDS RESUME_SUBMIT_INTERVAL STATE_FRESH_SECONDS \
      HANDOFF_RESTORE_FRESH_SECONDS \
      GC_STATE_DAYS GC_HANDOFF_DAYS GC_MARKER_DAYS GC_ARCHIVE_DAYS DEFAULT_WINDOW_TOKENS 2>/dev/null || true
# shellcheck disable=SC1090
. "${CONF}"
# 2段 cadence の %基準閾値
assert_eq "${PREPARE_PCT}" "50" "PREPARE_PCT"
assert_eq "${COMPACT_PCT}" "55" "COMPACT_PCT"
assert_eq "${CRITICAL_PCT}" "78" "CRITICAL_PCT"
assert_nonempty "${DEBOUNCE_SECONDS}" "DEBOUNCE_SECONDS"
assert_nonempty "${PREPARE_PROMPT_DEBOUNCE_SECONDS}" "PREPARE_PROMPT_DEBOUNCE_SECONDS"
assert_nonempty "${COOLDOWN_SECONDS}" "COOLDOWN_SECONDS"
assert_nonempty "${STATE_FRESH_SECONDS}" "STATE_FRESH_SECONDS"
assert_eq "${RESUME_DELAY_SECONDS}" "12" "RESUME_DELAY_SECONDS 既定 12 (大 context の圧縮リロード最低待機)"
# Part B: 圧縮完了 poll の上限 (/compact 要約は /clear より長めの 90) + 継続プロンプト自動送信の堅牢化パラメータ
assert_eq "${RESUME_MAX_WAIT_SECONDS}" "90" "RESUME_MAX_WAIT_SECONDS 既定 90"
assert_eq "${RESUME_REENTER_MAX}" "5" "RESUME_REENTER_MAX 既定 5 (取りこぼし追加 Enter の上限)"
assert_eq "${RESUME_SETTLE_SECONDS}" "2" "RESUME_SETTLE_SECONDS 既定 2 (テキスト送出→Enter の settle)"
assert_eq "${RESUME_SUBMIT_INTERVAL}" "2" "RESUME_SUBMIT_INTERVAL 既定 2 (追加 Enter の間隔)"
# 圧縮コマンド (既定 /compact) と compacted inflight TTL
assert_eq "${COMPACTION_COMMAND}" "/compact" "COMPACTION_COMMAND 既定 /compact"
assert_nonempty "${COMPACTED_TTL_SECONDS}" "COMPACTED_TTL_SECONDS"
# I1: /compact 送出前の入力欄 bounded defer の上限
assert_eq "${COMPACT_DEFER_MAX}" "9" "COMPACT_DEFER_MAX 既定 9 (I1 圧縮 defer の上限)"
# A2: 復元の鮮度ゲート
assert_eq "${HANDOFF_RESTORE_FRESH_SECONDS}" "1800" "HANDOFF_RESTORE_FRESH_SECONDS 既定 1800"
# A3: age GC 閾値
assert_nonempty "${GC_STATE_DAYS}" "GC_STATE_DAYS"
assert_nonempty "${GC_HANDOFF_DAYS}" "GC_HANDOFF_DAYS"
assert_nonempty "${GC_MARKER_DAYS}" "GC_MARKER_DAYS"
assert_nonempty "${GC_ARCHIVE_DAYS}" "GC_ARCHIVE_DAYS"
# 絶対トークン cap は撤去済み (%基準に統一)。binding な cap が残っていないこと。
assert_eq "${TRIGGER_TOKEN_CAP:-unset}" "unset" "TRIGGER_TOKEN_CAP 撤去"
assert_eq "${LOW_WATER_TOKEN_CAP:-unset}" "unset" "LOW_WATER_TOKEN_CAP 撤去"
# ★env override が source 後も保持される (`: "${VAR:=default}"` 形式の検証、Codex 指摘 #4)。
OV="$(HANDOFF_RESTORE_FRESH_SECONDS=7200 bash -c '. "$1"; printf "%s" "${HANDOFF_RESTORE_FRESH_SECONDS}"' _ "${CONF}")"
assert_eq "${OV}" "7200" "env override が conf source 後も保持される"
DEF="$(bash -c '. "$1"; printf "%s" "${HANDOFF_RESTORE_FRESH_SECONDS}"' _ "${CONF}")"
assert_eq "${DEF}" "1800" "env 未設定なら conf 既定 (1800) が入る"
# ★後方互換: 旧名 CLEAR_RESUME_* を env で渡すと新名 RESUME_* に伝播する (override 入力専用)。
BC1="$(CLEAR_RESUME_DELAY_SECONDS=7 bash -c '. "$1"; printf "%s" "${RESUME_DELAY_SECONDS}"' _ "${CONF}")"
assert_eq "${BC1}" "7" "旧名 CLEAR_RESUME_DELAY_SECONDS env → 新名 RESUME_DELAY_SECONDS に伝播"
BC2="$(CLEAR_RESUME_MAX_WAIT_SECONDS=45 bash -c '. "$1"; printf "%s" "${RESUME_MAX_WAIT_SECONDS}"' _ "${CONF}")"
assert_eq "${BC2}" "45" "旧名 CLEAR_RESUME_MAX_WAIT_SECONDS env → 新名 RESUME_MAX_WAIT_SECONDS に伝播"
# 新名 env override も保持される (assign-if-unset 形式の確認)
NV="$(RESUME_MAX_WAIT_SECONDS=120 bash -c '. "$1"; printf "%s" "${RESUME_MAX_WAIT_SECONDS}"' _ "${CONF}")"
assert_eq "${NV}" "120" "新名 RESUME_MAX_WAIT_SECONDS env override が保持される"
report
