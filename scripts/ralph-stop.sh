#!/bin/bash
# ralph-loop を停止して後片付けする。制御用 worktree で実行すること。
#   usage: scripts/ralph-stop.sh [--worktrees]
# state ファイルを消すと、次にセッションが終了しようとした時点でループが抜ける。
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

STATE=".claude/ralph-loop.local.md"

if [[ -f "$STATE" ]]; then
  ITER=$(grep '^iteration:' "$STATE" | sed 's/iteration: *//')
  rm "$STATE"
  echo "ループを停止しました（イテレーション $ITER で終了）"
else
  echo "実行中のループはありません"
fi

if [[ "${1:-}" == "--worktrees" ]]; then
  ROOT=$(git rev-parse --show-toplevel)
  for slot in "${ROOT%-ctl}-a" "${ROOT%-ctl}-b"; do
    [[ -d "$slot" ]] && git worktree remove "$slot" && echo "削除: $slot"
  done
  echo "制御用 worktree は goal / state を保持しているため残しています"
fi

cat <<'MSG'

後片付けの確認:
  - ~/.claude/settings.json の skipDangerousModePermissionPrompt を戻すか検討する
    （残っていると bypassPermissions が警告なしで起動します）
MSG
