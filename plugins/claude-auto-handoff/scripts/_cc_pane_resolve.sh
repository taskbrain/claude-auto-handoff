#!/usr/bin/env bash
# _cc_pane_resolve.sh — session の cwd から tmux pane を解決 (source 専用)。
# per-session の特定ペインへ注入するのが目的なので、全ペインをコマンド名で走査する方式ではなく
# pane_current_path (cwd) 突合でペインを特定する (session_id→特定 cwd の 1:1 対応)。
resolve_pane_by_cwd() {
    local target="$1"
    command -v tmux >/dev/null 2>&1 || return 0
    # cwd 一致のうち claude REPL ペインを優先 (I1: 同一 cwd に shell ペインが並ぶと別ペインに
    # /clear を誤爆するため)。command 一致が無ければ最初の cwd 一致に degrade。
    # ★claude 判定: node/claude/claude-code に加え cc/bun ランチャ、および native installer が
    #   #{pane_current_command} に返す versioned バイナリ (例 "2.1.161") を `^[0-9]+\.[0-9]+\.[0-9]+`
    #   で救済する。これを欠くと native-install 構成で claude pane が version 文字列を名乗り優先されず、
    #   先頭の非 claude pane (bash) に fallback して圧縮コマンドを誤爆 = その session が圧縮されない。
    tmux list-panes -a -F '#{pane_id} #{pane_current_path} #{pane_current_command}' 2>/dev/null \
        | awk -v t="${target}" '
            $2==t {
                if (fb=="") fb=$1
                if ($3 ~ /^(node|claude|claude-code|cc|bun)$/ || $3 ~ /^[0-9]+\.[0-9]+\.[0-9]+/) { print $1; found=1; exit }
            }
            END { if (!found && fb!="") print fb }'
}

# _capture_pane <pane> → ペインの可視内容を stdout に出す (テストで override 可能)。
_capture_pane() {
    command -v tmux >/dev/null 2>&1 || return 1
    tmux capture-pane -p -t "$1" 2>/dev/null
}

# pane_is_idle <pane> → 0(idle=注入可) / 1(busy または不明=注入しない)。
# Claude Code REPL は生成中に busy を示す: tool/stream 中は "esc to interrupt"、生成スピナーは
# "✶ Doing… (5s · thinking)" 等の『… (Ns · …)』タイマ (実機 capture で確認: thinking 中は
# esc to interrupt が出ずスピナータイマのみのことがある → esc 単独検出では false idle になり、
# 圧縮完了待ち poll が早期離脱しテキスト未着地を招く = Codex Important)。両者を busy とみなす。
# ★スピナーは Claude のステータス行形式 "…WORD (Ns · …)" に限定 (`… \([0-9]+s ·`): 省略記号 "…" +
#   タイマ括弧 "(Ns" + 中黒 "·" の 3 点を要求する。アンカーが緩いと通常応答テキストを busy 誤検出し、
#   その行が可視末尾に残る間 idle pane を永久 busy 化して圧縮を止める (Codex Important): `(Ns · ` 単独 →
#   "benchmark (5s · completed)" 誤検出 / `… (Ns` のみ → "Doing… (5s later)" 誤検出。中黒まで要求すれば
#   どちらも除外され、実機スピナー "(Ns · thinking)" だけが残る。
# ★scrollback 履歴に同種文字列が残っても誤検出しないよう live ステータス域 = 末尾 18 行に限定する。
# capture 失敗・空は「不明」→ 安全側で busy 扱い (turn 中の誤注入を避ける)。
pane_is_idle() {
    local pane="$1"; [ -n "${pane}" ] || return 1
    local cap; cap="$(_capture_pane "${pane}" 2>/dev/null || true)"
    [ -n "${cap}" ] || return 1
    local tail_area; tail_area="$(printf '%s' "${cap}" | tail -18)"
    printf '%s' "${tail_area}" | grep -qiE 'esc to interrupt|… \([0-9]+s ·' && return 1
    return 0
}
