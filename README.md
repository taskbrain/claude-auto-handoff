# claude-auto-handoff

**Claude Code の自動コンパクション handoff + 確実な復元** — 長時間セッションで文脈が圧縮 (`/compact` / `/clear`) されても作業の続きを失わないプラグイン & marketplace。

文脈が賢いうちに 8 セクションの詳細 handoff を先回りで書き、圧縮直後の `SessionStart` でその handoff を自動再注入する。手動コピペ不要。

## インストール

```bash
/plugin marketplace add TaskBrain/claude-auto-handoff
/plugin install claude-auto-handoff
# (常駐 auto-trigger を使う場合) daemon 登録 + statusLine 配線案内:
bash "$(echo ~/.claude/plugins/*/claude-auto-handoff/plugins/claude-auto-handoff)/install/install.sh"
```

hooks 経由の **SessionStart 復元 / PreCompact バックストップ** は install.sh 不要で自動稼働する。常時 `context %` 監視 + daemon の `/compact` auto-trigger を使う場合のみ `install.sh` + statusLine 配線が必要。

詳細・設定・仕組み・kill switch は **[plugins/claude-auto-handoff/README.md](plugins/claude-auto-handoff/README.md)** を参照。

## 構成

```
claude-auto-handoff/
├── .claude-plugin/marketplace.json   # marketplace カタログ
├── plugins/claude-auto-handoff/      # プラグイン本体
│   ├── .claude-plugin/plugin.json
│   ├── hooks/                         # SessionStart/PreCompact/Stop + statusLine 委譲 + 共有ヘルパ
│   ├── scripts/                       # 常駐 daemon + pane 解決
│   ├── install/                       # systemd unit + 配線スクリプト
│   ├── tests/                         # shell テスト (bash + python3, Docker 不要)
│   └── README.md
└── LICENSE                            # MIT
```

## 動作要件

Claude Code / `bash` / `python3` (stdlib only) / `tmux` (daemon auto-trigger) / `systemd --user` (daemon 常駐)。

## ライセンス

MIT — [LICENSE](LICENSE)。
