#!/usr/bin/env bash
# 修正②: pane 再利用誤爆防止。
#  (A) ctx_pane_owner <state_dir> <pane>: 引数 pane を記録した state のうち最新 (mtime 最新)
#      のものの session_id を返す (= その pane の現住人)。
#  (B) tick(): 解決 pane の現住人が別セッションなら /clear しない (古い残骸 state を撃たない)。
# pane が別セッションに再利用された後に古い state が残ると、daemon が古い state の記録 pane を
# 撃ち現住人 (別セッション) を誤爆する。これを現住人突合で防ぐ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/_assert.sh"
. "${HERE}/../hooks/_ctx_common.sh"
DAEMON="${HERE}/../scripts/cc-compaction-daemon.sh"

# --- (A) ctx_pane_owner 単体 -------------------------------------------------
# state json を {session_id, pane} で生成、mtime を引数で制御。
mkstate() {  # <state_dir> <sess> <pane> <mtime_spec>
    mkdir -p "$1"
    python3 -c "import json,sys;json.dump({'session_id':sys.argv[2],'band':'compact','cwd':'/x','used_pct':0,'used_tokens':0,'window_size':0,'ts':'t','pane':sys.argv[3]},open(sys.argv[1]+'/'+sys.argv[2]+'.json','w'))" "$1" "$2" "$3"
    [ -n "${4:-}" ] && touch -d "$4" "$1/$2.json"
}

# 同一 pane %45 を 2 つの state (old=10 分前, new=now) が記録 → 現住人は new (sess-new)
# 既定 STATE_FRESH_SECONDS=180 では old(10分前) は鮮度フィルタで除外され、new のみが候補。
SD="$(mktemp -d)"
mkstate "${SD}" "sess-old" "%45" "10 minutes ago"
mkstate "${SD}" "sess-new" "%45" ""   # now
assert_eq "$(ctx_pane_owner "${SD}" "%45")" "sess-new" "現住人 = 同 pane を記録した最新 state"

# 別 pane (%99) を記録した state は無視される (pane フィルタ)
mkstate "${SD}" "sess-other" "%99" ""
assert_eq "$(ctx_pane_owner "${SD}" "%45")" "sess-new" "別 pane の state は現住人判定に混ざらない"

# 同名 pane が 1 つだけ → それを返す
SD2="$(mktemp -d)"
mkstate "${SD2}" "solo" "%12" ""
assert_eq "$(ctx_pane_owner "${SD2}" "%12")" "solo" "同名 pane が 1 つ → それを返す"

# 該当 pane を記録した state が皆無 → 空 (現住人不明)
assert_eq "$(ctx_pane_owner "${SD2}" "%88")" "" "記録 state 皆無 → 空"

# --- (I-1a) 鮮度フィルタ -----------------------------------------------------
# stale な残骸 state は owner 候補から除外する (STATE_FRESH_SECONDS, daemon の state_is_fresh
# と同基準)。古い state が pane の現住人を僭称し daemon が現住人突合を素通りするのを防ぐ。
# 全 stale → owner 空 / 鮮度窓を広げれば古いのも候補に戻る / fresh と stale 混在 → fresh のみ。

# 全 state が stale (10 分前) → 既定窓 (180s) では owner 空
SDF="$(mktemp -d)"
mkstate "${SDF}" "stale-only" "%45" "10 minutes ago"
assert_eq "$(STATE_FRESH_SECONDS=180 ctx_pane_owner "${SDF}" "%45")" "" "全 stale → owner 空 (鮮度窓外)"

# 鮮度窓を広げれば (1 時間) 古い state も候補に戻る
assert_eq "$(STATE_FRESH_SECONDS=3600 ctx_pane_owner "${SDF}" "%45")" "stale-only" "窓拡大 → 古い state も候補"

# fresh と stale 混在 → fresh のみで判定 (stale は鮮度で除外され fresh が残る)。
# stale を 10 分前、fresh を now にして同一 pane %45 を両方記録。
SDM="$(mktemp -d)"
mkstate "${SDM}" "stale-resident" "%45" "10 minutes ago"
mkstate "${SDM}" "fresh-resident" "%45" ""   # now
assert_eq "$(STATE_FRESH_SECONDS=180 ctx_pane_owner "${SDM}" "%45")" "fresh-resident" "fresh+stale 混在 → fresh のみで判定"

# 対象 pane %45 を記録するのが stale のみ (fresh は別 pane) → 鮮度フィルタで owner 空。
SDM2="$(mktemp -d)"
mkstate "${SDM2}" "stale-on-pane" "%45" "10 minutes ago"
mkstate "${SDM2}" "fresh-elsewhere" "%99" ""   # 別 pane、now
assert_eq "$(STATE_FRESH_SECONDS=180 ctx_pane_owner "${SDM2}" "%45")" "" "対象 pane は stale のみ → owner 空"

# --- (B) tick() の現住人突合 -------------------------------------------------
# tmux mock: 記録 pane を実在扱いし、cwd 突合は使わせない (pane 直接ターゲット経路)。
TMOCK="$(mktemp -d)"
cat > "${TMOCK}/tmux" <<'M'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    if printf '%s\n' "$@" | grep -qF '#{pane_id}' && ! printf '%s\n' "$@" | grep -qF '#{pane_current_path}'; then
      printf '%s\n' "${PANE_IDS:-%45}"
    else
      echo "%45 /x node"
    fi
    ;;
  capture-pane) printf '%s' "${CAP:-idle prompt >}";;
  send-keys)    shift; echo "$*" >> "${TMUX_LOG}";;
esac
M
chmod +x "${TMOCK}/tmux"
cat > "${TMOCK}/sleep" <<'M'
#!/usr/bin/env bash
:
M
chmod +x "${TMOCK}/sleep"

# 2 セッションが同一 pane %45 を記録。new=現住人、old=再利用前の古い残骸。
# 両 state を fresh (mtime now 付近) にしつつ、現住人は new。両方とも handoff を持たせ
# /clear 経路に到達させる (現住人突合だけが差を生む)。
mk_pair() {  # <home>
    mkdir -p "$1/state" "$1/handoffs"
    # old を 30 秒前 (fresh)、new を now にして mtime 差で現住人を new にする。
    # 両者を model.md 付き (NEW 厳格化: model.md 非空が /clear の前提) で /clear 経路に乗せる。
    python3 -c "import json;json.dump({'session_id':'sess-old','band':'critical','cwd':'/x','used_pct':0,'used_tokens':0,'window_size':0,'ts':'t','pane':'%45'},open('$1/state/sess-old.json','w'))"
    python3 -c "import json;json.dump({'session_id':'sess-new','band':'critical','cwd':'/x','used_pct':0,'used_tokens':0,'window_size':0,'ts':'t','pane':'%45'},open('$1/state/sess-new.json','w'))"
    printf 'model' > "$1/handoffs/sess-old.model.md"
    printf 'model' > "$1/handoffs/sess-new.model.md"
    touch -d "30 seconds ago" "$1/state/sess-old.json"   # fresh だが new より古い
    # new は now (touch 省略)
}
run_tick() {  # <home>
    export TMUX_LOG="$1/inject.log"; : > "${TMUX_LOG}"
    COOLDOWN_SECONDS=0 PANE_IDS="%45" PATH="${TMOCK}:${PATH}" bash "${DAEMON}" --once
    cat "${TMUX_LOG}"
}

# old state を処理 → 現住人 (sess-new) と不一致 → /clear しない。
# new state を処理 → 一致 → /clear する。両 state が同一 run にあるので、ログには
# new 経由の /clear のみが現れ、old 経由の余計な /clear は現れない (=計 1 回)。
T="$(mktemp -d)"; export CC_COMPACTION_HOME="${T}"; mk_pair "${T}"
OUT="$(run_tick "${T}")"
CLEARS="$(printf '%s\n' "${OUT}" | grep -cF '/compact Enter')"
assert_eq "${CLEARS}" "1" "同 pane を 2 state が記録 → 現住人 (new) の 1 回のみ圧縮 (/compact)"
# 現住人 sess-new だけ compacted が立ち、old は立たない (誤爆していない証拠)
assert_eq "$([ -e "${T}/.compacted_sess-new" ] && echo SET || echo UNSET)" "SET" "現住人 (new) は /clear 済"
assert_eq "$([ -e "${T}/.compacted_sess-old" ] && echo SET || echo UNSET)" "UNSET" "残骸 (old) は撃たれない (現住人不一致で skip)"

rm -rf "${SD}" "${SD2}" "${SDF}" "${SDM}" "${SDM2}" "${TMOCK}" "${T}"
report
