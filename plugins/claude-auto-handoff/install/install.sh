#!/usr/bin/env bash
# install.sh — claude-auto-handoff の常駐 daemon (systemd --user) を冪等にインストールし、
# statusLine 配線手順を案内する。
#
# hooks (SessionStart/PreCompact/Stop) は plugin インストールで自動配線される。本スクリプトは
# 追加の「常駐レール」= context % を監視して compact 帯で /compact を撃つ daemon を有効化する。
# daemon は tmux 必須 (send-keys で /compact を送るため)。
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="${PLUGIN_ROOT}/scripts/cc-compaction-daemon.sh"
[ -x "${DAEMON}" ] || { echo "ERROR: daemon が見つからない/実行不可: ${DAEMON}" >&2; exit 1; }

# 依存チェック (auto-trigger は tmux/python3/bash 必須。無くても hooks 経由の復元は動く)
miss=0
for c in tmux python3 bash; do
    command -v "$c" >/dev/null 2>&1 || { echo "WARN: '$c' が見つからない (daemon の auto-trigger に必要)"; miss=1; }
done

if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARN: systemctl が無いため daemon を systemd --user に登録できません。"
    echo "      手動起動する場合: CC_HANDOFF_DAEMON_ENABLED=true nohup bash '${DAEMON}' >/dev/null 2>&1 &"
    exit 0
fi

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "${UNIT_DIR}"
UNIT="${UNIT_DIR}/cc-handoff-daemon.service"
cat > "${UNIT}" <<EOF
[Unit]
Description=claude-auto-handoff compaction daemon (monitor context %% and trigger /compact with handoff restore)

[Service]
Type=simple
Environment=CC_HANDOFF_DAEMON_ENABLED=true
ExecStart=/usr/bin/env bash ${DAEMON}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
echo "installed systemd --user unit: ${UNIT}"

systemctl --user daemon-reload
if [ "${miss:-0}" = 1 ]; then
    echo "WARN: 依存 (tmux/python3/bash) が不足しているため daemon を enable しません。"
    echo "      依存を導入後: systemctl --user enable --now cc-handoff-daemon.service"
    exit 0
fi
systemctl --user enable --now cc-handoff-daemon.service
if systemctl --user is-active --quiet cc-handoff-daemon.service; then
    echo "✅ daemon active (PID $(systemctl --user show -p MainPID --value cc-handoff-daemon.service))"
else
    echo "WARN: daemon が active になりませんでした。'systemctl --user status cc-handoff-daemon.service' で確認してください。"
fi

cat <<GUIDE

=== 追加の手動配線: statusLine 委譲 (常駐 handoff レールの完全有効化) ===
hooks 経由の復元 (SessionStart) と PreCompact バックストップは plugin インストールで自動稼働します。
ただし「context % を常時監視し、prepare 帯 (既定 50%) で詳細 handoff を書き、compact 帯 (55%) で
/compact を撃つ」常駐レールは、context_window.used_percentage を持つ statusLine からの委譲が必要です。

~/.claude/settings.json の statusLine コマンドを、受け取った JSON を ctx-monitor.sh にも渡す形に
変更してください。例 (install/statusline-snippet.sh 参照):

  input="\$(cat)"
  printf '%s' "\$input" | '${PLUGIN_ROOT}/hooks/ctx-monitor.sh' >/dev/null 2>&1
  printf '%s' "\$input" | <あなたの既存 statusLine コマンド>

未配線でも SessionStart 復元と PreCompact バックストップは動作します (常駐 auto-trigger のみ無効)。

=== kill switch ===
  daemon 停止 : systemctl --user stop cc-handoff-daemon.service  または  touch ~/.claude/auto-compaction/DISABLED
  機能無効化  : 環境変数 CC_HANDOFF_ENABLED=off
  /clear へ切替: 環境変数 COMPACTION_COMMAND=/clear (1M で /compact が不発の場合)
GUIDE
