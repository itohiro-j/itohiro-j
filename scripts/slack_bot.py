#!/usr/bin/env python3
"""
slack_bot.py — Daily Planner Slack Bot（Socket Mode）

使い方:
  python3 scripts/slack_bot.py

必要な環境変数（config.env に設定）:
  SLACK_BOT_TOKEN   xoxb- で始まるBot Token
  SLACK_APP_TOKEN   xapp- で始まるApp-Level Token
  SLACK_CHANNEL     デフォルト投稿先チャンネル

機能:
  - App Home にインタラクティブボタンを表示
  - DM / メンション でトリガー
  - 朝・夕の時刻にスケジュール通知（SLACK_MORNING_REMINDER / SLACK_EVENING_REMINDER）
  - ボタンクリックで morning.sh / evening.sh を実行し結果をSlackに投稿
"""

import os
import re
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

# ----------------------------------------------------------------
# 設定の読み込み
# ----------------------------------------------------------------

def load_config() -> dict:
    """config.env を読み込んで環境変数に設定"""
    repo_root = Path(__file__).parent.parent
    config_file = repo_root / "config.env"
    if config_file.exists():
        with open(config_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, _, value = line.partition('=')
                value = value.strip().strip('"').strip("'")
                if key.strip() and value:
                    os.environ.setdefault(key.strip(), value)
    return {
        "bot_token":        os.environ.get("SLACK_BOT_TOKEN", ""),
        "app_token":        os.environ.get("SLACK_APP_TOKEN", ""),
        "channel":          os.environ.get("SLACK_CHANNEL", ""),
        "morning_reminder": os.environ.get("SLACK_MORNING_REMINDER", "09:00"),
        "evening_reminder": os.environ.get("SLACK_EVENING_REMINDER", "18:00"),
        "repo_root":        str(repo_root),
    }


config = load_config()

if not config["bot_token"] or not config["bot_token"].startswith("xoxb-"):
    raise SystemExit(
        "[ERROR] SLACK_BOT_TOKEN が未設定または不正です。\n"
        "config.env に SLACK_BOT_TOKEN=xoxb-... を設定してください。\n"
        "詳細は README.md の「Slack App のセットアップ」を参照。"
    )
if not config["app_token"] or not config["app_token"].startswith("xapp-"):
    raise SystemExit(
        "[ERROR] SLACK_APP_TOKEN が未設定または不正です。\n"
        "config.env に SLACK_APP_TOKEN=xapp-... を設定してください。"
    )

app = App(token=config["bot_token"])

# ----------------------------------------------------------------
# Block Kit — UI ブロック定義
# ----------------------------------------------------------------

HOME_BLOCKS = [
    {
        "type": "header",
        "text": {"type": "plain_text", "text": "📅 Daily Planner", "emoji": True},
    },
    {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "毎日の計画・レポートをワンクリックで作成できます。",
        },
    },
    {"type": "divider"},
    {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "*🌅 朝の計画作成*\nGitHub Issues・todo.txt・バックログを統合して優先順位付きの計画を生成します。",
        },
        "accessory": {
            "type": "button",
            "text": {"type": "plain_text", "text": "計画を作成する", "emoji": True},
            "style": "primary",
            "action_id": "run_morning",
            "value": "morning",
        },
    },
    {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "*🌙 夕方のレポート作成*\n完了・未完了タスクを集計してレポートを生成し、未完了を翌日へ繰越します。",
        },
        "accessory": {
            "type": "button",
            "text": {"type": "plain_text", "text": "レポートを作成する", "emoji": True},
            "style": "danger",
            "action_id": "run_evening",
            "value": "evening",
        },
    },
    {"type": "divider"},
    {
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": f"リポジトリ: `{config['repo_root']}`",
            }
        ],
    },
]


def action_buttons_block(description: str = "") -> list:
    """チャンネル投稿用のアクションボタンブロック"""
    blocks = []
    if description:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": description},
        })
    blocks.append({
        "type": "actions",
        "elements": [
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "🌅 朝の計画を作成", "emoji": True},
                "style": "primary",
                "action_id": "run_morning",
                "value": "morning",
            },
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "🌙 夕方のレポートを作成", "emoji": True},
                "style": "danger",
                "action_id": "run_evening",
                "value": "evening",
            },
        ],
    })
    return blocks


def result_blocks(title: str, output: str, success: bool) -> list:
    """スクリプト実行結果のブロック"""
    icon = "✅" if success else "❌"
    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"{icon} {title}", "emoji": True},
        },
    ]
    if output:
        # 長すぎる場合は切り詰め（Slackの制限: 3000文字）
        truncated = output[:2800] + ("\n…（省略）" if len(output) > 2800 else "")
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"```\n{truncated}\n```"},
        })
    return blocks


# ----------------------------------------------------------------
# スクリプト実行
# ----------------------------------------------------------------

def run_script(script_name: str, extra_flags: list[str] | None = None) -> tuple[bool, str]:
    """
    morning.sh / evening.sh を実行して (成功フラグ, 出力テキスト) を返す。
    """
    script_path = Path(config["repo_root"]) / "scripts" / script_name
    if not script_path.exists():
        return False, f"スクリプトが見つかりません: {script_path}"

    cmd = ["bash", str(script_path), "--no-slack"]
    if extra_flags:
        cmd.extend(extra_flags)

    env = os.environ.copy()
    env["LANG"] = "ja_JP.UTF-8"

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=config["repo_root"],
            env=env,
        )
        output = result.stdout
        if result.returncode != 0:
            output += f"\n[STDERR]\n{result.stderr}"
        return result.returncode == 0, output
    except subprocess.TimeoutExpired:
        return False, "タイムアウト（120秒）: スクリプトの実行が完了しませんでした"
    except Exception as e:
        return False, f"実行エラー: {e}"


def read_generated_file(script_name: str) -> str:
    """生成されたMarkdownファイルの内容を読む"""
    today = datetime.now().strftime("%Y-%m-%d")
    if script_name == "morning.sh":
        path = Path(config["repo_root"]) / "plans" / f"{today}.md"
    else:
        path = Path(config["repo_root"]) / "reports" / f"{today}.md"

    if path.exists():
        content = path.read_text(encoding="utf-8")
        # コードブロックが長すぎる場合は先頭部分のみ
        return content[:2500] + ("\n\n…（続きは plans/ フォルダを確認してください）" if len(content) > 2500 else "")
    return ""


# ----------------------------------------------------------------
# アクションハンドラー
# ----------------------------------------------------------------

def _handle_script_run(script_name: str, title: str, client, channel: str, thread_ts: str | None = None):
    """スクリプトを実行してSlackに結果を投稿（バックグラウンドで実行）"""

    def _run():
        # 実行中メッセージ
        msg = client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"⏳ {title} 実行中...",
        )
        running_ts = msg["ts"]

        success, console_output = run_script(script_name)
        md_content = read_generated_file(script_name)

        # 実行中メッセージを結果で置き換え
        client.chat_update(
            channel=channel,
            ts=running_ts,
            text=f"{'✅' if success else '❌'} {title} {'完了' if success else '失敗'}",
            blocks=result_blocks(title, console_output.strip(), success),
        )

        # 生成されたMarkdownファイルをスレッドに投稿
        if md_content:
            client.chat_postMessage(
                channel=channel,
                thread_ts=running_ts,
                text=f"📄 生成ファイル:\n```\n{md_content}\n```",
            )

    threading.Thread(target=_run, daemon=True).start()


@app.action("run_morning")
def handle_morning_action(ack, body, client):
    ack()
    channel = body.get("channel", {}).get("id") or config["channel"]
    thread_ts = body.get("message", {}).get("ts")
    _handle_script_run("morning.sh", "朝の計画作成", client, channel, thread_ts)


@app.action("run_evening")
def handle_evening_action(ack, body, client):
    ack()
    channel = body.get("channel", {}).get("id") or config["channel"]
    thread_ts = body.get("message", {}).get("ts")
    _handle_script_run("evening.sh", "夕方のレポート作成", client, channel, thread_ts)


# ----------------------------------------------------------------
# App Home
# ----------------------------------------------------------------

@app.event("app_home_opened")
def update_home_tab(client, event):
    client.views_publish(
        user_id=event["user"],
        view={
            "type": "home",
            "blocks": HOME_BLOCKS,
        },
    )


# ----------------------------------------------------------------
# メッセージトリガー（DM / メンション）
# ----------------------------------------------------------------

MORNING_PATTERNS = re.compile(r"morning|朝|おはよ|計画", re.IGNORECASE)
EVENING_PATTERNS = re.compile(r"evening|夕方|おつかれ|レポート|終わり", re.IGNORECASE)
HELP_PATTERNS    = re.compile(r"help|ヘルプ|使い方|使い方", re.IGNORECASE)


def _post_button_message(say, text: str):
    say(
        text=text,
        blocks=[
            {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        ]
        + action_buttons_block(),
    )


@app.event("message")
def handle_dm_message(event, say, client):
    """DM でのメッセージに応答"""
    # Bot自身のメッセージは無視
    if event.get("bot_id"):
        return
    # DM チャンネルのみ反応（チャンネルIDが D で始まる = DM）
    channel_type = event.get("channel_type", "")
    if channel_type not in ("im", "mpim"):
        return

    text = event.get("text", "")

    if MORNING_PATTERNS.search(text):
        _post_button_message(say, "🌅 *朝の計画を作成しますか？*")
    elif EVENING_PATTERNS.search(text):
        _post_button_message(say, "🌙 *夕方のレポートを作成しますか？*")
    elif HELP_PATTERNS.search(text):
        say(
            blocks=[
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": (
                            "*Daily Planner Bot の使い方*\n\n"
                            "• `朝` / `morning` → 朝の計画作成ボタンを表示\n"
                            "• `夕方` / `evening` / `おつかれ` → 夕方のレポートボタンを表示\n"
                            "• App Home タブからもいつでも実行できます"
                        ),
                    },
                }
            ]
        )
    else:
        _post_button_message(say, "何をしますか？")


@app.event("app_mention")
def handle_mention(event, say):
    """チャンネルでのメンションに応答"""
    text = event.get("text", "")

    if MORNING_PATTERNS.search(text):
        _post_button_message(say, "🌅 *朝の計画を作成しますか？*")
    elif EVENING_PATTERNS.search(text):
        _post_button_message(say, "🌙 *夕方のレポートを作成しますか？*")
    else:
        _post_button_message(say, "何をしますか？")


# ----------------------------------------------------------------
# スケジュール通知
# ----------------------------------------------------------------

def _schedule_loop():
    """設定された時刻にチャンネルへリマインダーを投稿するループ"""
    morning_time = config.get("morning_reminder", "").strip()
    evening_time = config.get("evening_reminder", "").strip()
    channel = config.get("channel", "").strip()

    if not channel:
        print("[SCHEDULE] SLACK_CHANNEL が未設定のためスケジュール通知をスキップします")
        return

    sent_today: dict[str, str] = {}  # {"morning": "YYYY-MM-DD", "evening": "YYYY-MM-DD"}

    while True:
        now = datetime.now()
        today_str = now.strftime("%Y-%m-%d")
        current_hhmm = now.strftime("%H:%M")

        if morning_time and current_hhmm == morning_time and sent_today.get("morning") != today_str:
            try:
                app.client.chat_postMessage(
                    channel=channel,
                    text="おはようございます！今日の計画を作成しましょう 🌅",
                    blocks=action_buttons_block("*おはようございます！* 今日の計画を作成しましょう 🌅"),
                )
                sent_today["morning"] = today_str
                print(f"[SCHEDULE] 朝のリマインダーを投稿しました ({today_str})")
            except Exception as e:
                print(f"[SCHEDULE] 朝のリマインダー投稿エラー: {e}")

        if evening_time and current_hhmm == evening_time and sent_today.get("evening") != today_str:
            try:
                app.client.chat_postMessage(
                    channel=channel,
                    text="おつかれさまでした！夕方のレポートを作成しましょう 🌙",
                    blocks=action_buttons_block("*おつかれさまでした！* 夕方のレポートを作成しましょう 🌙"),
                )
                sent_today["evening"] = today_str
                print(f"[SCHEDULE] 夕方のリマインダーを投稿しました ({today_str})")
            except Exception as e:
                print(f"[SCHEDULE] 夕方のリマインダー投稿エラー: {e}")

        time.sleep(30)  # 30秒ごとにチェック


# ----------------------------------------------------------------
# エントリーポイント
# ----------------------------------------------------------------

if __name__ == "__main__":
    print("=" * 60)
    print("  Daily Planner Slack Bot")
    print(f"  リポジトリ: {config['repo_root']}")
    print(f"  朝のリマインダー: {config['morning_reminder'] or '無効'}")
    print(f"  夕方のリマインダー: {config['evening_reminder'] or '無効'}")
    print("=" * 60)

    # スケジュールループをバックグラウンドで起動
    sched_thread = threading.Thread(target=_schedule_loop, daemon=True)
    sched_thread.start()

    # Socket Mode で接続開始
    handler = SocketModeHandler(app, config["app_token"])
    print("\n[INFO] Bot を起動しました。Ctrl+C で停止します。\n")
    handler.start()
