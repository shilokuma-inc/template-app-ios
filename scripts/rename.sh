#!/bin/bash
#
# テンプレートのプロジェクト名（IOSTemplateApp）を新しいアプリ名に一括変更する。
#
# 使い方:
#   scripts/rename.sh <NewAppName> [owner/repo]
#
#   NewAppName  新しいプロジェクト名。英字で始まる英数字のみ（例: MyApp）
#   owner/repo  README のバッジ URL に使う GitHub リポジトリ。省略時は origin から推定する
#
# 実行後に行うこと:
#   - Configs/Project.xcconfig の DEVELOPMENT_TEAM / APP_BUNDLE_IDENTIFIER を書き換える
#   - 差分を確認してコミットする
#
set -euo pipefail

OLD_NAME="IOSTemplateApp"
OLD_REPO="shilokuma-inc/template-app-ios"

NEW_NAME="${1:-}"
if [[ ! "$NEW_NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
  echo "usage: $0 <NewAppName> [owner/repo]" >&2
  echo "  NewAppName は英字で始まる英数字のみ（例: MyApp）" >&2
  exit 1
fi
if [[ "$NEW_NAME" == "$OLD_NAME" ]]; then
  echo "新しい名前が現在の名前と同じです: $NEW_NAME" >&2
  exit 1
fi

NEW_REPO="${2:-}"
if [[ -z "$NEW_REPO" ]]; then
  NEW_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##' || true)
fi
if [[ ! "$NEW_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "GitHub リポジトリ（owner/repo）を特定できません。第 2 引数で指定してください" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "作業ツリーに未コミットの変更があります。コミットまたは退避してから実行してください" >&2
  exit 1
fi

echo "==> $OLD_NAME -> $NEW_NAME / $OLD_REPO -> $NEW_REPO"

# 1) パスに旧名を含むファイルを新しいパスへ移動する（深い階層から順に）
echo "==> ファイル・ディレクトリをリネーム"
while IFS= read -r -d '' path; do
  new_path="${path//$OLD_NAME/$NEW_NAME}"
  mkdir -p "$(dirname "$new_path")"
  git mv "$path" "$new_path"
  echo "  $path -> $new_path"
done < <(git ls-files -z | grep -z "$OLD_NAME" | sort -z -r)

# 移動後にファイルが残っていない旧ディレクトリを削除する（空のサブディレクトリごと）
find . -depth -type d -name "*${OLD_NAME}*" -not -path "./.git/*" | while IFS= read -r dir; do
  if [[ -z "$(find "$dir" -type f -print -quit)" ]]; then
    rm -r "$dir"
  fi
done

# 2) ファイル内容の旧名・旧リポジトリを置換する（バイナリは対象外）
echo "==> ファイル内容を置換"
git ls-files -z \
  | xargs -0 grep -Il -e "$OLD_NAME" -e "$OLD_REPO" 2>/dev/null \
  | grep -v "^scripts/rename.sh$" \
  | while IFS= read -r file; do
      perl -pi -e "s/\Q$OLD_NAME\E/$NEW_NAME/g; s#\Q$OLD_REPO\E#$NEW_REPO#g" "$file"
      echo "  $file"
    done

echo
echo "完了しました。続けて以下を行ってください:"
echo "  1. Configs/Project.xcconfig の DEVELOPMENT_TEAM と APP_BUNDLE_IDENTIFIER を書き換える"
echo "  2. git diff で差分を確認し、コミットする"
