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
  echo "統合ブランチは epic/[機能名] の形式にしてください（指定: ${INTEGRATION}）" >&2
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

# AskHub のプロトコルのラベル（shilokuma-inc/ask-hub-apple の docs/protocol.md）。
# ループが ask・判断ログ・実機確認に付け、AskHub とオーケストレーターがこれで集める。無ければ作る
if command -v gh >/dev/null 2>&1; then
  while IFS='|' read -r name color description; do
    # 既にあるラベルの作成は失敗するので、失敗したら一覧で有無を確かめる（set -e で止めないよう if で受ける）
    if error=$(gh label create "$name" --color "$color" --description "$description" 2>&1); then
      echo "ラベルを作成しました: $name"
    elif ! gh label list --limit 1000 --json name --jq '.[].name' | grep -Fqx -- "$name"; then
      echo "エラー: ラベルを作成も確認もできませんでした: $name" >&2
      printf '%s\n' "$error" >&2
      exit 1
    fi
  done <<'LABELS'
needs-answer|D93F0B|人間の回答を待っている質問がある
ready-for-loop|0E8A16|Discussion の回答が確定し、ループを始めてよい
idea-request|5319E7|アプリから出した新機能の依頼
decision-log|1D76DB|epic ごとの仮決め一覧（判断ログ）
needs-verify|FBCA04|実機・実データでの確認が必要
epic-final|B60205|epic から develop への最終 PR
LABELS
else
  echo "警告: gh が無いため、AskHub のラベルを確認できませんでした" >&2
fi

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
# checkout 中のブランチ（refs/heads/...）を返す。detached なら空
worktree_branch() {
  git worktree list --porcelain | awk -v wt="worktree $1" '
    $0 == wt { found = 1; next }
    found && /^branch / { print $2; exit }
    found && $0 == "" { exit }'
}
add_worktree() { # $1=パス $2=追加オプション
  local path="$1"; shift
  if is_worktree "$path"; then
    # 制御用が別の統合ブランチのままだと、ループが古いテーマの上で動いてしまう。
    # 作業を失わないよう自動では切り替えず、人に判断させる。
    # スロットは detached で、タスクごとに origin/<統合ブランチ> から切り直すので見ない。
    if [[ "$path" == "$CTL" ]]; then
      local current
      current=$(worktree_branch "$path")
      if [[ "$current" != "refs/heads/$INTEGRATION" ]]; then
        echo "エラー: 既存の制御用 worktree が $INTEGRATION を checkout していません（現在: ${current:+${current#refs/heads/}}${current:-detached HEAD}）" >&2
        echo "      作業を退避したうえで $path で $INTEGRATION を checkout するか、" >&2
        echo "      git worktree remove で削除してから再実行してください" >&2
        exit 1
      fi
    fi
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
# 既存の settings.json にテンプレートの deny が欠けていたら止める。
# bypassPermissions で動くループにとって、deny は禁止操作を止める最初の層だから
check_deny() {
  local settings="$1"
  command -v jq >/dev/null 2>&1 \
    || { echo "エラー: jq が必要です（$settings の deny の検査に使います）" >&2; exit 1; }
  local missing
  missing=$(jq -r --slurpfile have "$settings" \
    '.permissions.deny - ($have[0].permissions.deny // []) | .[]' \
    .claude/ralph/settings.deny.example.json) \
    || { echo "エラー: $settings を JSON として読めません" >&2; exit 1; }
  if [[ -n "$missing" ]]; then
    echo "エラー: $settings に次の deny がありません。統合してから再実行してください:" >&2
    echo "$missing" | sed 's/^/      /' >&2
    exit 1
  fi
}

# deny リストは制御用 worktree にだけ置く。リポジトリにコミットすると
# gh pr create --base <base> の deny が通常開発の PR 作成まで塞いでしまう。
if git ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  echo "警告: .claude/settings.json が git 管理下にあります。deny リストは手で統合してください" >&2
  # git 管理下でも、制御用 worktree で効く設定に deny が揃っていなければ止める
  if [[ -f "$CTL/.claude/settings.json" ]]; then
    check_deny "$CTL/.claude/settings.json"
  else
    echo "エラー: $CTL/.claude/settings.json がありません。deny リストを統合してから再実行してください" >&2
    exit 1
  fi
else
  if [[ -f "$CTL/.claude/settings.json" ]]; then
    check_deny "$CTL/.claude/settings.json"
  else
    cp .claude/ralph/settings.deny.example.json "$CTL/.claude/settings.json"
  fi
  # 既存の settings.json も git 管理外なら除外する。コピーした時だけにすると、
  # 手で置いた settings.json が git add -A で統合ブランチに載ってしまう
  grep -qxF '.claude/settings.json' "$EXCLUDE" 2>/dev/null \
    || echo '.claude/settings.json' >> "$EXCLUDE"
fi

# CLAUDE.md は毎セッション読み込まれる唯一の入口。ポインタが無いと、
# 文脈を持たない新しいセッションが ralph-loop の存在に気づけない。
# 語の有無ではなく、スニペット固有の見出しで判定する。別文脈の "ralph-loop" で
# 警告が消えるのを避けるため。見出しはスニペット側から読み、定義の二重化を避ける。
# ループのセッションは制御用 worktree で起動するので、実行元ではなくそちらの CLAUDE.md を見る。
# 実行元のブランチにだけ記載があっても、統合ブランチに無ければ新しいセッションには届かない。
MARKER=$(grep -m1 '^## ' .claude/ralph/CLAUDE.snippet.md 2>/dev/null || true)
MARKER=${MARKER:-'## ralph-loop による自律開発'}
if [[ ! -f "$CTL/CLAUDE.md" ]] || ! grep -qF "$MARKER" "$CTL/CLAUDE.md"; then
  echo "警告: 制御用 worktree の CLAUDE.md に ralph-loop の記載がありません（${INTEGRATION}）。" >&2
  echo "      .claude/ralph/CLAUDE.snippet.md を $INTEGRATION の CLAUDE.md に追記してください" >&2
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
  3. プロジェクト固有の保護ブランチがあれば、$CTL/.claude/settings.json の deny に追加する（テンプレートの deny は消さない）
  4. git push -u origin $INTEGRATION
  5. cd $CTL && ../${REPO_NAME}/scripts/ralph-start.sh "PHASE1 DONE"   # 完了語は任意
MSG
