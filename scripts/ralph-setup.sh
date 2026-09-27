#!/bin/bash
# ralph-loop の作業環境を用意する。
#   usage: scripts/ralph-setup.sh [統合ブランチ] [起点ブランチ]
# 制御用 1 枠 + 作業スロット 2 枠の worktree をリポジトリの隣に作る。
set -euo pipefail

INTEGRATION="${1:-ralph/integration}"
BASE="${2:-develop}"

REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
PARENT=$(dirname "$REPO_ROOT")
CTL="$PARENT/${REPO_NAME%-ios}-ralph-ctl"
SLOT_A="$PARENT/${REPO_NAME%-ios}-ralph-a"
SLOT_B="$PARENT/${REPO_NAME%-ios}-ralph-b"

cd "$REPO_ROOT"
git fetch origin --quiet

# 統合ブランチ（無ければ起点から作る）
if git show-ref --verify --quiet "refs/heads/$INTEGRATION"; then
  echo "既存のブランチを使います: $INTEGRATION"
else
  git branch "$INTEGRATION" "origin/$BASE"
  echo "ブランチを作成しました: $INTEGRATION (起点 origin/$BASE)"
fi

# worktree（制御用は統合ブランチを checkout、スロットは detached）
[[ -d "$CTL"    ]] || git worktree add "$CTL" "$INTEGRATION"
[[ -d "$SLOT_A" ]] || git worktree add --detach "$SLOT_A" "$INTEGRATION"
[[ -d "$SLOT_B" ]] || git worktree add --detach "$SLOT_B" "$INTEGRATION"

# ループの作業ファイルは git に載せない（.gitignore は汚さない）
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
grep -qxF '.claude/*.local.md' "$EXCLUDE" 2>/dev/null || echo '.claude/*.local.md' >> "$EXCLUDE"

# テンプレートを制御用 worktree へ配置
mkdir -p "$CTL/.claude"
[[ -f "$CTL/.claude/ralph-playbook.local.md" ]] \
  || cp .claude/ralph/playbook.template.md "$CTL/.claude/ralph-playbook.local.md"
[[ -f "$CTL/.claude/ralph-goal.local.md" ]] \
  || cp .claude/ralph/goal.template.md "$CTL/.claude/ralph-goal.local.md"
[[ -f "$CTL/.claude/settings.local.json" ]] \
  || cp .claude/ralph/settings.deny.example.json "$CTL/.claude/settings.local.json"

cat <<MSG

セットアップ完了

  制御用   $CTL
  スロット $SLOT_A
           $SLOT_B

次の手順:
  1. $CTL/.claude/ralph-playbook.local.md の {{...}} をすべて置き換える
  2. $CTL/.claude/ralph-goal.local.md にタスクを書く
  3. $CTL/.claude/settings.local.json の保護ブランチ名を確認する
  4. git push -u origin $INTEGRATION
  5. cd $CTL && ../${REPO_NAME}/scripts/ralph-start.sh "<完了語>"
MSG
