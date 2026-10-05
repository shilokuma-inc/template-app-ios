#!/bin/bash
# ralph-loop の state ファイルを生成する。制御用 worktree で実行すること。
#   usage: scripts/ralph-start.sh 完了語 [max_iterations]
# max_iterations の既定は 0（無制限）。0 で回す場合、playbook の
# 「詰まったときの扱い」が書かれていないと無限ループになるので必ず確認する。
set -euo pipefail

# Git hook や wrapper から継承した経路変数が別のチェックアウトを指すことがある
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

PROMISE="${1:-}"
MAX="${2:-0}"
# "00" が 0 判定をすり抜けたり、"abc" が Stop hook に弾かれる state を書くのを防ぐ
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "max_iterations は 0 以上の整数で指定してください（指定: ${MAX}）" >&2; exit 1; }
MAX=$((10#$MAX))
# 制御用 worktree のサブディレクトリから実行しても、worktree の直下に state を置く
# （Stop hook はループの Claude の作業ディレクトリ＝制御用 worktree の直下を見る）
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
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
# goal.template.md の雛形のまま（{{日本語タイトル}} などが残る）でも未完了タスクの数は数えられてしまう。
# 起動すると STEP A を飛ばして雛形のタスクに着手するので、プレースホルダが残っていれば止める
GOAL_LEFTOVER=$(grep -o '{{[^}]*}}' "$GOAL" | sort -u || true)
if [[ -n "$GOAL_LEFTOVER" ]]; then
  echo "$GOAL に未置換のプレースホルダが残っています（雛形のままです）:" >&2
  echo "$GOAL_LEFTOVER" >&2
  exit 1
fi

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

# 周回は ralph-loop プラグインの Stop hook が回す。プラグインが無いと 1 周目で黙って終わるので、state を作る前に止める
RALPH_PLUGIN="ralph-loop@claude-plugins-official"
command -v jq >/dev/null 2>&1 || { echo "jq が見つかりません（brew install jq で入れてください）" >&2; exit 1; }
ralph_plugin_enabled() {
  local settings
  # Claude Code と同じく、優先度の高い設定（ローカル → プロジェクト → ユーザー）から見て、
  # このプラグインの値を最初に持つファイルで決める（上位の false を下位の true で覆さない）
  for settings in ".claude/settings.local.json" ".claude/settings.json" "$HOME/.claude/settings.json"; do
    [[ -f "$settings" ]] || continue
    if jq -e --arg plugin "$RALPH_PLUGIN" '.enabledPlugins | has($plugin)' "$settings" >/dev/null 2>&1; then
      jq -e --arg plugin "$RALPH_PLUGIN" '.enabledPlugins[$plugin] == true' "$settings" >/dev/null 2>&1
      return
    fi
  done
  return 1
}
ralph_plugin_enabled \
  || { echo "Claude Code の ${RALPH_PLUGIN} が有効になっていません（claude plugin install ${RALPH_PLUGIN} で入れてください）" >&2; exit 1; }

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
echo "注意: この制御用 worktree の中で、ほかの Claude Code セッションを開いたり cd したりしないこと。"
echo "      Stop hook に捕まり、そのセッションがループ本体として扱われる。"
echo
echo "起動コマンド（スロットのパスは環境に合わせて調整）:"
echo "  claude --add-dir ../\$(basename \$PWD | sed 's/-ctl\$/-a/') \\"
echo "         --add-dir ../\$(basename \$PWD | sed 's/-ctl\$/-b/') \\"
echo "         --permission-mode bypassPermissions \\"
echo "         \"\$(sed -n '/^---\$/,/^---\$/!p' $STATE | sed '/^\$/d' | head -20)\""
