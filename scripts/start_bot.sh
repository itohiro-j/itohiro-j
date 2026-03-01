#!/usr/bin/env bash
# start_bot.sh — Daily Planner Slack Bot を起動するスクリプト
#
# 使い方:
#   bash scripts/start_bot.sh
#
# バックグラウンド起動:
#   bash scripts/start_bot.sh --daemon
#
# 停止:
#   bash scripts/stop_bot.sh  (または kill $(cat .bot.pid))

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

DAEMON_MODE=false
for arg in "$@"; do
  [[ "${arg}" == "--daemon" ]] && DAEMON_MODE=true
done

# ----------------------------------------------------------------
# 前提確認
# ----------------------------------------------------------------
echo "=== Daily Planner Slack Bot ==="
echo ""

# config.env の確認
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "[ERROR] config.env が見つかりません。"
  echo "  cp config.env.example config.env を実行してから設定してください。"
  exit 1
fi

# Python の確認
if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 が見つかりません。"
  exit 1
fi

# 依存パッケージの確認・インストール
if ! python3 -c "import slack_bolt" 2>/dev/null; then
  echo "[INFO] slack_bolt をインストールします..."
  pip3 install -r "${REPO_ROOT}/requirements.txt" --quiet
fi

# トークンの簡易チェック
source "${REPO_ROOT}/config.env" 2>/dev/null || true

if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "[ERROR] SLACK_BOT_TOKEN が config.env に設定されていません。"
  echo "  README.md の「Slack App のセットアップ」を参照してください。"
  exit 1
fi

if [[ -z "${SLACK_APP_TOKEN:-}" ]]; then
  echo "[ERROR] SLACK_APP_TOKEN が config.env に設定されていません。"
  echo "  Slack App の Socket Mode を有効にして App-Level Token を取得してください。"
  exit 1
fi

# ----------------------------------------------------------------
# 起動
# ----------------------------------------------------------------
BOT_SCRIPT="${SCRIPT_DIR}/slack_bot.py"
PID_FILE="${REPO_ROOT}/.bot.pid"
LOG_FILE="${REPO_ROOT}/logs/bot.log"

mkdir -p "${REPO_ROOT}/logs"

if [[ "${DAEMON_MODE}" == "true" ]]; then
  # 既存のプロセスを確認
  if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
      echo "[WARN] Bot はすでに起動中です (PID: ${OLD_PID})"
      echo "  停止: kill ${OLD_PID}"
      exit 0
    else
      rm -f "${PID_FILE}"
    fi
  fi

  echo "[INFO] Bot をバックグラウンドで起動します..."
  nohup python3 "${BOT_SCRIPT}" >> "${LOG_FILE}" 2>&1 &
  BOT_PID=$!
  echo "${BOT_PID}" > "${PID_FILE}"
  sleep 2

  if kill -0 "${BOT_PID}" 2>/dev/null; then
    echo "[OK] Bot が起動しました (PID: ${BOT_PID})"
    echo "  ログ: tail -f ${LOG_FILE}"
    echo "  停止: kill ${BOT_PID}  または  bash scripts/stop_bot.sh"
  else
    echo "[ERROR] Bot の起動に失敗しました。ログを確認してください:"
    tail -20 "${LOG_FILE}"
    exit 1
  fi
else
  # フォアグラウンド起動
  echo "[INFO] Bot を起動します... (停止: Ctrl+C)"
  echo ""
  python3 "${BOT_SCRIPT}"
fi
