#!/bin/bash
# ralph-loop の作業環境を用意する。
#   usage: scripts/ralph-setup.sh epic/機能名 [起点ブランチ]
# 統合ブランチはテーマ単位で `epic/[機能名]` の形式にする（例: epic/monetization）。
# 制御用 1 枠 + 作業スロット 2 枠の worktree をリポジトリの隣に作る。
set -euo pipefail

# Git hook や wrapper から継承した経路変数が別のチェックアウトを指すことがある
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

INTEGRATION="${1:-}"
if [[ -z "$INTEGRATION" ]]; then
  echo "統合ブランチ名を指定してください（例: epic/monetization）" >&2
  exit 1
fi
if [[ "$INTEGRATION" != epic/* ]]; then
  echo "統合ブランチは epic/[機能名] の形式にしてください（指定: $INTEGRATION）" >&2
  exit 1
fi
BASE="${2:-develop}"

REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
PARENT=$(dirname "$REPO_ROOT")
CTL="$PARENT/${REPO_NAME%-ios}-ralph-ctl"
SLOT_A="$PARENT/${REPO_NAME%-ios}-ralph-a"
SLOT_B="$PARENT/${REPO_NAME%-ios}-ralph-b"

cd "$REPO_ROOT"
git remote get-url origin >/dev/null 2>&1 \
  || { echo "リモート origin がありません。先に origin を設定してください" >&2; exit 1; }
git fetch origin --quiet \
  || { echo "origin への fetch に失敗しました。ネットワークとアクセス権を確認してください" >&2; exit 1; }
git rev-parse --verify --quiet "origin/$BASE" >/dev/null \
  || { echo "origin/$BASE が見つかりません。起点ブランチ名を確認してください" >&2; exit 1; }

# 統合ブランチ（無ければ起点から作る）
if git show-ref --verify --quiet "refs/heads/$INTEGRATION"; then
  echo "既存のブランチを使います: $INTEGRATION"
else
  git branch "$INTEGRATION" "origin/$BASE"
  echo "ブランチを作成しました: $INTEGRATION (起点 origin/$BASE)"
fi

# worktree（制御用は統合ブランチを checkout、スロットは detached）
# ディレクトリが在るだけでは足りない。無関係なディレクトリを worktree と誤認して
# そこへ Claude のアクセス権を渡してしまうため、登録済みかどうかで判定する。
is_worktree() { git worktree list --porcelain | grep -qxF "worktree $1"; }
add_worktree() { # $1=パス $2=追加オプション
  local path="$1"; shift
  if is_worktree "$path"; then
    echo "既存の worktree を使います: $path"
  elif [[ -e "$path" ]]; then
    echo "エラー: $path は worktree ではありません。別の場所へ退避してください" >&2
    exit 1
  else
    git worktree add "$@" "$path" "$INTEGRATION"
  fi
}
# 制御用 worktree は固定パスなので、別の epic を指定しても登録済みという理由だけで
# 再利用されてしまう。前の epic の goal / state が残ったまま走るのを防ぐ。
if is_worktree "$CTL"; then
  CURRENT=$(git -C "$CTL" symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")
  if [[ "$CURRENT" != "$INTEGRATION" ]]; then
    cat >&2 <<ERR
エラー: 制御用 worktree は別の epic のものです
      パス:   $CTL
      現在:   $CURRENT
      要求:   $INTEGRATION

      前の epic の goal / state がそのまま残っています。終わっているなら
      片付けてから実行してください:
        cd "$CTL" && ../$(basename "$REPO_ROOT")/scripts/ralph-stop.sh
        git worktree remove "$CTL"
ERR
    exit 1
  fi
fi

add_worktree "$CTL"
add_worktree "$SLOT_A" --detach
add_worktree "$SLOT_B" --detach

# ループの作業ファイルは git に載せない（.gitignore は汚さない）
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
grep -qxF '.claude/*.local.md' "$EXCLUDE" 2>/dev/null || echo '.claude/*.local.md' >> "$EXCLUDE"

# テンプレートを制御用 worktree へ配置
mkdir -p "$CTL/.claude"
LOCAL_PB="$CTL/.claude/ralph-playbook.local.md"
if [[ -f "$LOCAL_PB" ]]; then
  # テンプレートは初回しかコピーしない（置換済みの playbook を壊さないため）。
  # そのため改善が既存の制御用 worktree に届かない。見出し単位で不足を報告する。
  MISSING=$(comm -23 \
    <(grep -E '^#{2,3} ' .claude/ralph/playbook.template.md | sort -u) \
    <(grep -E '^#{2,3} ' "$LOCAL_PB" | sort -u) || true)
  if [[ -n "$MISSING" ]]; then
    echo "注意: 既存の playbook にテンプレートの節がありません。手で取り込んでください:" >&2
    echo "$MISSING" | sed 's/^/      /' >&2
    echo "      元: $REPO_ROOT/.claude/ralph/playbook.template.md" >&2
  fi
else
  cp .claude/ralph/playbook.template.md "$LOCAL_PB"
fi
[[ -f "$CTL/.claude/ralph-goal.local.md" ]] \
  || cp .claude/ralph/goal.template.md "$CTL/.claude/ralph-goal.local.md"
[[ -f "$CTL/.claude/ralph-state.local.md" ]] \
  || cp .claude/ralph/state.template.md "$CTL/.claude/ralph-state.local.md"
# deny リストは制御用 worktree にだけ置く。リポジトリにコミットすると
# gh pr create --base <base> の deny が通常開発の PR 作成まで塞いでしまう。
if git ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  echo "警告: .claude/settings.json が git 管理下にあります。deny リストは手で統合してください" >&2
elif [[ ! -f "$CTL/.claude/settings.json" ]]; then
  cp .claude/ralph/settings.deny.example.json "$CTL/.claude/settings.json"
  grep -qxF '.claude/settings.json' "$EXCLUDE" 2>/dev/null \
    || echo '.claude/settings.json' >> "$EXCLUDE"
fi

# CLAUDE.md は毎セッション読み込まれる唯一の入口。ポインタが無いと、
# 文脈を持たない新しいセッションが ralph-loop の存在に気づけない。
# 語の有無ではなく、スニペット固有の見出しで判定する。別文脈の "ralph-loop" で
# 警告が消えるのを避けるため。見出しはスニペット側から読み、定義の二重化を避ける。
MARKER=$(grep -m1 '^## ' .claude/ralph/CLAUDE.snippet.md 2>/dev/null || true)
MARKER=${MARKER:-'## ralph-loop による自律開発'}
if [[ ! -f CLAUDE.md ]] || ! grep -qF "$MARKER" CLAUDE.md; then
  echo "警告: CLAUDE.md に ralph-loop の記載がありません。" >&2
  echo "      .claude/ralph/CLAUDE.snippet.md を CLAUDE.md に追記してください" >&2
  echo "      （無いと、新しいセッションがこの仕組みに気づけません）" >&2
fi

cat <<MSG

セットアップ完了

  制御用   $CTL
  スロット $SLOT_A
           $SLOT_B

次の手順:
  1. $CTL/.claude/ralph-playbook.local.md の {{...}} をすべて置き換える
  2. $CTL/.claude/ralph-goal.local.md にタスクを書く
  3. $CTL/.claude/settings.json の保護ブランチ名を確認する
  4. git push -u origin $INTEGRATION
  5. cd $CTL && ../${REPO_NAME}/scripts/ralph-start.sh "PHASE1 DONE"   # 完了語は任意
MSG
