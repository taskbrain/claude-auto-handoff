#!/usr/bin/env bash
# statusline-snippet.sh — claude-auto-handoff の常駐レールを有効化する statusLine の例。
#
# Claude Code の statusLine コマンドは stdin で JSON (context_window.used_percentage を含む) を受け取り、
# stdout に1行のステータス文字列を出す。hook は token 量を受け取れず statusLine だけが used_percentage を
# 持つため、ctx-monitor.sh (per-session state を書く副作用のみ) は statusLine から委譲する必要がある。
#
# 使い方: ~/.claude/settings.json の statusLine.command をこのスクリプト (CC_HANDOFF_PLUGIN_ROOT を
# あなたのプラグイン絶対パスに設定) に向けるか、下記2行をあなたの既存 statusLine に組み込む。
set -u

# ★あなたのプラグイン絶対パスに合わせて設定 (例: ~/.claude/plugins/.../claude-auto-handoff)
CC_HANDOFF_PLUGIN_ROOT="${CC_HANDOFF_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/claude-auto-handoff/plugins/claude-auto-handoff}"

input="$(cat)"

# 副作用: 同じ JSON を ctx-monitor.sh に渡し per-session state を更新する (daemon の監視材料)。
# 失敗は握り潰す (statusLine を壊さない)。
printf '%s' "${input}" | "${CC_HANDOFF_PLUGIN_ROOT}/hooks/ctx-monitor.sh" >/dev/null 2>&1 || true

# --- ここから下はあなたの既存ステータス行の描画に置き換える ---
# 例: context % を表示するだけの最小ステータス。実際にはあなたの好きな statusLine を使ってください。
printf '%s' "${input}" | python3 -c '
import json,sys
try: p=json.load(sys.stdin)
except Exception: p={}
pct=(p.get("context_window",{}) or {}).get("used_percentage")
model=(p.get("model",{}) or {}).get("display_name","")
print(f"{model}  ctx {pct if pct is not None else 0}%")
' 2>/dev/null || printf 'claude'
