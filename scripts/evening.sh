#!/usr/bin/env bash
# evening.sh — 夕方の日次レポート作成スクリプト
#
# 使い方:
#   bash scripts/evening.sh [--dry-run] [--no-slack]
#
# オプション:
#   --dry-run   ファイルの書き込み・Slack投稿・git commitをスキップ
#   --no-slack  Slack への投稿をスキップ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ライブラリの読み込み
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tasks.sh
source "${SCRIPT_DIR}/lib/tasks.sh"

# フラグのパース
parse_flags "$@"

# 設定の読み込み
load_config

log_section "夕方のレポート作成を開始します"

TODAY=$(today)
TODAY_JA="$(day_of_week_ja)曜日"
TODO_FILE="${REPO_ROOT}/${TASKS_DIR}/todo.txt"
PLAN_FILE="${REPO_ROOT}/${PLANS_DIR}/${TODAY}.md"
REPORT_FILE="${REPO_ROOT}/${REPORTS_DIR}/${TODAY}.md"
TOMORROW_FILE="${REPO_ROOT}/${TASKS_DIR}/todo_tomorrow.txt"

ensure_dir "${REPO_ROOT}/${REPORTS_DIR}"

# ----------------------------------------------------------------
# バリデーション
# ----------------------------------------------------------------
if [[ ! -f "${TODO_FILE}" ]]; then
  log_warn "todo.txt が見つかりません: ${TODO_FILE}"
  log_warn "morning.sh を先に実行してください"
fi

# ----------------------------------------------------------------
# ステップ1: タスク集計
# ----------------------------------------------------------------
log_section "タスクの集計"

done_count=0
pending_count=0
total=0

if [[ -f "${TODO_FILE}" ]]; then
  done_count=$(get_done_tasks "${TODO_FILE}" | grep -c '.' 2>/dev/null || echo 0)
  pending_count=$(get_pending_tasks "${TODO_FILE}" | grep -c '.' 2>/dev/null || echo 0)
  total=$(( done_count + pending_count ))
fi

if [[ ${total} -gt 0 ]]; then
  completion_rate=$(( done_count * 100 / total ))
else
  completion_rate=0
fi

log_info "完了: ${done_count} / ${total} タスク (${completion_rate}%)"
log_info "繰越: ${pending_count} タスク"

# ----------------------------------------------------------------
# ステップ2: 日次レポートの生成
# ----------------------------------------------------------------
log_section "日次レポートの生成"

if [[ "${DRY_RUN}" == "false" ]]; then
  generate_report_markdown "${TODAY}" "${TODAY_JA}" "${TODO_FILE}" "${REPORT_FILE}"
  log_ok "レポートファイルを生成しました: ${REPORT_FILE}"
else
  log_warn "[DRY-RUN] レポートファイルの生成をスキップ: ${REPORT_FILE}"
fi

# ----------------------------------------------------------------
# ステップ3: 未完了タスクを明日へ繰越
# ----------------------------------------------------------------
log_section "未完了タスクの繰越準備"

if [[ "${DRY_RUN}" == "false" ]] && [[ -f "${TODO_FILE}" ]]; then
  if [[ ${pending_count} -gt 0 ]]; then
    get_pending_tasks "${TODO_FILE}" > "${TOMORROW_FILE}"
    log_ok "未完了タスク ${pending_count} 件を ${TOMORROW_FILE} に保存しました"
    log_info "次回の morning.sh 実行時に自動的に繰越されます"
  else
    log_info "繰越タスクはありません（全タスク完了！）"
    rm -f "${TOMORROW_FILE}"
  fi
else
  log_warn "[DRY-RUN] 繰越ファイルの生成をスキップ"
fi

# ----------------------------------------------------------------
# ステップ4: git auto-commit
# ----------------------------------------------------------------
log_section "git コミット"

if [[ "${GIT_AUTO_COMMIT}" == "true" ]] && [[ "${DRY_RUN}" == "false" ]]; then
  # 変更があるか確認
  changed_files=()
  [[ -f "${REPORT_FILE}" ]] && changed_files+=("${REPORTS_DIR}/${TODAY}.md")
  [[ -f "${PLAN_FILE}" ]] && changed_files+=("${PLANS_DIR}/${TODAY}.md")

  if [[ ${#changed_files[@]} -gt 0 ]]; then
    git add "${changed_files[@]}" 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      log_info "コミットする変更がありません"
    else
      git commit -m "$(printf 'daily: %s のレポート・計画を追加\n\nhttps://claude.ai/code/session' "${TODAY}")" 2>/dev/null && \
        log_ok "git commit しました" || \
        log_warn "git commit に失敗しました（手動でコミットしてください）"
    fi
  fi
else
  if [[ "${GIT_AUTO_COMMIT}" != "true" ]]; then
    log_info "GIT_AUTO_COMMIT が無効のためスキップします"
  else
    log_warn "[DRY-RUN] git commit をスキップ"
  fi
fi

# ----------------------------------------------------------------
# ステップ5: Slack 通知
# ----------------------------------------------------------------
log_section "Slack 通知"

if [[ "${NO_SLACK}" == "false" ]]; then
  # 完了タスク一覧（上位5件）
  done_list=""
  count=0
  if [[ -f "${TODO_FILE}" ]]; then
    while IFS= read -r line && [[ ${count} -lt 5 ]]; do
      [[ -z "${line}" ]] && continue
      title=$(echo "${line}" | sed 's/^x [0-9-]* //; s/^([ABC]) //; s/due:[^ ]* //g; s/+[^ ]* //g; s/#[^ ]* //g; s/GH#[0-9]* //g; s/added:[^ ]* //g; s/  */ /g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      done_list="${done_list}✓ ${title}\n"
      (( count++ )) || true
    done < <(get_done_tasks "${TODO_FILE}")
  fi

  if [[ -z "${done_list}" ]]; then
    done_list="（なし）\n"
  fi

  slack_message="*Daily Report: ${TODAY} (${TODAY_JA})*
完了率: *${completion_rate}%* (${done_count}/${total} タスク) | 繰越: ${pending_count}件

*完了タスク:*
${done_list}
レポート: \`${REPORTS_DIR}/${TODAY}.md\`"

  run_or_dry slack_post "${slack_message}"
fi

# ----------------------------------------------------------------
# 完了
# ----------------------------------------------------------------
log_section "完了"
log_ok "夕方のレポート作成が完了しました！"
echo ""
echo "  レポートファイル: ${REPORT_FILE}"
echo "  完了: ${done_count} / ${total} タスク (${completion_rate}%)"
echo "  繰越: ${pending_count} タスク"
echo ""
if [[ ${completion_rate} -eq 100 ]]; then
  echo "  全タスク完了です！素晴らしい仕事でした！"
elif [[ ${completion_rate} -ge 80 ]]; then
  echo "  素晴らしい！ほとんどのタスクを完了しました。"
elif [[ ${completion_rate} -ge 50 ]]; then
  echo "  半分以上完了しました。残りは明日に繰越されます。"
else
  echo "  残りのタスクは明日に繰越されます。"
fi
