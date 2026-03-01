#!/usr/bin/env bash
# stop_bot.sh — Daily Planner Slack Bot を停止するスクリプト

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="${REPO_ROOT}/.bot.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "[WARN] PIDファイルが見つかりません: ${PID_FILE}"
  echo "  手動で停止する場合: ps aux | grep slack_bot.py"
  exit 0
fi

BOT_PID=$(cat "${PID_FILE}")

if kill -0 "${BOT_PID}" 2>/dev/null; then
  kill "${BOT_PID}"
  rm -f "${PID_FILE}"
  echo "[OK] Bot を停止しました (PID: ${BOT_PID})"
else
  echo "[WARN] Bot はすでに停止しています (PID: ${BOT_PID})"
  rm -f "${PID_FILE}"
fi
