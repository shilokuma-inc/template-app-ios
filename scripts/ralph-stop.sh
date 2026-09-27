#!/bin/bash
# ralph-loop を停止して後片付けする。制御用 worktree で実行すること。
#   usage: scripts/ralph-stop.sh [--worktrees]
# state ファイルを消すと、次にセッションが終了しようとした時点でループが抜ける。
# --worktrees はセッションの終了後に使う。実行中のループを止めたのと同じ呼び出しでは
# スロットを消さない（そのイテレーションがまだスロットで作業しているため）。
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

STATE=".claude/ralph-loop.local.md"

WAS_RUNNING=false
if [[ -f "$STATE" ]]; then
  ITER=$(grep '^iteration:' "$STATE" | sed 's/iteration: *//')
  rm "$STATE"
  WAS_RUNNING=true
  echo "ループを停止しました（イテレーション $ITER で終了）"
else
  echo "実行中のループはありません"
fi

if [[ "${1:-}" == "--worktrees" ]]; then
  ROOT=$(git rev-parse --show-toplevel)
  SLOTS=("${ROOT%-ctl}-a" "${ROOT%-ctl}-b")
  # state を消してもイテレーションはすぐには終わらない。作業中のスロットを消すと
  # セッションの作業が途中で壊れるので、ここでは消さずに別手順にする。
  BUSY=""
  if $WAS_RUNNING; then
    BUSY="いま停止したループのイテレーションが終わっていない可能性があります"
  else
    # 起動コマンドは --add-dir でスロットを渡すので、引数にスロット名を含む claude を探す
    for slot in "${SLOTS[@]}"; do
      if pgrep -f "claude.*$(basename "$slot")" >/dev/null 2>&1; then
        BUSY="$(basename "$slot") を使う claude のプロセスが残っています"
        break
      fi
    done
  fi
  if [[ -n "$BUSY" ]]; then
    echo "スロットの worktree は削除していません: $BUSY" >&2
    echo "  Claude のセッションが終了したのを確認してから、もう一度実行してください:" >&2
    echo "    scripts/ralph-stop.sh --worktrees" >&2
  else
    for slot in "${SLOTS[@]}"; do
      [[ -d "$slot" ]] && git worktree remove "$slot" && echo "削除: $slot"
    done
    echo "制御用 worktree は goal / state を保持しているため残しています"
  fi
fi

cat <<'MSG'

後片付けの確認:
  - ~/.claude/settings.json の skipDangerousModePermissionPrompt を戻すか検討する
    （残っていると bypassPermissions が警告なしで起動します）
MSG
