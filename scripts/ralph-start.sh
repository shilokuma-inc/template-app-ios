#!/bin/bash
# ralph-loop の state ファイルを生成する。制御用 worktree で実行すること。
#   usage: scripts/ralph-start.sh 完了語 [max_iterations]
# max_iterations の既定は 0（無制限）。0 で回す場合、playbook の
# 「詰まったときの扱い」が書かれていないと無限ループになるので必ず確認する。
set -euo pipefail

PROMISE="${1:-}"
MAX="${2:-0}"
# "00" が 0 判定をすり抜けたり、"abc" が Stop hook に弾かれる state を書くのを防ぐ
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "max_iterations は 0 以上の整数で指定してください（指定: $MAX）" >&2; exit 1; }
MAX=$((10#$MAX))
STATE=".claude/ralph-loop.local.md"
GOAL=".claude/ralph-goal.local.md"
PLAYBOOK=".claude/ralph-playbook.local.md"

[[ -n "$PROMISE" ]] || { echo "完了語を指定してください（例: PHASE1 DONE）" >&2; exit 1; }
[[ -f "$GOAL"     ]] || { echo "$GOAL がありません" >&2; exit 1; }
[[ -f "$PLAYBOOK" ]] || { echo "$PLAYBOOK がありません" >&2; exit 1; }
[[ -f "$STATE"    ]] && { echo "ループが実行中です。停止するには scripts/ralph-stop.sh" >&2; exit 1; }

LEFTOVER=$(grep -o '{{[A-Z_][A-Z_]*}}' "$PLAYBOOK" | sort -u || true)
if [[ -n "$LEFTOVER" ]]; then
  echo "$PLAYBOOK に未置換のプレースホルダが残っています:" >&2
  echo "$LEFTOVER" >&2
  exit 1
fi

TASKS=$(grep -c '^- \[ \]' "$GOAL" || true)
[[ "$TASKS" -gt 0 ]] || { echo "$GOAL に未完了タスクがありません" >&2; exit 1; }

# 見出しだけでは足りない。無制限運用の安全性は 2 つの手順の実体に依存する
if [[ "$MAX" -eq 0 ]]; then
  missing=""
  grep -q '詰まったときの扱い' "$PLAYBOOK" || missing="$missing\n  - 「詰まったときの扱い」の節"
  grep -q '※保留'              "$PLAYBOOK" || missing="$missing\n  - 着手不能なタスクを保留として閉じる手順"
  grep -q '5イテレーション'      "$PLAYBOOK" || missing="$missing\n  - 無進捗が続いたときに自分で停止する手順"
  if [[ -n "$missing" ]]; then
    echo "max_iterations=0 で回すには playbook に次が必要です:" >&2
    printf "$missing\n" >&2
    echo "（どれか欠けると着手不能なタスクで無限ループになります）" >&2
    exit 1
  fi
fi

cat > "$STATE" <<STATE_EOF
---
active: true
iteration: 1
session_id:
max_iterations: $MAX
completion_promise: "$PROMISE"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PLAYBOOK を読み、そこに書かれた手順を厳密に実行する。1ステップも省略しない。
ゴールは $GOAL に展開済みなので STEP A は不要。

完了条件を満たしたときだけ <promise>$PROMISE</promise> を出力すること。
行き詰まったからといって、条件が真でないのに promise を出してはならない。
STATE_EOF

echo "未完了タスク $TASKS 件 / 上限 $([[ "$MAX" -eq 0 ]] && echo '無制限' || echo "$MAX") / 完了語 $PROMISE"
echo
echo "起動コマンド（スロットのパスは環境に合わせて調整）:"
echo "  claude --add-dir ../\$(basename \$PWD | sed 's/-ctl\$/-a/') \\"
echo "         --add-dir ../\$(basename \$PWD | sed 's/-ctl\$/-b/') \\"
echo "         --permission-mode bypassPermissions \\"
echo "         \"\$(sed -n '/^---\$/,/^---\$/!p' $STATE | sed '/^\$/d' | head -20)\""
