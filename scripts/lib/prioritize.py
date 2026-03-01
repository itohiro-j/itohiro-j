#!/usr/bin/env python3
"""
prioritize.py — タスク優先順位付けスクリプト

使い方:
  python3 scripts/lib/prioritize.py tasks/todo.txt [tasks/github_issues.txt ...]

環境変数:
  W_PRIORITY  優先度マーカー (A/B/C) の重み (デフォルト: 4)
  W_URGENCY   締切の緊急度の重み (デフォルト: 5)
  W_LABEL     ラベル (#high/#medium/#low) の重み (デフォルト: 3)
  W_BUG_BOOST +bug カテゴリのボーナス重み (デフォルト: 2)

出力: 優先順位の高い順にタスクを stdout に出力
"""

import sys
import re
import os
from datetime import datetime, date, timedelta


def get_weight(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


W_PRIORITY = get_weight('W_PRIORITY', 4)
W_URGENCY = get_weight('W_URGENCY', 5)
W_LABEL = get_weight('W_LABEL', 3)
W_BUG_BOOST = get_weight('W_BUG_BOOST', 2)


def score_priority(line: str) -> int:
    """優先度マーカー (A/B/C) のスコア"""
    match = re.match(r'^\(([ABC])\)', line.strip())
    if not match:
        return 1  # 未設定
    scores = {'A': 10, 'B': 6, 'C': 3}
    return scores.get(match.group(1), 1)


def score_urgency(line: str) -> int:
    """締切の緊急度スコア"""
    match = re.search(r'due:(\d{4}-\d{2}-\d{2})', line)
    if not match:
        return 0

    try:
        due = datetime.strptime(match.group(1), '%Y-%m-%d').date()
    except ValueError:
        return 0

    today = date.today()
    delta = (due - today).days

    if delta < 0:
        return 12   # 期限切れ
    elif delta == 0:
        return 10   # 今日
    elif delta == 1:
        return 8    # 明日
    elif delta <= 3:
        return 6    # 2-3日後
    elif delta <= 7:
        return 4    # 今週
    else:
        return 1    # それ以降


def score_label(line: str) -> int:
    """ラベルスコア (#high/#medium/#low)"""
    if '#high' in line:
        return 10
    elif '#medium' in line:
        return 5
    elif '#low' in line:
        return 1
    return 3  # ラベルなし → 中間値


def is_blocked(line: str) -> bool:
    """#blocked または #waiting タグの確認"""
    return bool(re.search(r'#(blocked|waiting)', line))


def score_bug_boost(line: str) -> int:
    """+bug カテゴリのボーナス"""
    return 5 if '+bug' in line else 0


def compute_score(line: str) -> tuple[int, str]:
    """
    タスクのトータルスコアを計算。
    blocked タスクはスコア -1（最下位）。
    """
    if is_blocked(line):
        return (-1, line)

    total = (
        score_priority(line) * W_PRIORITY
        + score_urgency(line) * W_URGENCY
        + score_label(line) * W_LABEL
        + score_bug_boost(line) * W_BUG_BOOST
    )
    return (total, line)


def read_tasks(filepath: str) -> list[str]:
    """ファイルからペンディングタスクを読み込む"""
    tasks = []
    try:
        with open(filepath, encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                stripped = line.strip()
                # コメント・空行・完了行をスキップ
                if not stripped or stripped.startswith('#'):
                    continue
                if re.match(r'^x \d{4}-\d{2}-\d{2}', stripped):
                    continue
                tasks.append(line)
    except FileNotFoundError:
        pass
    return tasks


def dedup(tasks: list[str]) -> list[str]:
    """GH#番号とタイトルで重複除去"""
    seen_gh: dict[str, bool] = {}
    seen_title: dict[str, bool] = {}
    result = []

    for task in tasks:
        gh_match = re.search(r'GH#(\d+)', task)
        gh_num = gh_match.group(1) if gh_match else None

        # タイトル抽出（メタデータを除く）
        title = re.sub(r'^\([ABC]\)\s*', '', task.strip())
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

        result.append(task)

    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: prioritize.py <task_file> [<task_file2> ...]", file=sys.stderr)
        sys.exit(1)

    all_tasks: list[str] = []
    for filepath in sys.argv[1:]:
        all_tasks.extend(read_tasks(filepath))

    # 重複除去
    all_tasks = dedup(all_tasks)

    # スコアリング & ソート（降順）
    scored = [compute_score(task) for task in all_tasks]
    scored.sort(key=lambda x: x[0], reverse=True)

    for _, task in scored:
        print(task)


if __name__ == '__main__':
    main()
