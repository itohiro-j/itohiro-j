#!/usr/bin/env bash
# morning.sh — 朝の計画作成スクリプト
#
# 使い方:
#   bash scripts/morning.sh [--dry-run] [--no-github] [--no-slack]
#
# オプション:
#   --dry-run     ファイルの書き込み・Slack投稿をスキップ（動作確認用）
#   --no-github   GitHub Issues の取得をスキップ
#   --no-slack    Slack への投稿をスキップ

set -euo pipefail

# スクリプトのディレクトリからリポジトリルートを特定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ライブラリの読み込み
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tasks.sh
source "${SCRIPT_DIR}/lib/tasks.sh"
# shellcheck source=scripts/lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"

# フラグのパース
parse_flags "$@"

# 設定の読み込み
load_config

log_section "朝の計画作成を開始します"
log_info "日付: $(today) ($(day_of_week_ja)曜日)"

TODAY=$(today)
TODAY_JA="$(day_of_week_ja)曜日"
TODO_FILE="${REPO_ROOT}/${TASKS_DIR}/todo.txt"
BACKLOG_FILE="${REPO_ROOT}/${TASKS_DIR}/backlog.txt"
DONE_DIR="${REPO_ROOT}/${TASKS_DIR}/done"
PLAN_FILE="${REPO_ROOT}/${PLANS_DIR}/${TODAY}.md"

ensure_dir "${REPO_ROOT}/${PLANS_DIR}"
ensure_dir "${DONE_DIR}"

# ----------------------------------------------------------------
# ステップ1: 前日の todo.txt をアーカイブ
# ----------------------------------------------------------------
log_section "前日タスクのアーカイブ"

YESTERDAY=$(yesterday)
YESTERDAY_DONE_FILE="${DONE_DIR}/${YESTERDAY}.txt"

if [[ -f "${TODO_FILE}" ]]; then
  local_done_tasks=$(get_done_tasks "${TODO_FILE}" || true)
  if [[ -n "${local_done_tasks}" ]]; then
    if [[ "${DRY_RUN}" == "false" ]]; then
      echo "${local_done_tasks}" >> "${YESTERDAY_DONE_FILE}"
      log_ok "完了タスクを ${YESTERDAY_DONE_FILE} にアーカイブしました"
    else
      log_warn "[DRY-RUN] 完了タスクのアーカイブをスキップ"
    fi
  else
    log_info "アーカイブする完了タスクはありません"
  fi
fi

# ----------------------------------------------------------------
# ステップ2: 未完了タスクの引き継ぎ
# ----------------------------------------------------------------
log_section "未完了タスクの引き継ぎ"

CARRY_OVER_FILE=$(mktemp)
trap 'rm -f "${CARRY_OVER_FILE}"' EXIT

if [[ -f "${TASKS_DIR}/todo_tomorrow.txt" ]]; then
  # evening.sh が生成した繰越ファイルがあれば使用
  cp "${TASKS_DIR}/todo_tomorrow.txt" "${CARRY_OVER_FILE}"
  rm -f "${TASKS_DIR}/todo_tomorrow.txt"
  log_info "繰越ファイル (todo_tomorrow.txt) から引き継ぎました"
elif [[ -f "${TODO_FILE}" ]]; then
  # 未完了タスクを繰越（added:日付を今日に更新）
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # added: の日付を今日に更新
    updated_line=$(echo "${line}" | sed "s/added:[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/added:${TODAY}/")
    echo "${updated_line}"
  done < <(get_pending_tasks "${TODO_FILE}") > "${CARRY_OVER_FILE}"

  carryover_count=$(wc -l < "${CARRY_OVER_FILE}" || echo 0)
  log_info "前日から ${carryover_count} タスクを繰越しました"
fi

# ----------------------------------------------------------------
# ステップ3: GitHub Issues の取得
# ----------------------------------------------------------------
log_section "GitHub Issues の取得"

GITHUB_ISSUES_FILE=$(mktemp)
trap 'rm -f "${CARRY_OVER_FILE}" "${GITHUB_ISSUES_FILE}"' EXIT

github_count=0
if [[ "${NO_GITHUB}" == "false" ]]; then
  fetch_github_issues "${GITHUB_ISSUES_FILE}"
  github_count=$(wc -l < "${GITHUB_ISSUES_FILE}" 2>/dev/null || echo 0)
else
  log_warn "--no-github フラグが指定されたため GitHub Issues 取得をスキップします"
fi

# ----------------------------------------------------------------
# ステップ4: バックログからの昇格
# ----------------------------------------------------------------
log_section "バックログからの昇格（${BACKLOG_PROMOTE_DAYS}日以内）"

BACKLOG_PROMOTED_FILE=$(mktemp)
trap 'rm -f "${CARRY_OVER_FILE}" "${GITHUB_ISSUES_FILE}" "${BACKLOG_PROMOTED_FILE}"' EXIT

backlog_count=0
if [[ -f "${BACKLOG_FILE}" ]]; then
  get_due_soon_tasks "${BACKLOG_FILE}" "${BACKLOG_PROMOTE_DAYS}" > "${BACKLOG_PROMOTED_FILE}"
  backlog_count=$(wc -l < "${BACKLOG_PROMOTED_FILE}" 2>/dev/null || echo 0)
  log_ok "バックログから ${backlog_count} タスクを昇格しました"
else
  log_info "backlog.txt が見つかりません。スキップします。"
fi

# ----------------------------------------------------------------
# ステップ5: タスクのマージ・優先順位付け
# ----------------------------------------------------------------
log_section "タスクのマージ・優先順位付け"

MERGED_FILE=$(mktemp)
PRIORITIZED_FILE=$(mktemp)
trap 'rm -f "${CARRY_OVER_FILE}" "${GITHUB_ISSUES_FILE}" "${BACKLOG_PROMOTED_FILE}" "${MERGED_FILE}" "${PRIORITIZED_FILE}"' EXIT

# 全ソースをマージ
{
  cat "${CARRY_OVER_FILE}" 2>/dev/null || true
  cat "${GITHUB_ISSUES_FILE}" 2>/dev/null || true
  cat "${BACKLOG_PROMOTED_FILE}" 2>/dev/null || true
} > "${MERGED_FILE}"

total_before=$(wc -l < "${MERGED_FILE}" || echo 0)

# 優先順位付け（Pythonスクリプトで重複除去 & スコアリング）
python3 "${SCRIPT_DIR}/lib/prioritize.py" "${MERGED_FILE}" > "${PRIORITIZED_FILE}"

total_after=$(wc -l < "${PRIORITIZED_FILE}" || echo 0)
duplicates=$(( total_before - total_after ))
log_ok "タスク数: ${total_after}（重複除去: ${duplicates}件）"

# ----------------------------------------------------------------
# ステップ6: 計画ファイルの生成
# ----------------------------------------------------------------
log_section "計画ファイルの生成"

if [[ "${DRY_RUN}" == "false" ]]; then
  generate_plan_markdown \
    "${TODAY}" "${TODAY_JA}" \
    "${PRIORITIZED_FILE}" "${PLAN_FILE}" \
    "${github_count}" "${backlog_count}"
  log_ok "計画ファイルを生成しました: ${PLAN_FILE}"
else
  log_warn "[DRY-RUN] 計画ファイルの生成をスキップ: ${PLAN_FILE}"
fi

# ----------------------------------------------------------------
# ステップ7: todo.txt の更新（優先順位順に整理）
# ----------------------------------------------------------------
log_section "todo.txt の更新"

if [[ "${DRY_RUN}" == "false" ]]; then
  {
    echo "# ==============================================================
# todo.txt — 今日のタスクリスト (${TODAY})
# ==============================================================
# 書式: [完了マーク] (優先度) [due:日付] +カテゴリ [#ラベル] [GH#issue] タスク名 added:日付
# 完了: 行頭に「x YYYY-MM-DD 」を追加する
# ==============================================================
"
    cat "${PRIORITIZED_FILE}"
  } > "${TODO_FILE}"
  log_ok "todo.txt を優先順位順に更新しました"
else
  log_warn "[DRY-RUN] todo.txt の更新をスキップ"
fi

# ----------------------------------------------------------------
# ステップ8: Slack 通知
# ----------------------------------------------------------------
log_section "Slack 通知"

if [[ "${NO_SLACK}" == "false" ]]; then
  top5=""
  count=0
  while IFS= read -r line && [[ ${count} -lt 5 ]]; do
    [[ -z "${line}" ]] && continue
    title=$(echo "${line}" | sed 's/^([ABC]) //; s/due:[^ ]* //g; s/+[^ ]* //g; s/#[^ ]* //g; s/GH#[0-9]* //g; s/added:[^ ]* //g; s/  */ /g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    top5="${top5}• ${title}\n"
    (( count++ )) || true
  done < "${PRIORITIZED_FILE}"

  slack_message="*Daily Plan: ${TODAY} (${TODAY_JA})*
合計 ${total_after} タスク（GitHub: ${github_count}件 / バックログ昇格: ${backlog_count}件）

*フォーカスタスク:*
${top5}
計画ファイル: \`${PLANS_DIR}/${TODAY}.md\`"

  run_or_dry slack_post "${slack_message}"
fi

# ----------------------------------------------------------------
# 完了
# ----------------------------------------------------------------
log_section "完了"
log_ok "朝の計画作成が完了しました！"
echo ""
echo "  計画ファイル: ${PLAN_FILE}"
echo "  タスク数:     ${total_after}"
echo ""
if [[ "${DRY_RUN}" == "false" ]]; then
  echo "  → エディタで ${PLAN_FILE} を開いて今日の作業を始めましょう！"
fi
