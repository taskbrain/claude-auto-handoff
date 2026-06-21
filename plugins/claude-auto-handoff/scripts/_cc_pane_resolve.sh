#!/usr/bin/env bash
# _cc_pane_resolve.sh — session の cwd から tmux pane を解決 (source 専用)。
# per-session の特定ペインへ注入するのが目的なので、全ペインをコマンド名で走査する方式ではなく
# pane_current_path (cwd) 突合でペインを特定する (session_id→特定 cwd の 1:1 対応)。
resolve_pane_by_cwd() {
    local target="$1"
    command -v tmux >/dev/null 2>&1 || return 0
    # cwd 一致のうち claude REPL (node/claude) ペインを優先 (I1: 同一 cwd に shell ペインが
    # 並ぶと別ペインに /clear を誤爆するため)。command 一致が無ければ最初の cwd 一致に degrade。
    tmux list-panes -a -F '#{pane_id} #{pane_current_path} #{pane_current_command}' 2>/dev/null \
        | awk -v t="${target}" '
            $2==t {
                if (fb=="") fb=$1
                if ($3 ~ /^(node|claude|claude-code)$/) { print $1; found=1; exit }
            }
            END { if (!found && fb!="") print fb }'
}

# _capture_pane <pane> → ペインの可視内容を stdout に出す (テストで override 可能)。
_capture_pane() {
    command -v tmux >/dev/null 2>&1 || return 1
    tmux capture-pane -p -t "$1" 2>/dev/null
}

# pane_is_idle <pane> → 0(idle=注入可) / 1(busy または不明=注入しない)。
# Claude Code REPL は生成中に "esc to interrupt" を表示する。これが見えれば busy。
# capture 失敗・空は「不明」→ 安全側で busy 扱い (turn 中の誤注入を避ける)。
pane_is_idle() {
    local pane="$1"; [ -n "${pane}" ] || return 1
    local cap; cap="$(_capture_pane "${pane}" 2>/dev/null || true)"
    [ -n "${cap}" ] || return 1
    printf '%s' "${cap}" | grep -qiE 'esc to interrupt' && return 1
    return 0
}
