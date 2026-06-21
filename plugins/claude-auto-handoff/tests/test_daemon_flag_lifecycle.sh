#!/usr/bin/env bash
# daemon compacted フラグのライフサイクル — 送出『前』に立て、失敗時に clear する。
#
# 旧実装は inject 成功後 (= 圧縮コマンド送出の約12秒後) にフラグを立てたため、SessionStart が
# フラグを読む時点では未設定で、復元レース ＋ フラグ deadlock の両方を生んだ。本テストは
# 「send-keys が走る時点で compacted フラグが既に立っている」ことを tmux モックで観測し、
# 送出前設定を保証する (ordering の回帰テスト)。あわせて成功=維持 / 失敗=clear の終状態も固定。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"

# tmux mock: send-keys 時点での compacted フラグ有無を FLAG_AT_SEND に記録する。
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    if printf '%s\n' "$@" | grep -qF '#{pane_id}' && ! printf '%s\n' "$@" | grep -qF '#{pane_current_path}'; then
      printf '%s\n' "${PANE_IDS:-%9}"
    else
      echo "%9 /x node"
    fi
    ;;
  capture-pane) printf '%s' "${CAP:-idle prompt >}";;
  send-keys)
    # ★送出時点の compacted フラグ有無を記録 (ordering 検証の核)。最初の send-keys (圧縮コマンド本体) のみ。
    if [ -n "${FLAG_AT_SEND:-}" ] && [ ! -f "${FLAG_AT_SEND}.done" ]; then
      [ -e "${CC_COMPACTION_HOME}/.compacted_wt-a" ] && echo SET > "${FLAG_AT_SEND}" || echo UNSET > "${FLAG_AT_SEND}"
      : > "${FLAG_AT_SEND}.done"
    fi
    if [ "${SENDFAIL:-0}" = 1 ]; then exit 1; fi
    shift; echo "$*" >> "${TMUX_LOG}"
    ;;
esac
M
chmod +x "${TMOCK}/tmux"

mk() {  # <home> <band> <handoff:model> [pane]
    mkdir -p "$1/state" "$1/handoffs"
    python3 -c "import json,sys;json.dump({'session_id':'wt-a','band':sys.argv[2],'cwd':'/x','used_pct':0,'used_tokens':0,'window_size':0,'ts':'t','pane':sys.argv[3]},open(sys.argv[1]+'/state/wt-a.json','w'))" "$1" "$2" "${4:-%9}"
    printf 'model handoff body' > "$1/handoffs/wt-a.model.md"
}
run() {  # <home> [sendfail]
    export TMUX_LOG="$1/inject.log"; : > "${TMUX_LOG}"
    export FLAG_AT_SEND="$1/flag_at_send"; rm -f "${FLAG_AT_SEND}" "${FLAG_AT_SEND}.done"
    COOLDOWN_SECONDS=0 CAP="idle prompt >" SENDFAIL="${2:-0}" PANE_IDS="%9" \
        CLEAR_RESUME_DELAY_SECONDS=0 CLEAR_RESUME_MAX_WAIT_SECONDS=0 RESUME_REENTER_MAX=0 \
        RESUME_DELAY_SECONDS=0 RESUME_MAX_WAIT_SECONDS=0 \
        PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once >/dev/null 2>&1
}

# 1) [ordering 核心] 送出成功 → send-keys 時点で compacted が既に立っている (送出前設定の証拠)
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
run "${T}"
assert_eq "$(cat "${T}/flag_at_send" 2>/dev/null)" "SET" "compacted は圧縮コマンド送出『前』に立っている (ordering)"

# 2) 送出成功後も compacted は維持される (SessionStart の resume が後で reset する設計)
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "SET" "送出成功 → compacted 維持"

# 3) 送出失敗 → compacted は clear される (I2: 立てっぱなしは resume 待ちデッドロック)
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
run "${T}" 1
assert_eq "$(cat "${T}/flag_at_send" 2>/dev/null)" "SET" "失敗ケースでも送出試行時点ではフラグが立っている"
assert_eq "$([ -e "${T}/.compacted_wt-a" ] && echo SET || echo UNSET)" "UNSET" "送出失敗 → compacted を clear (deadlock 防止)"

# 4) [TTL 自己回復] stale compacted (TTL 超) + band 圧縮帯 → clear して再評価し圧縮を再送出する。
#    SessionStart 不達で inflight が恒久残留する沈黙劣化を防ぐ (デュアルレビュー must-fix)。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
: > "${T}/.compacted_wt-a"; touch -d '5 seconds ago' "${T}/.compacted_wt-a"
export TMUX_LOG="${T}/inject.log"; : > "${TMUX_LOG}"
COOLDOWN_SECONDS=0 CAP="idle prompt >" PANE_IDS="%9" COMPACTED_TTL_SECONDS=1 \
    RESUME_DELAY_SECONDS=0 RESUME_MAX_WAIT_SECONDS=0 RESUME_REENTER_MAX=0 \
    PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once >/dev/null 2>&1
assert_contains "$(cat "${TMUX_LOG}")" "/compact" "stale compacted (TTL超) + 圧縮帯 → clear して再評価し再送出"

# 5) [冪等] fresh compacted (TTL 内) + band 圧縮帯 → skip (二重圧縮しない・resume 待ちを潰さない)。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" critical model
: > "${T}/.compacted_wt-a"   # now (fresh)
export TMUX_LOG="${T}/inject.log"; : > "${TMUX_LOG}"
COOLDOWN_SECONDS=0 CAP="idle prompt >" PANE_IDS="%9" COMPACTED_TTL_SECONDS=600 \
    RESUME_DELAY_SECONDS=0 RESUME_MAX_WAIT_SECONDS=0 RESUME_REENTER_MAX=0 \
    PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once >/dev/null 2>&1
assert_eq "$(cat "${TMUX_LOG}")" "" "fresh compacted (TTL内) → skip (二重圧縮しない)"

# 6) [TTL 自己回復しない条件] stale compacted (TTL 超) だが band=idle (= 圧縮成功済) → skip。
#    圧縮が効いて band が idle に落ちている場合は再送出しない (空振りでないため)。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk "${T}" idle model
: > "${T}/.compacted_wt-a"; touch -d '5 seconds ago' "${T}/.compacted_wt-a"
export TMUX_LOG="${T}/inject.log"; : > "${TMUX_LOG}"
COOLDOWN_SECONDS=0 CAP="idle prompt >" PANE_IDS="%9" COMPACTED_TTL_SECONDS=1 \
    RESUME_DELAY_SECONDS=0 RESUME_MAX_WAIT_SECONDS=0 RESUME_REENTER_MAX=0 \
    PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once >/dev/null 2>&1
assert_eq "$(cat "${TMUX_LOG}")" "" "stale compacted + band=idle (圧縮成功) → 再送出しない"

rm -rf "${TMOCK}" "${T}"
report
