#!/usr/bin/env bash
# common.sh — 共通ユーティリティ関数
# source scripts/lib/common.sh として読み込んで使用

set -euo pipefail

# ----------------------------------------------------------------
# 色付き出力
# ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}${BLUE}=== $* ===${RESET}"; }

# ----------------------------------------------------------------
# 設定ファイルの読み込み
# ----------------------------------------------------------------
load_config() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../.. && pwd)"
  REPO_ROOT="${script_dir}"

  # デフォルト値
  GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  GITHUB_USER="${GITHUB_USER:-}"
  GITHUB_REPOS="${GITHUB_REPOS:-}"
  SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
  BACKLOG_PROMOTE_DAYS="${BACKLOG_PROMOTE_DAYS:-3}"
  TZ="${TZ:-Asia/Tokyo}"
  W_PRIORITY="${W_PRIORITY:-4}"
  W_URGENCY="${W_URGENCY:-5}"
  W_LABEL="${W_LABEL:-3}"
  W_BUG_BOOST="${W_BUG_BOOST:-2}"
  PLANS_DIR="${PLANS_DIR:-plans}"
  REPORTS_DIR="${REPORTS_DIR:-reports}"
  TASKS_DIR="${TASKS_DIR:-tasks}"
  GIT_AUTO_COMMIT="${GIT_AUTO_COMMIT:-true}"

  # config.env があれば読み込む
  local config_file="${REPO_ROOT}/config.env"
  if [[ -f "${config_file}" ]]; then
    # shellcheck disable=SC1090
    source "${config_file}"
    log_ok "config.env を読み込みました"
  else
    log_warn "config.env が見つかりません。デフォルト設定で動作します。"
    log_warn "cp ${REPO_ROOT}/config.env.example ${REPO_ROOT}/config.env を実行して設定してください。"
  fi

  export REPO_ROOT PLANS_DIR REPORTS_DIR TASKS_DIR
}

# ----------------------------------------------------------------
# 日付ユーティリティ
# ----------------------------------------------------------------
today() { date +%Y-%m-%d; }
yesterday() { date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v -1d +%Y-%m-%d; }
day_of_week() { date +%A; }
day_of_week_ja() {
  local dow
  dow=$(date +%u)  # 1=Mon ... 7=Sun
  local days=("" "月" "火" "水" "木" "金" "土" "日")
  echo "${days[$dow]}"
}

# ----------------------------------------------------------------
# Slack 通知
# ----------------------------------------------------------------
slack_post() {
  local message="$1"
  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    log_warn "SLACK_WEBHOOK_URL が未設定のためSlack通知をスキップします"
    return 0
  fi

  local payload
  payload=$(printf '{"text": %s}' "$(echo "${message}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

  if curl -s -f -X POST \
    -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK_URL}" > /dev/null 2>&1; then
    log_ok "Slackに通知を送信しました"
  else
    log_warn "Slack通知の送信に失敗しました"
  fi
}

# ----------------------------------------------------------------
# ファイルバリデーション
# ----------------------------------------------------------------
require_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    log_error "ファイルが見つかりません: ${file}"
    exit 1
  fi
}

ensure_dir() {
  local dir="$1"
  mkdir -p "${dir}"
}

# ----------------------------------------------------------------
# dry-run サポート
# ----------------------------------------------------------------
DRY_RUN=false

parse_flags() {
  NO_GITHUB=false
  NO_SLACK=false

  for arg in "$@"; do
    case "$arg" in
      --dry-run)   DRY_RUN=true  ;;
      --no-github) NO_GITHUB=true ;;
      --no-slack)  NO_SLACK=true  ;;
    esac
  done

  export DRY_RUN NO_GITHUB NO_SLACK
}

run_or_dry() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "[DRY-RUN] スキップ: $*"
  else
    "$@"
  fi
}
