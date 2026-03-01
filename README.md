# 毎日の計画自動化システム

毎朝・毎夕の反復作業を自動化するシェルスクリプト + Slack Bot セットです。

- **朝**: GitHub Issues・todo.txt・バックログを統合して優先順位付きの計画を生成
- **夕**: 完了/未完了を集計して日次レポートを生成し、未完了を翌日へ繰越

---

## ディレクトリ構成

```
.
├── scripts/
│   ├── morning.sh              # 朝の計画作成（メインスクリプト）
│   ├── evening.sh              # 夕方のレポート作成（メインスクリプト）
│   ├── slack_bot.py            # Slack Bot（Socket Mode・インタラクティブボタン）
│   ├── start_bot.sh            # Bot 起動スクリプト
│   ├── stop_bot.sh             # Bot 停止スクリプト
│   └── lib/
│       ├── common.sh           # 共通ユーティリティ
│       ├── tasks.sh            # タスクパース・Markdown生成
│       ├── github.sh           # GitHub REST API連携
│       └── prioritize.py       # 優先順位付けエンジン（Python）
├── tasks/
│   ├── todo.txt                # 今日のタスク
│   ├── backlog.txt             # バックログ
│   └── done/                   # 完了アーカイブ（gitignore済み）
├── plans/                      # 日次計画（YYYY-MM-DD.md）
├── reports/                    # 日次レポート（YYYY-MM-DD.md）
├── logs/                       # Bot ログ（gitignore済み）
├── requirements.txt            # Python 依存パッケージ
├── config.env.example          # 設定テンプレート
└── .gitignore
```

---

## セットアップ

### 1. 設定ファイルを作成

```bash
cp config.env.example config.env
```

`config.env` を編集して必要な項目を設定します：

| 変数 | 説明 | 必須 |
|------|------|------|
| `SLACK_BOT_TOKEN` | Bot User OAuth Token（xoxb-...）| **Slack Bot 使用時は必須** |
| `SLACK_APP_TOKEN` | App-Level Token（xapp-...）| **Slack Bot 使用時は必須** |
| `SLACK_CHANNEL` | デフォルト投稿先チャンネルID | 任意 |
| `SLACK_MORNING_REMINDER` | 朝のリマインダー時刻（HH:MM）| 任意 |
| `SLACK_EVENING_REMINDER` | 夕方のリマインダー時刻（HH:MM）| 任意 |
| `GITHUB_TOKEN` | GitHub Personal Access Token | 任意 |
| `GITHUB_USER` | GitHub ユーザー名 | 任意 |
| `GITHUB_REPOS` | 対象リポジトリ（カンマ区切り）| 任意 |

---

## Slack App のセットアップ

### 1. Slack App の作成

1. [api.slack.com/apps](https://api.slack.com/apps) を開く
2. **「Create New App」** → **「From scratch」** を選択
3. App Name（例: `Daily Planner`）と Workspace を入力

### 2. 必要な権限（OAuth Scopes）を追加

**「OAuth & Permissions」** → **「Bot Token Scopes」** に以下を追加:

| スコープ | 用途 |
|---------|------|
| `chat:write` | メッセージの投稿 |
| `im:read` | DM の読み取り |
| `im:write` | DM への書き込み |
| `app_mentions:read` | メンションの受信 |
| `channels:read` | チャンネル情報の取得 |

### 3. Interactivity を有効化

**「Interactivity & Shortcuts」** → **「Interactivity」** を **ON** に設定

> Socket Mode を使うため Request URL は不要です

### 4. Socket Mode を有効化

1. **「Socket Mode」** → **「Enable Socket Mode」** を ON
2. **「App-Level Tokens」** → **「Generate Token」** をクリック
3. Token Name を入力し、`connections:write` スコープを付与
4. 生成された `xapp-...` トークンを `SLACK_APP_TOKEN` に設定

### 5. Event Subscriptions を設定

**「Event Subscriptions」** → **「Enable Events」** を ON にして、以下の Bot Events を追加:

| イベント | 用途 |
|---------|------|
| `message.im` | DM メッセージの受信 |
| `app_home_opened` | App Home タブを開いたとき |
| `app_mention` | チャンネルでのメンション |

### 6. App Home を有効化

**「App Home」** → **「Home Tab」** を **ON** に設定

### 7. アプリをワークスペースにインストール

**「Install App」** → **「Install to Workspace」** → 認証
→ 生成された `xoxb-...` トークンを `SLACK_BOT_TOKEN` に設定

### 8. Slack Bot を起動

```bash
bash scripts/start_bot.sh
```

Slack で App Home を開くとボタンが表示されます。

> GitHub・Slack を使わない場合は空のままで動作します。

### 2. 必要ツールの確認

```bash
bash --version    # 4.0+ 推奨
python3 --version # 3.8+
curl --version    # GitHub API呼び出し
jq --version      # JSON処理
```

---

## 使い方

### 毎朝実行

```bash
bash scripts/morning.sh
```

以下を自動で行います：
1. 前日の未完了タスクを引き継ぎ
2. GitHub にアサインされた Issues を取得
3. バックログから締切が近いタスクを昇格
4. 優先順位スコアでソート
5. `plans/YYYY-MM-DD.md` を生成
6. `tasks/todo.txt` を優先順位順に更新
7. Slack に朝の計画サマリーを投稿（設定済みの場合）

**オプション:**

| オプション | 説明 |
|-----------|------|
| `--dry-run` | ファイル書き込み・Slack投稿をしない（動作確認用） |
| `--no-github` | GitHub Issues の取得をスキップ |
| `--no-slack` | Slack 通知をスキップ |

```bash
# 動作確認
bash scripts/morning.sh --dry-run

# GitHub連携なしで実行
bash scripts/morning.sh --no-github
```

### 毎夕実行

```bash
bash scripts/evening.sh
```

以下を自動で行います：
1. `tasks/todo.txt` の完了/未完了を集計
2. `reports/YYYY-MM-DD.md` を生成
3. 未完了タスクを `tasks/todo_tomorrow.txt` に保存（翌朝自動繰越）
4. git auto-commit（`GIT_AUTO_COMMIT=true` の場合）
5. Slack に夕方のサマリーを投稿

**オプション:**

| オプション | 説明 |
|-----------|------|
| `--dry-run` | ファイル書き込み・git commit・Slack投稿をしない |
| `--no-slack` | Slack 通知をスキップ |

---

## タスクフォーマット（todo.txt）

```
(優先度) [due:締切] +カテゴリ [#ラベル] [GH#issue番号] タスク名 added:追加日
```

### 優先度

| マーカー | 意味 |
|---------|------|
| `(A)` | 最高優先（今日中に対応必須） |
| `(B)` | 高優先 |
| `(C)` | 低優先 |
| （省略） | 未設定 |

### カテゴリ

| タグ | 説明 |
|-----|------|
| `+bug` | バグ修正 |
| `+feature` | 機能実装 |
| `+chore` | 雑務・メンテナンス |
| `+meeting` | 会議・打ち合わせ |
| `+review` | コードレビュー |
| `+docs` | ドキュメント作業 |

### ラベル

| タグ | 説明 |
|-----|------|
| `#high` | 重要度: 高 |
| `#medium` | 重要度: 中 |
| `#low` | 重要度: 低 |
| `#blocked` | ブロックされている（スコア最下位） |
| `#waiting` | 待機中（スコア最下位） |

### 記述例

```
# 優先度高・締切あり・バグ
(A) due:2026-03-01 +bug #high GH#451 本番ログインエラーの修正 added:2026-02-28

# 機能実装・GitHub Issue連携
(B) due:2026-03-10 +feature GH#123 ダッシュボード画面の実装 added:2026-03-01

# 会議
(B) +meeting 週次チームミーティング 14:00 added:2026-03-01

# 完了済み（「x 完了日 」を先頭に追加）
x 2026-03-01 (A) +bug ホットフィックスのデプロイ added:2026-02-28

# ブロック中（スコア最下位に）
(B) +feature #blocked 承認待ち: デザイン確認 added:2026-03-01
```

---

## 優先順位スコアの仕組み

```
スコア = 優先度スコア × W_PRIORITY
       + 緊急度スコア × W_URGENCY
       + ラベルスコア × W_LABEL
       + bugボーナス  × W_BUG_BOOST
```

| 条件 | スコア |
|------|--------|
| (A) 優先度 | 10 |
| (B) 優先度 | 6 |
| (C) 優先度 | 3 |
| due: 期限切れ | 12 |
| due: 今日 | 10 |
| due: 明日 | 8 |
| due: 2-3日後 | 6 |
| due: 今週 | 4 |
| #high ラベル | 10 |
| #medium ラベル | 5 |
| #blocked / #waiting | スコア強制 -1（最下位） |
| +bug カテゴリ | +5ボーナス |

デフォルト重み: `W_URGENCY=5, W_PRIORITY=4, W_LABEL=3, W_BUG_BOOST=2`

`config.env` で重みをカスタマイズできます。

---

## バックログの管理

`tasks/backlog.txt` に将来のタスクを記述しておきます。
`morning.sh` 実行時に **BACKLOG_PROMOTE_DAYS 日以内（デフォルト: 3日）** の締切があるタスクを自動的に今日のタスクに昇格します。

```bash
# backlog.txt の例
(B) due:2026-03-10 +feature 新機能の実装 added:2026-03-01
(C) due:2026-04-01 +docs APIドキュメントの整備 added:2026-03-01
(C) +chore 依存パッケージのアップデート added:2026-03-01  # 締切なし → 昇格されない
```

---

## GitHub Issues との連携

`config.env` に以下を設定すると、毎朝あなたにアサインされたIssueを自動取得します：

```bash
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxx  # read:org + repo スコープ
GITHUB_USER=your-github-username
GITHUB_REPOS=owner/repo1,owner/repo2  # 空にすると全リポジトリから取得
```

GitHub のラベルから優先度・カテゴリを自動推定します：
- `critical`, `urgent` → `(A)` 最高優先
- `bug`, `high` → `(B)` 高優先
- `medium` → `(C)` 低優先
- マイルストーンの締切日 → `due:YYYY-MM-DD`

---

## cron への登録（自動実行）

```bash
# crontab -e で編集
# 毎朝 8:30 に計画作成
30 8 * * 1-5 cd /path/to/itohiro-j && source config.env && bash scripts/morning.sh --no-slack >> logs/morning.log 2>&1

# 毎夕 18:00 にレポート作成
0 18 * * 1-5 cd /path/to/itohiro-j && bash scripts/evening.sh >> logs/evening.log 2>&1
```

---

## トラブルシューティング

**計画ファイルが生成されない**
```bash
# dry-run で動作確認
bash scripts/morning.sh --dry-run --no-github --no-slack
```

**GitHub Issues が取得できない**
```bash
# トークンの確認
curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
```

**文字化けする**
```bash
export LANG=ja_JP.UTF-8
```
