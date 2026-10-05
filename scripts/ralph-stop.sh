#!/bin/bash
# ralph-loop を停止して後片付けする。制御用 worktree で実行すること。
#   usage: scripts/ralph-stop.sh [--worktrees]
# state ファイルを消すと、次にセッションが終了しようとした時点でループが抜ける。
# --worktrees はセッションの終了後に使う。実行中のループを止めたのと同じ呼び出しでは
# スロットを消さない（そのイテレーションがまだスロットで作業しているため）。
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

# 制御用 worktree のサブディレクトリから実行しても、worktree の直下の state を見る
ROOT=$(git rev-parse --show-toplevel)
STATE="$ROOT/.claude/ralph-loop.local.md"

WAS_RUNNING=false
FAILED=false
if [[ -f "$STATE" ]]; then
  ITER=$(grep '^iteration:' "$STATE" | sed 's/iteration: *//')
  rm "$STATE"
  WAS_RUNNING=true
  echo "ループを停止しました（イテレーション $ITER で終了）"
else
  echo "実行中のループはありません"
fi

if [[ "${1:-}" == "--worktrees" ]]; then
  SLOTS=("${ROOT%-ctl}-a" "${ROOT%-ctl}-b")
  # state を消してもイテレーションはすぐには終わらない。作業中のスロットを消すと
  # セッションの作業が途中で壊れるので、ここでは消さずに別手順にする。
  BUSY=""
  if $WAS_RUNNING; then
    BUSY="いま停止したループのイテレーションが終わっていない可能性があります"
  else
    # ループは手で起動しても起動スクリプト（askhub-start-loop）から起動しても、スロットを --add-dir で渡す
    # （手では ralph-start.sh が表示する ../<スロット名>、起動スクリプトからは絶対パス）。
    # 実行ファイル名（claude とは限らない）ではなく、--add-dir の値がこのスロットを指すプロセスを探す。
    # pgrep -f は正規表現なので、パスのメタ文字はエスケープして字面どおりに照合する（空白を含むパスもそのまま一致する）
    # macOS の pgrep は既定で自分の祖先を結果から除く。ループの Claude（祖先）の中からこのスクリプトを実行すると、
    # そのセッションを見落としてスロットを消してしまうので、-a で祖先も含める（Linux の -a は意味が違うので付けない）
    PGREP=(pgrep -f)
    [[ "$(uname)" == Darwin ]] && PGREP=(pgrep -a -f)
    escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
    for slot in "${SLOTS[@]}"; do
      absolute=$(escape "$slot")
      relative=$(escape "../$(basename "$slot")")
      if "${PGREP[@]}" -- "--add-dir[ =]($absolute|$relative)( |\$)" >/dev/null 2>&1; then
        BUSY="$(basename "$slot") を --add-dir で使うプロセスが残っています"
        break
      fi
    done
  fi
  if [[ -n "$BUSY" ]]; then
    echo "スロットの worktree は削除していません: $BUSY" >&2
    echo "  そのプロセスが終了したのを確認してから、もう一度実行してください:" >&2
    echo "    scripts/ralph-stop.sh --worktrees" >&2
  else
    for slot in "${SLOTS[@]}"; do
      [[ -d "$slot" ]] || continue
      if git worktree remove "$slot"; then
        echo "削除: $slot"
      else
        echo "削除に失敗しました: $slot" >&2
        FAILED=true
      fi
    done
    echo "制御用 worktree は goal / state を保持しているため残しています"
  fi
fi

cat <<'MSG'

後片付けの確認:
  - ~/.claude/settings.json の skipDangerousModePermissionPrompt を戻すか検討する
    （残っていると bypassPermissions が警告なしで起動します）
MSG

if $FAILED; then
  echo "スロットの worktree の削除が完了していません。上のエラーを確認してください" >&2
  exit 1
fi
