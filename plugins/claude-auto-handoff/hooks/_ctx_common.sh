#!/usr/bin/env bash
# _ctx_common.sh — auto-compaction handoff hook 群の共有ヘルパ (source 専用)。
# 依存: python3 (stdlib only)。外部依存なし (standalone)。
_CTX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# config ロード (KEY=VALUE を source)
# shellcheck disable=SC1091
[ -f "${_CTX_DIR}/auto_compaction.conf" ] && . "${_CTX_DIR}/auto_compaction.conf"

# cch_session_slug <cwd> → セッションの基底 slug を解決する。
# 解決順: CLAUDE_SESSION_ID (明示 override) > git branch 名 (slash→dash) > リポ basename >
# "unknown-session"。1 セッション = 1 branch 前提で安定した id になる。
cch_session_slug() {
    local ref_dir="${1:-$PWD}"
    if [ -n "${CLAUDE_SESSION_ID:-}" ]; then printf '%s' "${CLAUDE_SESSION_ID}"; return 0; fi
    local br; br="$(git -C "${ref_dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "${br}" ] && [ "${br}" != "HEAD" ]; then printf '%s' "${br//\//-}"; return 0; fi
    local top; top="$(git -C "${ref_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "${top}" ]; then printf '%s' "$(basename "${top}")"; return 0; fi
    printf '%s' "unknown-session"
}

# ctx_session_key <cwd> → state/handoff/flag キー専用の per-session キー。
# cch_session_slug (基底 slug) とは別物。複数 Claude セッションが同一 slug (例 branch 名) に
# 解決し state/handoff/flag を共有・上書き衝突するのを防ぐため、slug を前置しつつ
# per-session suffix を付ける。
#   - ★suffix は TMUX_PANE (例 %45) 由来の -p<N> を最優先する。pane は同一端末で /clear を
#     跨いで不変かつ並行セッション間で一意なため、/clear 後の SessionStart 復元
#     (compaction-resume) が /clear 前に書いた handoff を確実に同一キーで読める。
#   - ★CLAUDE_CODE_SESSION_ID (= 会話 UUID = transcript ディレクトリ名) は suffix に使わない。
#     /clear は新しい会話を開始し新 UUID を発行するため suffix が /clear で変わり、書込キー
#     ≠ 読込キーで handoff が永遠に見つからない (旧実装のバグ)。CLAUDE_SESSION_ID は
#     cch_session_slug 経由で slug 側にのみ反映される (明示 override 用、通常未設定)。
#   - TMUX_PANE 無し (非 tmux) は制御端末 (tty) を suffix に使う (slug-tty<dev>)。tty も /clear を
#     跨いで不変かつ端末ごとに一意なので、co-located 同一 slug の複数非 tmux セッションが
#     state/handoff/flag を共有し別セッションの handoff を誤注入するのを防ぐ。
#   - tty も取れない (バッチ/非対話) ときのみ slug 単独 (degrade)。daemon は tmux 必須なので
#     非 tmux では auto-restore (daemon /clear) 自体が成立せず、残るは手動 /compact のみ。
ctx_session_key() {
    local cwd="${1:-$PWD}" slug tty
    slug="$(cch_session_slug "${cwd}")"
    if [ -n "${TMUX_PANE:-}" ]; then printf '%s-p%s' "${slug}" "${TMUX_PANE#%}"; return 0; fi
    tty="$(ps -o tty= -p "$$" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "${tty}" ] && [ "${tty}" != "?" ]; then printf '%s-tty%s' "${slug}" "${tty//\//-}"; return 0; fi
    printf '%s' "${slug}"
}

# state/handoff ルート (テストで上書き可能)
ctx_home() { printf '%s' "${CC_COMPACTION_HOME:-${HOME}/.claude/auto-compaction}"; }
ctx_state_dir()   { printf '%s' "$(ctx_home)/state"; }
ctx_handoff_dir() { printf '%s' "$(ctx_home)/handoffs"; }
ctx_archive_dir() { printf '%s' "$(ctx_home)/archive"; }
ctx_ensure_dirs() { mkdir -p "$(ctx_state_dir)" "$(ctx_handoff_dir)" "$(ctx_archive_dir)" 2>/dev/null || true; }

# ctx_write_state <sess> <pct> <tok> <win> <band> <cwd> <ts> <pane>
# per-session state json を書く単一 writer。ctx-monitor (statusLine 由来) と
# compaction-resume (SessionStart 自記録) が共有しフォーマットの重複を排除する。
# フォーマットは従来 ctx-monitor の inline writer と完全同一。
ctx_write_state() {
    python3 - "$(ctx_state_dir)/${1}.json" "$1" "${2:-0}" "${3:-0}" "${4:-0}" "${5:-idle}" "${6:-}" "${7:-}" "${8:-}" <<'PY' 2>/dev/null || true
import json,sys
path,sess,pct,tok,win,band,cwd,ts,pane=sys.argv[1:10]
json.dump({"session_id":sess,"used_pct":float(pct),"used_tokens":int(tok),
           "window_size":int(win),"band":band,"cwd":cwd,"ts":ts,"pane":pane},
          open(path,"w"))
PY
}

# classify_band <used_pct> [used_tokens(無視)] → idle|prepare|compact|critical
# 2段 cadence: 画面% 基準のみ。第2引数 (tok) は後方互換で受容するが band 判定に使わない
# (絶対トークン cap は撤去 — 1M 窓で早発火し %cadence と衝突したため)。
classify_band() {
    local pct="${1:-0}"
    pct=${pct%.*}
    [ -z "${pct}" ] && pct=0
    case "${pct}" in *[!0-9]*) pct=0 ;; esac   # 非数値 (負号等) は 0 扱い
    if [ "${pct}" -ge "${CRITICAL_PCT:-78}" ]; then echo "critical"; return; fi
    if [ "${pct}" -ge "${COMPACT_PCT:-55}" ];  then echo "compact";  return; fi
    if [ "${pct}" -ge "${PREPARE_PCT:-50}" ];  then echo "prepare";  return; fi
    echo "idle"
}

# debounce: <op-name> → 0(実行可) / 1(skip)。DEBOUNCE_SECONDS 窓。
ctx_debounce_ok() {
    local op="$1" mark; mark="$(ctx_home)/.last_${op}"
    mkdir -p "$(ctx_home)" 2>/dev/null || true
    local now last; now="$(date +%s)"
    last="$(cat "${mark}" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "${DEBOUNCE_SECONDS:-60}" ]; then return 1; fi
    echo "${now}" > "${mark}" 2>/dev/null || true
    return 0
}

# generic debounce with explicit window: <op-name> <window-sec> → 0(可) / 1(skip)。
ctx_debounce_ok_window() {
    local op="$1" win="${2:-60}" mark; mark="$(ctx_home)/.last_${op}"
    mkdir -p "$(ctx_home)" 2>/dev/null || true
    local now last; now="$(date +%s)"
    last="$(cat "${mark}" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "${win}" ]; then return 1; fi
    echo "${now}" > "${mark}" 2>/dev/null || true
    return 0
}

# ctx_file_has_text <file> → 0(strip 後に非空テキストあり) / 1(不在・空・空白/改行のみ)。
# [ -s ] (サイズ>0) は空白/改行のみを非空と誤判定するため、handoff 本文の実在判定はこちらを使う。
ctx_file_has_text() {
    local fp="$1"
    [ -f "${fp}" ] || return 1
    python3 - "${fp}" <<'PYEOF' 2>/dev/null
import sys
try:
    data = open(sys.argv[1], errors="replace").read()
except OSError:
    sys.exit(1)
sys.exit(0 if data.strip() else 1)
PYEOF
}

# ctx_file_has_fresh_text <file> <max_secs> → 0(strip後に非空テキスト ∧ mtime が max_secs 以内)。
# /clear 復元の鮮度ゲート用。pane 基軸キーは同一 pane の順次別セッション間で共有されうるため、
# 古い (= 死んだ占有者の) handoff を本文有りと見なして誤復元しないよう、本文存在に加え鮮度も見る。
ctx_file_has_fresh_text() {
    local fp="$1" max="${2:-1800}" now m
    ctx_file_has_text "${fp}" || return 1
    # mtime / now が読めない (stat/date 失敗) ときは鮮度判定不能。本文は実在するので、
    # 主目的 (handoff を失わない) を優先し復元側 (return 0=fresh) に倒す。0 握り潰しで
    # 巨大差→誤 stale 判定する旧形は避ける。
    m="$(stat -c %Y "${fp}" 2>/dev/null)"; [ -n "${m}" ] || return 0
    now="$(date +%s 2>/dev/null)"; [ -n "${now}" ] || return 0
    [ $((now - m)) -le "${max}" ]
}

# ctx_handoff_next_steps_thin <handoff_file> [min_chars] → 0(NEXT STEPS 節が薄い = 追加ガイダンス対象) /
#   1(十分 / 見出し不在 / ファイル不在)。Stage3 復元 (compaction-resume) が、NEXT STEPS が薄い handoff
#   で復帰後の最初の turn が漠然となるのを防ぐ補強ガイダンス材料。★warn-only: 圧縮も復元も止めない
#   純テキスト判定 (副作用なし・stall risk ゼロ)。閾値 conf: NEXT_STEPS_MIN_CHARS (既定 40)。
ctx_handoff_next_steps_thin() {
    local fp="$1" minchars="${2:-${NEXT_STEPS_MIN_CHARS:-40}}"
    [ -f "${fp}" ] || return 1
    NS_MIN="${minchars}" python3 - "${fp}" <<'PY' 2>/dev/null
import os, re, sys
ns_raw = os.environ.get("NS_MIN", "40")
if not ns_raw.lstrip("+-").isdigit():
    sys.exit(1)
minc = int(ns_raw)
try:
    lines = open(sys.argv[1], errors="replace").read().splitlines()
except OSError:
    sys.exit(1)
head_like = re.compile(r'^\s*(#{1,6}\s|\d+\s*[.)]\s)')
start = None
for i, l in enumerate(lines):
    if "NEXT STEPS" in l.upper() and head_like.match(l):
        start = i + 1
        break
if start is None:
    sys.exit(1)
hdr = re.compile(r'^\s*(#{1,6}\s|-{3,}\s*$|={3,}\s*$)')
body = []
for l in lines[start:]:
    if hdr.match(l):
        break
    body.append(l)
text = "".join("".join(body).split())
sys.exit(0 if len(text) < minc else 1)
PY
}


# --- 2段 cadence 状態フラグ (マーカーファイル) ---------------------------------
# フラグ実体は ctx_home()/.<name>_<sess>。set/clear/isset の最小 API。
ctx_flag_path()  { printf '%s' "$(ctx_home)/.${1}_${2}"; }
ctx_flag_set()   { mkdir -p "$(ctx_home)" 2>/dev/null || true; : > "$(ctx_flag_path "$1" "$2")" 2>/dev/null || true; }
ctx_flag_clear() { rm -f "$(ctx_flag_path "$1" "$2")" 2>/dev/null || true; }
ctx_flag_isset() { [ -e "$(ctx_flag_path "$1" "$2")" ]; }

# ctx_flag_stale <name> <sess> <ttl_secs> → 0(フラグが存在し mtime が ttl より古い) / 1(不在/新しい)。
# daemon の compacted inflight marker が SessionStart 不達で恒久残留するのを TTL 回復するため。
ctx_flag_stale() {
    local fp m now; fp="$(ctx_flag_path "$1" "$2")"
    [ -e "${fp}" ] || return 1
    m="$(stat -c %Y "${fp}" 2>/dev/null)"; [ -n "${m}" ] || return 1
    now="$(date +%s 2>/dev/null)"; [ -n "${now}" ] || return 1
    [ $((now - m)) -gt "${3:-600}" ]
}

# --- generation marker (pane 再利用時の誤復元防止) ------------------------------
# pane 基軸キー (slug-p<N>) は同一 pane を順次使う別セッション間で共有される。前占有者が書いた
# fresh handoff が残っていると、新占有者の手動 /clear/compact で旧作業が誤復元されうる (鮮度
# ゲートは「30分以内の pane 再利用」を防げない)。SessionStart(startup|resume) = 新プロセス起動で
# generation marker (.gen_<sess>) を touch し、復元は handoff.mtime >= gen.mtime を要求することで
# 「現世代 (この startup 以降) に書かれた handoff」だけを復元対象にする。同一プロセス内の /clear や
# /compact は startup を発火しないため gen は据え置かれ、自分の handoff は常に復元される。
ctx_generation_path()  { printf '%s' "$(ctx_home)/.gen_${1}"; }
ctx_generation_stamp() { mkdir -p "$(ctx_home)" 2>/dev/null || true; : > "$(ctx_generation_path "$1")" 2>/dev/null || true; }
# ctx_handoff_after_generation <handoff_file> <sess> → 0(現世代 = 復元可) / 1(前世代 = 復元不可)。
# generation marker が無ければ世代境界なしとみなし 0 (後方互換: 従来どおり復元)。stat 失敗時も
# 0 (handoff を失わない側に倒す。鮮度ゲートと同方針)。
# ★既知の境界 (dual-review nit, fix-now でない): 比較は秒粒度 mtime の `-ge` (同値=復元可)。これは
#   「自分の fresh handoff を必ず復元する」安全側 (未送信/文脈喪失を避ける) の意図的選択で、`-gt` は
#   同一秒に書かれた自分の handoff を under-restore し stall 側に倒れるため採らない。代償として、別
#   セッションが同一 pane を『同一 Unix 秒』内に再利用し前占有者 handoff.mtime と新世代 gen.mtime が
#   同秒に揃う極稀ケースで前占有者 handoff を誤復元しうる (= 文脈汚染。stall ではない)。sub-second
#   比較や provenance 照合で塞げるが、現行 -ge は安全原則 (復元優先) と整合した妥当な選択のため維持。
ctx_handoff_after_generation() {
    local fp="$1" sess="$2" gen hm gm
    gen="$(ctx_generation_path "${sess}")"
    [ -e "${gen}" ] || return 0
    hm="$(stat -c %Y "${fp}" 2>/dev/null)"; [ -n "${hm}" ] || return 0
    gm="$(stat -c %Y "${gen}" 2>/dev/null)"; [ -n "${gm}" ] || return 0
    [ "${hm}" -ge "${gm}" ]
}

# episode stamp: idle→非idle 立ち上がりで touch、idle 落ち/resume で clear。
# prepared 判定 (model.md 鮮度) の基準時刻。冪等 (既存なら維持し climb 跨ぎで不変)。
ctx_episode_path()  { printf '%s' "$(ctx_home)/.episode_${1}"; }
ctx_episode_stamp() {
    mkdir -p "$(ctx_home)" 2>/dev/null || true
    [ -e "$(ctx_episode_path "$1")" ] || : > "$(ctx_episode_path "$1")" 2>/dev/null || true
}
ctx_episode_clear() { rm -f "$(ctx_episode_path "$1")" 2>/dev/null || true; }

# prepared-for-episode: モデル自筆 handoff (model.md) が当 episode で更新済みか。
# model.md が存在し非空 ∧ (episode stamp 不在 OR model.md が stamp より新しい) → prepared(0)。
ctx_prepared_for_episode() {
    local sess="$1" mf ef
    mf="$(ctx_handoff_dir)/${sess}.model.md"
    ef="$(ctx_episode_path "${sess}")"
    # 空白/改行のみの model.md は「準備済」とみなさない (daemon の /clear ガードと統一)。
    ctx_file_has_text "${mf}" || return 1
    [ -e "${ef}" ] || return 0
    [ "${mf}" -nt "${ef}" ] && return 0 || return 1
}

# compact defer counter (I1): /compact 送出前に入力欄へユーザーの下書きがある間、圧縮を bounded で
# defer する連続回数。box false-positive 等で圧縮が恒久ブロック (=overflow=stall方向) に倒れるのを
# 防ぐため上限 (COMPACT_DEFER_MAX) を設け、超過したら下書きを犠牲に圧縮する。非数値/不在は 0 扱い。
ctx_defer_path()  { printf '%s' "$(ctx_home)/.compact_defer_${1}"; }
ctx_defer_get()   { local v; v="$(cat "$(ctx_defer_path "$1")" 2>/dev/null || echo 0)"; case "${v}" in ''|*[!0-9]*) echo 0 ;; *) echo "${v}" ;; esac; }
# ctx_defer_bump <sess> → counter を +1 して永続化し新値を stdout。★書込に失敗したら return 1
#   (echo しない)。caller は『書込成功時のみ defer』にし、ctx_home 不可書込で counter が進まず defer が
#   無期限化 (=圧縮恒久ブロック=stall方向) に倒れるのを防ぐ (書込不能なら圧縮側に倒す)。
ctx_defer_bump()  { local n; n=$(( $(ctx_defer_get "$1") + 1 )); printf '%s' "${n}" > "$(ctx_defer_path "$1")" 2>/dev/null || return 1; printf '%s' "${n}"; }
ctx_defer_clear() { rm -f "$(ctx_defer_path "$1")" 2>/dev/null || true; }

# episode 終了時の全フラグ reset (resume / idle 落ちで使用)。model.md は iterative
# update 用に保持し、episode stamp / compacted / prepare_prompted / compact_defer のみ消す。
ctx_episode_reset() {
    local sess="$1"
    ctx_episode_clear "${sess}"
    ctx_flag_clear compacted "${sess}"
    ctx_flag_clear prepare_prompted "${sess}"
    ctx_defer_clear "${sess}"
}

# ctx_pane_owner <state_dir> <pane> → 引数 pane を記録した state/*.json のうち最新 (mtime
# 最新) のものの session_id を stdout に返す (= その pane の「現住人」)。該当 state が皆無
# なら空。pane が別セッションに再利用された後に古い state が残ると daemon が記録 pane を撃ち
# 現住人 (別セッション) を誤爆する — その判定材料 (daemon の tick が突合に使う)。
# 同名 pane が 1 つならそれを返す。mtime 同着は走査順で最後に勝った 1 つ (決定論性は不要)。
# ★鮮度フィルタ: STATE_FRESH_SECONDS (既定 180s, daemon の state_is_fresh と同基準) より
#   古い state は owner 候補から除外する。stale な残骸 state が pane の現住人を僭称し、daemon の
#   現住人突合 (別セッションなら /clear skip) を素通りして誤爆させるのを防ぐ。fresh 候補が
#   皆無なら空を返す。
ctx_pane_owner() {
    local sdir="$1" pane="$2"
    [ -n "${pane}" ] || return 0
    [ -d "${sdir}" ] || return 0
    STATE_FRESH_SECONDS="${STATE_FRESH_SECONDS:-180}" python3 - "${sdir}" "${pane}" <<'PY' 2>/dev/null || true
import glob, json, os, sys, time
sdir, pane = sys.argv[1], sys.argv[2]
fresh_secs = float(os.environ.get("STATE_FRESH_SECONDS", "180"))
now = time.time()
best_sess, best_mtime = "", -1.0
for fp in glob.glob(os.path.join(sdir, "*.json")):
    try:
        m = os.path.getmtime(fp)
    except OSError:
        continue
    # 鮮度フィルタ: stale な残骸 state は現住人候補から除外 (daemon の state_is_fresh と同基準)
    if now - m > fresh_secs:
        continue
    try:
        d = json.load(open(fp))
    except Exception:
        continue
    if d.get("pane", "") != pane:
        continue
    if m >= best_mtime:
        best_mtime = m
        best_sess = str(d.get("session_id", ""))
if best_sess:
    print(best_sess)
PY
}

# ctx_gc — age ベースの孤立ファイル GC。state/handoff/marker/archive を mtime 閾値 (日) で削除。
# pane 基軸キーへの移行で旧 UUID キーのファイルが孤立する + そもそも age GC が無く蓄積する
# ため。冪等 (find -mtime +N -delete)・race 許容 (|| true)。DISABLED kill switch は age に
# 関わらず絶対に削除しない。kill switch: CC_HANDOFF_GC=off。
# 閾値 conf: GC_STATE_DAYS(1) / GC_HANDOFF_DAYS(7) / GC_MARKER_DAYS(1) / GC_ARCHIVE_DAYS(14)。
ctx_gc() {
    [ "${CC_HANDOFF_GC:-on}" = "off" ] && return 0
    local home; home="$(ctx_home)"
    [ -d "${home}" ] || return 0
    local sdays="${GC_STATE_DAYS:-1}" hdays="${GC_HANDOFF_DAYS:-7}"
    local mdays="${GC_MARKER_DAYS:-1}" adays="${GC_ARCHIVE_DAYS:-14}"
    # state json (live state は毎ターン更新されるため、古い = 終了済セッションの残骸)
    find "$(ctx_state_dir)" -maxdepth 1 -type f -name '*.json' -mtime +"${sdays}" -delete 2>/dev/null || true
    # handoff (model 自筆 + 機械版)。archive にコピーが残るため本体は積極 age out 可。
    find "$(ctx_handoff_dir)" -maxdepth 1 -type f -name '*.md' -mtime +"${hdays}" -delete 2>/dev/null || true
    # archive (debug 履歴。最も件数が嵩むため最も積極的に age out)。
    find "$(ctx_archive_dir)" -maxdepth 1 -type f -name '*.md' -mtime +"${adays}" -delete 2>/dev/null || true
    # dot-marker (compacted/episode/prepare_prompted/last_*/lastinject_*)。
    # DISABLED は kill switch なので age に関わらず除外 (パターン非該当だが防御的に明示)。
    # .last_gc は GC 自身の debounce マーカー: 自己削除すると日次 cadence が乱れるため除外。
    find "${home}" -maxdepth 1 -type f ! -name 'DISABLED' ! -name '.last_gc' \
        \( -name '.compacted_*' -o -name '.episode_*' -o -name '.prepare_prompted_*' -o -name '.last_*' -o -name '.lastinject_*' -o -name '.gen_*' -o -name '.compact_defer_*' -o -name '.compact_tr_lines_*' \) \
        -mtime +"${mdays}" -delete 2>/dev/null || true
}
