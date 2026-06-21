#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
MON="${HERE}/../hooks/ctx-monitor.sh"
TMP="$(mktemp -d)"; export CC_COMPACTION_HOME="${TMP}"

# state ファイルは coord slug でなく ctx_session_key (per-session ユニーク) で命名される。
# CLAUDE_SESSION_ID 設定時 key = <slug>-<uid 末尾8> (slug も uid も CLAUDE_SESSION_ID)。

# 1) 60%/1M → compact + episode stamp (非idle) + pane を state に記録
export CLAUDE_SESSION_ID="testsess"
export TMUX_PANE="%45"
KEY1="$(ctx_session_key /x)"
J='{"session_id":"testsess","workspace":{"current_dir":"/x"},"context_window":{"used_percentage":60,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":120000,"cache_creation_input_tokens":0}}'
printf '%s' "$J" | bash "${MON}"
STATE="${TMP}/state/${KEY1}.json"
assert_file_exists "${STATE}"
BAND="$(python3 -c "import json;print(json.load(open('${STATE}'))['band'])")"
assert_eq "${BAND}" "compact" "band=compact@60%"
assert_file_exists "${TMP}/.episode_${KEY1}"
# session_id フィールドには新キーが入る
SID_FIELD="$(python3 -c "import json;print(json.load(open('${STATE}'))['session_id'])")"
assert_eq "${SID_FIELD}" "${KEY1}" "session_id フィールド = ctx_session_key"
# pane フィールドが TMUX_PANE を記録
PANE_FIELD="$(python3 -c "import json;print(json.load(open('${STATE}'))['pane'])")"
assert_eq "${PANE_FIELD}" "%45" "pane フィールド = TMUX_PANE"

# 2) 30%/1M → idle (絶対トークン cap 撤去で早発火しない) + used_tokens は導出 (情報用) + episode reset
export CLAUDE_SESSION_ID="testsess2"
unset TMUX_PANE
KEY2="$(ctx_session_key /x)"
J2='{"session_id":"testsess2","workspace":{"current_dir":"/x"},"context_window":{"used_percentage":30,"context_window_size":1000000}}'
printf '%s' "$J2" | bash "${MON}"
STATE2="${TMP}/state/${KEY2}.json"
assert_file_exists "${STATE2}"
TOK2="$(python3 -c "import json;print(json.load(open('${STATE2}'))['used_tokens'])")"
assert_eq "${TOK2}" "300000" "used_tokens=pct×window 導出 (情報用)"
BAND2="$(python3 -c "import json;print(json.load(open('${STATE2}'))['band'])")"
assert_eq "${BAND2}" "idle" "30%→idle (%基準・cap 撤去)"
assert_eq "$([ -e "${TMP}/.episode_${KEY2}" ] && echo SET || echo UNSET)" "UNSET" "idle → episode stamp なし"
# pane フィールドは TMUX_PANE 未設定 → 空文字
PANE2="$(python3 -c "import json;print(json.load(open('${STATE2}'))['pane'])")"
assert_eq "${PANE2}" "" "TMUX_PANE 未設定 → pane=空"

# 3) 50% → prepare 帯
export CLAUDE_SESSION_ID="testsess3"
KEY3="$(ctx_session_key /x)"
J3='{"session_id":"testsess3","workspace":{"current_dir":"/x"},"context_window":{"used_percentage":50,"context_window_size":1000000}}'
printf '%s' "$J3" | bash "${MON}"
BAND3="$(python3 -c "import json;print(json.load(open('${TMP}/state/${KEY3}.json'))['band'])")"
assert_eq "${BAND3}" "prepare" "50%→prepare"

rm -rf "${TMP}"
report
