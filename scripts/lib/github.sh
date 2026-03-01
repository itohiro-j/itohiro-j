#!/usr/bin/env bash
# github.sh — GitHub REST API を使ったIssue取得
# source scripts/lib/github.sh として読み込んで使用

# ----------------------------------------------------------------
# アサインされたIssueをtodo.txt形式で取得
# ----------------------------------------------------------------

# 戻り値: todo.txt 形式の行（stdout）
fetch_github_issues() {
  local output_file="$1"
  local today
  today=$(date +%Y-%m-%d)

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log_warn "GITHUB_TOKEN が未設定のためGitHub Issues取得をスキップします"
    return 0
  fi

  if [[ -z "${GITHUB_USER:-}" ]]; then
    log_warn "GITHUB_USER が未設定のためGitHub Issues取得をスキップします"
    return 0
  fi

  log_info "GitHub Issues を取得中 (assignee: ${GITHUB_USER})..."

  local api_url="https://api.github.com/issues"
  local query_params="assignee=${GITHUB_USER}&state=open&per_page=50"

  # GITHUB_REPOS が指定されていれば各リポジトリから取得、なければ全体
  if [[ -n "${GITHUB_REPOS:-}" ]]; then
    local tmp_all
    tmp_all=$(mktemp)

    IFS=',' read -ra repos <<< "${GITHUB_REPOS}"
    for repo in "${repos[@]}"; do
      repo="${repo// /}"  # trim
      local repo_url="https://api.github.com/repos/${repo}/issues"
      local response

      response=$(curl -s -f \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${repo_url}?assignee=${GITHUB_USER}&state=open&per_page=50" 2>/dev/null) || {
        log_warn "リポジトリ ${repo} の取得に失敗しました"
        continue
      }

      echo "${response}" >> "${tmp_all}"
    done

    _parse_issues_json "${tmp_all}" "${output_file}" "${today}"
    rm -f "${tmp_all}"
  else
    # 認証ユーザーにアサインされた全Issue
    local response
    response=$(curl -s -f \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${api_url}?${query_params}" 2>/dev/null) || {
      log_warn "GitHub Issues の取得に失敗しました（ネットワークエラー or 認証エラー）"
      return 0
    }

    echo "${response}" > /tmp/gh_issues_raw.json
    _parse_issues_json "/tmp/gh_issues_raw.json" "${output_file}" "${today}"
    rm -f /tmp/gh_issues_raw.json
  fi

  local count=0
  [[ -f "${output_file}" ]] && count=$(wc -l < "${output_file}")
  log_ok "GitHub Issues を ${count} 件取得しました"
}

# JSON を todo.txt 形式にパース
_parse_issues_json() {
  local json_file="$1"
  local output_file="$2"
  local today="$3"

  python3 - "${json_file}" "${output_file}" "${today}" <<'PYEOF'
import sys
import json
import re
from datetime import datetime, timezone

json_file = sys.argv[1]
output_file = sys.argv[2]
today = sys.argv[3]

def parse_issues(data):
    if not isinstance(data, list):
        return []
    results = []
    for issue in data:
        if not isinstance(issue, dict):
            continue
        if issue.get('pull_request'):
            continue  # PRは除外

        number = issue.get('number', 0)
        title = issue.get('title', '').replace('\n', ' ').strip()
        labels = [l.get('name', '') for l in issue.get('labels', [])]
        due_date = None

        # マイルストーン締切をdue:として利用
        milestone = issue.get('milestone')
        if milestone and milestone.get('due_on'):
            try:
                due_dt = datetime.fromisoformat(milestone['due_on'].replace('Z', '+00:00'))
                due_date = due_dt.strftime('%Y-%m-%d')
            except Exception:
                pass

        # 優先度をラベルから推定
        priority = ''
        if any(l in ('P0', 'critical', 'urgent', 'priority: critical') for l in labels):
            priority = '(A) '
        elif any(l in ('P1', 'high', 'priority: high', 'bug') for l in labels):
            priority = '(B) '
        elif any(l in ('P2', 'medium', 'priority: medium') for l in labels):
            priority = '(C) '

        # カテゴリをラベルから推定
        categories = []
        if any(l in ('bug', 'fix') for l in labels):
            categories.append('+bug')
        if any(l in ('feature', 'enhancement') for l in labels):
            categories.append('+feature')
        if any(l in ('documentation', 'docs') for l in labels):
            categories.append('+docs')
        if not categories:
            categories.append('+feature')

        # ラベル
        label_tag = ''
        if any(l in ('P0', 'critical', 'urgent') for l in labels):
            label_tag = ' #high'
        elif any(l in ('P1', 'high') for l in labels):
            label_tag = ' #high'
        elif any(l in ('P2', 'medium') for l in labels):
            label_tag = ' #medium'

        # blocked チェック
        if any(l in ('blocked', 'waiting') for l in labels):
            label_tag += ' #blocked'

        line = f"{priority}"
        if due_date:
            line += f"due:{due_date} "
        line += f"{' '.join(categories)}{label_tag} GH#{number} {title} added:{today}"

        results.append(line.strip())
    return results

all_results = []

try:
    with open(json_file) as f:
        content = f.read().strip()
        if content:
            # 複数のJSON配列が結合されている場合があるので分割試行
            try:
                data = json.loads(content)
                all_results.extend(parse_issues(data))
            except json.JSONDecodeError:
                # 複数JSONを行ごとにパース
                for line in content.splitlines():
                    line = line.strip()
                    if line:
                        try:
                            data = json.loads(line)
                            all_results.extend(parse_issues(data))
                        except Exception:
                            pass
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)

with open(output_file, 'w') as f:
    for line in all_results:
        f.write(line + '\n')
PYEOF
}
