#!/usr/bin/env bash
# tasks.sh — タスクのパース・Markdown生成関数
# source scripts/lib/tasks.sh として読み込んで使用

# ----------------------------------------------------------------
# タスクのフィルタリング
# ----------------------------------------------------------------

# pending タスクのみ抽出（完了行を除く、コメント行・空行を除く）
get_pending_tasks() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  grep -v '^[[:space:]]*#' "${file}" | \
    grep -v '^[[:space:]]*$' | \
    grep -v '^x [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || true
}

# 完了タスクのみ抽出
get_done_tasks() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  grep '^x [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "${file}" || true
}

# due:DATE が N日以内のタスクを抽出
get_due_soon_tasks() {
  local file="$1"
  local days="${2:-3}"
  [[ -f "${file}" ]] || return 0

  local today_epoch
  today_epoch=$(date +%s)
  local cutoff_epoch=$(( today_epoch + days * 86400 ))

  while IFS= read -r line; do
    # コメント行・空行・完了行をスキップ
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "${line}" =~ ^x\ [0-9]{4} ]] && continue

    # due:YYYY-MM-DD を抽出
    if [[ "${line}" =~ due:([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      local due_date="${BASH_REMATCH[1]}"
      local due_epoch
      due_epoch=$(date -d "${due_date}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${due_date}" +%s 2>/dev/null || echo 0)
      if [[ ${due_epoch} -le ${cutoff_epoch} ]]; then
        echo "${line}"
      fi
    fi
  done < "${file}"
}

# ----------------------------------------------------------------
# タスクのマージ・重複除去
# ----------------------------------------------------------------

# 複数のタスクリストをマージし、GH#番号とタイトルで重複除去
merge_and_dedup_tasks() {
  python3 - "$@" <<'PYEOF'
import sys
import re

seen_gh = {}
seen_title = {}
merged = []

for filepath in sys.argv[1:]:
    try:
        with open(filepath) as f:
            for line in f:
                line = line.rstrip('\n')
                # コメント・空行・完了行はスキップ
                stripped = line.strip()
                if not stripped or stripped.startswith('#'):
                    continue
                if re.match(r'^x \d{4}-\d{2}-\d{2}', stripped):
                    continue

                # GH#番号で重複チェック
                gh_match = re.search(r'GH#(\d+)', line)
                gh_num = gh_match.group(1) if gh_match else None

                # タイトル（メタデータを除いた部分）でも重複チェック
                title = re.sub(r'^\([ABC]\)\s*', '', stripped)
                title = re.sub(r'due:\S+\s*', '', title)
                title = re.sub(r'\+\S+\s*', '', title)
                title = re.sub(r'#\S+\s*', '', title)
                title = re.sub(r'GH#\d+\s*', '', title)
                title = re.sub(r'added:\S+\s*', '', title)
                title = title.strip().lower()

                if gh_num and gh_num in seen_gh:
                    continue
                if title and title in seen_title:
                    continue

                if gh_num:
                    seen_gh[gh_num] = True
                if title:
                    seen_title[title] = True

                merged.append(line)
    except FileNotFoundError:
        pass

for line in merged:
    print(line)
PYEOF
}

# ----------------------------------------------------------------
# Markdown 生成
# ----------------------------------------------------------------

# タスクをカテゴリ別にグループ化して辞書を返す（連想配列をグローバルに設定）
# 引数: タスクが入ったファイル
build_category_groups() {
  local input_file="$1"
  python3 - "${input_file}" <<'PYEOF'
import sys
import re
import json

categories = {}
uncategorized = []

try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip() or line.strip().startswith('#'):
                continue

            cats = re.findall(r'\+(\w+)', line)
            if cats:
                for cat in cats:
                    categories.setdefault(cat, []).append(line)
            else:
                uncategorized.append(line)
except FileNotFoundError:
    pass

if uncategorized:
    categories['その他'] = uncategorized

print(json.dumps(categories, ensure_ascii=False))
PYEOF
}

# 1つのタスク行を Markdown の箇条書きに変換
task_to_markdown_item() {
  local line="$1"
  python3 - "${line}" <<'PYEOF'
import sys
import re

line = sys.argv[1]

# 完了チェックマーク
if re.match(r'^x \d{4}-\d{2}-\d{2}', line):
    checkbox = '[x]'
    line = re.sub(r'^x \d{4}-\d{2}-\d{2} ', '', line)
else:
    checkbox = '[ ]'

# 優先度
prio_match = re.match(r'^\(([ABC])\)\s*', line)
prio = ''
if prio_match:
    prio = f'`{prio_match.group(1)}`'
    line = line[prio_match.end():]

# due
due_match = re.search(r'due:(\S+)', line)
due = f'⏰ `{due_match.group(1)}`' if due_match else ''

# GH#
gh_match = re.search(r'GH#(\d+)', line)
gh = f'[GH#{gh_match.group(1)}]' if gh_match else ''

# メタデータを除いたタイトル
title = re.sub(r'^\([ABC]\)\s*', '', line)
title = re.sub(r'due:\S+\s*', '', title)
title = re.sub(r'\+\S+\s*', '', title)
title = re.sub(r'#(high|medium|low|blocked|waiting)\s*', '', title)
title = re.sub(r'GH#\d+\s*', '', title)
title = re.sub(r'added:\S+\s*', '', title)
title = title.strip()

parts = [f'- {checkbox}', title]
meta = []
if prio:
    meta.append(prio)
if due:
    meta.append(due)
if gh:
    meta.append(gh)
if meta:
    parts.append('—')
    parts.extend(meta)

print(' '.join(parts))
PYEOF
}

# 優先順位付きタスクファイルから Daily Plan Markdown を生成
generate_plan_markdown() {
  local date="$1"
  local dow_ja="$2"
  local prioritized_file="$3"
  local output_file="$4"
  local github_count="${5:-0}"
  local backlog_count="${6:-0}"

  local generated_at
  generated_at=$(date +%H:%M)

  # タスク数カウント
  local total_count=0
  total_count=$(wc -l < "${prioritized_file}" 2>/dev/null || echo 0)

  {
    echo "# Daily Plan: ${date} (${dow_ja})"
    echo ""
    echo "> Generated by morning.sh at ${generated_at}"
    echo ""

    # フォーカスタスク（上位5件）
    echo "## フォーカスタスク（TOP 5）"
    echo ""
    local count=0
    while IFS= read -r line && [[ ${count} -lt 5 ]]; do
      [[ -z "${line}" ]] && continue
      task_to_markdown_item "${line}"
      (( count++ )) || true
    done < "${prioritized_file}"

    echo ""

    # カテゴリ別全タスク
    echo "## 全タスク"
    echo ""

    local categories_json
    categories_json=$(build_category_groups "${prioritized_file}")

    python3 - "${categories_json}" <<'PYEOF'
import sys
import re
import json
import subprocess

categories = json.loads(sys.argv[1])

category_icons = {
    'bug': '🐛',
    'feature': '✨',
    'chore': '🔧',
    'meeting': '🤝',
    'review': '👀',
    'docs': '📝',
    'その他': '📌',
}

for cat, tasks in categories.items():
    icon = category_icons.get(cat, '📌')
    print(f'### {icon} +{cat}')
    print()
    for task in tasks:
        result = subprocess.run(
            ['bash', '-c', f'source scripts/lib/tasks.sh && task_to_markdown_item "{task}"'],
            capture_output=True, text=True, cwd='.'
        )
        if result.stdout.strip():
            print(result.stdout.strip())
        else:
            print(f'- [ ] {task.strip()}')
    print()
PYEOF

    echo ""
    echo "## タイムブロック"
    echo ""
    echo "| 時間帯       | タスク |"
    echo "|-------------|--------|"
    echo "| 09:00-10:00 |        |"
    echo "| 10:00-12:00 |        |"
    echo "| 13:00-15:00 |        |"
    echo "| 15:00-17:00 |        |"
    echo "| 17:00-18:00 |        |"
    echo ""
    echo "## 統計"
    echo ""
    echo "| 項目 | 件数 |"
    echo "|------|------|"
    echo "| 合計タスク | ${total_count} |"
    echo "| GitHub Issues | ${github_count} |"
    echo "| バックログから昇格 | ${backlog_count} |"
    echo ""
    echo "## メモ"
    echo ""
    echo "<!-- 今日のブロッカー・メモを記入 -->"
  } > "${output_file}"
}

# Daily Report Markdown を生成
generate_report_markdown() {
  local date="$1"
  local dow_ja="$2"
  local todo_file="$3"
  local output_file="$4"

  local done_tasks pending_tasks total done_count pending_count completion_rate

  done_tasks=$(get_done_tasks "${todo_file}")
  pending_tasks=$(get_pending_tasks "${todo_file}")

  done_count=$(echo "${done_tasks}" | grep -c '.' 2>/dev/null || echo 0)
  pending_count=$(echo "${pending_tasks}" | grep -c '.' 2>/dev/null || echo 0)
  total=$(( done_count + pending_count ))

  if [[ ${total} -gt 0 ]]; then
    completion_rate=$(( done_count * 100 / total ))
  else
    completion_rate=0
  fi

  {
    echo "# Daily Report: ${date} (${dow_ja})"
    echo ""
    echo "> Generated by evening.sh at $(date +%H:%M)"
    echo ""
    echo "## サマリー"
    echo ""
    echo "| 項目 | 件数 |"
    echo "|------|------|"
    echo "| 完了 | ${done_count} |"
    echo "| 繰越 | ${pending_count} |"
    echo "| 合計 | ${total} |"
    echo "| 完了率 | ${completion_rate}% |"
    echo ""

    if [[ ${done_count} -gt 0 ]]; then
      echo "## 完了タスク"
      echo ""
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        task_to_markdown_item "${line}"
      done <<< "${done_tasks}"
      echo ""
    fi

    if [[ ${pending_count} -gt 0 ]]; then
      echo "## 未完了タスク（明日へ繰越）"
      echo ""
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        task_to_markdown_item "${line}"
      done <<< "${pending_tasks}"
      echo ""
    fi

    echo "## 振り返りメモ"
    echo ""
    echo "<!-- 今日の学び・課題・改善点を記入 -->"
  } > "${output_file}"
}
