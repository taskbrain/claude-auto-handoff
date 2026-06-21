# claude-auto-handoff

**Claude Code の自動コンパクション handoff + 確実な復元プラグイン。**

長時間セッションで文脈が肥大して圧縮 (`/compact` / `/clear`) されると、それまでの作業文脈が失われ「毎回 handoff を手動コピペする」羽目になる。本プラグインは **文脈が賢いうちに 8 セクションの詳細 handoff を先回りで書き**、圧縮直後の `SessionStart` で **その handoff を自動で先頭に再注入** する。圧縮を跨いでも作業の続きを失わない。

---

## 何を解決するか

- **文脈喪失ゼロ**: prepare 帯 (既定 50%) に達したらモデル自身に 8 セクション handoff (`CURRENT GOAL / STATE / NEXT STEPS / OPEN FILES / DECISIONS / GOTCHAS / TEST STATE / HOW TO RESUME`) を書かせ、圧縮後に再注入する。
- **手動コピペ不要**: daemon が compact 帯 (既定 55%) で自動的に `/compact` を撃ち、復元・継続まで自動化する。
- **`/compact` ベース**: `SessionStart.source == "compact"` は「圧縮された」という曖昧さゼロの復元信号。native 要約が安全網になり、self-authored handoff が一次情報になる。

## 仕組み (3 段カデンス)

```
statusLine (context %) ──> ctx-monitor.sh ──> per-session state (band: idle/prepare/compact/critical)
                                                   │
   prepare 帯 ── Stop hook (ctx-prepare-stop.sh) ──┤ モデルに 8 節 handoff を自筆させる (.model.md)
                                                   │
   compact 帯 ── daemon (cc-compaction-daemon.sh) ─┘ tmux に COMPACTION_COMMAND (既定 /compact) を送出
                                                   │
   圧縮後 ── SessionStart hook (compaction-resume.sh) ── handoff を additionalContext で先頭再注入
```

- **L2/L3 (PreCompact / SessionStart)** は plugin インストールで自動配線され、即稼働する。
- **L0/L1 (常時 statusLine 監視 + daemon auto-trigger)** は statusLine 委譲 + daemon 起動が必要 (`install/install.sh`)。

## 動作要件

- Claude Code (hooks + statusLine 対応版)
- `bash` / `python3` (stdlib only。外部 pip 依存なし)
- `tmux` (daemon の auto-trigger に必須。send-keys で `/compact` を送るため)
- `systemd --user` (daemon 常駐。無い環境では手動 `nohup` 起動も可)

## インストール

```bash
# 1. marketplace を追加してプラグインをインストール
/plugin marketplace add TaskBrain/claude-auto-handoff
/plugin install claude-auto-handoff

# 2. (常駐レールを使う場合) daemon を登録 + statusLine 配線案内
bash "$(echo ~/.claude/plugins/*/claude-auto-handoff/plugins/claude-auto-handoff)/install/install.sh"
```

`install.sh` は systemd --user daemon を冪等にインストールし、statusLine 委譲の手順を表示する。hooks 経由の **SessionStart 復元 / PreCompact バックストップは install.sh 不要で自動稼働** する (常駐 auto-trigger のみ statusLine 配線が必要)。

### statusLine 配線 (常駐レールの完全有効化)

hook は token 量を受け取れず、`context_window.used_percentage` を持つのは statusLine のみ。そのため `ctx-monitor.sh` (per-session state を書く副作用のみ) は statusLine から委譲する。`~/.claude/settings.json` の statusLine コマンドに次を組み込む (`install/statusline-snippet.sh` 参照):

```bash
input="$(cat)"
printf '%s' "$input" | "<plugin>/hooks/ctx-monitor.sh" >/dev/null 2>&1   # 副作用: state 書込
printf '%s' "$input" | <あなたの既存 statusLine コマンド>                   # 通常の描画
```

## 設定 (環境変数)

state/handoff は **`${HOME}/.claude/auto-compaction/`** 配下に保存される (`CC_COMPACTION_HOME` で上書き可)。
この固定パスは意図的: 常駐 daemon は Claude Code とは別プロセス (systemd --user) で `${CLAUDE_PLUGIN_DATA}` 等の
Claude Code ランタイム env を参照できないため、hooks と daemon が**同じ固定パス**を共有する必要がある。

**プライバシー**: handoff / archive にはあなたの作業文脈 (直近の user 要求・編集ファイルパス・実行コマンド) が含まれる。
これらは**ローカルのみ**に保存され外部送信はされず、`GC_*` 設定で age out される (既定: handoff 7日 / archive 14日)。
保存先を変えたい場合は `CC_COMPACTION_HOME` を設定する。

値は環境変数または `hooks/auto_compaction.conf` の直編集で調整 (assign-if-unset 形式で env override が優先)。

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `CC_HANDOFF_ENABLED` | `on` | `off` で handoff 生成 / 復元を無効化 (kill switch) |
| `CC_HANDOFF_DAEMON_ENABLED` | `false` | daemon の有効化 (systemd unit が `true` を設定) |
| `COMPACTION_COMMAND` | `/compact` | システム起因の圧縮コマンド。`/clear` にフォールバック可 |
| `PREPARE_PCT` / `COMPACT_PCT` / `CRITICAL_PCT` | `50` / `55` / `78` | 3 段カデンスの % 閾値 |
| `HANDOFF_RESTORE_FRESH_SECONDS` | `1800` | 復元する handoff の鮮度ゲート (これより古い handoff は復元しない) |
| `COMPACTED_TTL_SECONDS` | `600` | 圧縮空振り時に inflight フラグを自己回復する TTL |
| `RESUME_DELAY_SECONDS` / `RESUME_MAX_WAIT_SECONDS` | `12` / `90` | 圧縮後の入力欄再準備待ち (最低 / poll 上限) |
| `CC_HANDOFF_GC` | `on` | 孤立 state/handoff/marker の age ベース GC (`off` で無効) |

### kill switch

```bash
systemctl --user stop cc-handoff-daemon.service   # daemon 停止
touch ~/.claude/auto-compaction/DISABLED           # daemon を即停止 (再起動不要)
export CC_HANDOFF_ENABLED=off                       # 機能全体を無効化
export COMPACTION_COMMAND=/clear                    # /compact が不発な環境で /clear に切替
```

## 堅牢性の要点

- **復元はフラグ非依存**: `SessionStart.source ∈ {compact, clear}` ∧ fresh handoff があれば必ず再注入する。圧縮コマンド送出とフラグ設定の順序に依存しない (TOCTOU レース無し)。
- **誤復元防止 (世代マーカー)**: 同一 tmux pane / tty を別セッションが再利用したとき、前占有者の handoff を誤復元しない。`startup|resume` で世代マーカーを置き、復元は「現世代以降に書かれた handoff」に限定する。
- **沈黙劣化防止 (TTL 自己回復)**: 圧縮が空振りして inflight フラグが残っても、`COMPACTED_TTL_SECONDS` 超 ∧ context が圧縮帯のままなら daemon が clear して再評価する。
- **early-fail**: フォールバック値の捏造をしない。handoff が空/stale/前世代のときは明示ガイダンスに degrade する。

## テスト

```bash
bash tests/run_all.sh   # 全シェルテスト (bash + python3 のみ、Docker 不要)
```

## ライセンス

MIT — [LICENSE](../../LICENSE) 参照。
