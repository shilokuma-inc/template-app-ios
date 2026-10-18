#!/bin/bash
set -euo pipefail

# App Store のクリエイティブアセット（プロダクトページのヘッダー / 検索結果）を書き出す。
#
#   Tools/render_creative_assets.sh [6.9 inch のスクリーンショットのフォルダ] [アプリ名]
#
# 元は AppStore/creative/src/creative.html。画面の画像には 6.9 inch のスクリーンショット
# （Tools/capture_screenshots.sh APP_IPHONE_67 の出力か、Screenshots/App Store ワークフローの artifact。
#  既定は build/screenshots/APP_IPHONE_67）を、AppStore/screenshots.json の scenes の順に使う。
# アプリアイコンは AppStore/app.json の appIcon。アプリ名は省略すると .xcodeproj の名前を使う。
# Google Chrome をヘッドレスで開いて実寸で撮り、アルファを落として AppStore/creative/<言語>/ に保存する。
# 書き出したら差分を見てコミットし、Creative assets/App Store ワークフローで反映する。

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="python3 Tools/app_store_config.py"
SCREENSHOTS="${1:-build/screenshots/APP_IPHONE_67}"
APP_NAME="${2:-$($CONFIG app scheme)}"
APP_ICON="$($CONFIG app appIcon)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SOURCE="AppStore/creative/src/creative.html"
OUTPUT_DIR="AppStore/creative"

if [ ! -x "$CHROME" ]; then
    echo "Google Chrome が見つかりません（CHROME で場所を指定できます）: $CHROME" >&2
    exit 1
fi
if [ -z "$APP_ICON" ] || [ ! -f "$APP_ICON" ]; then
    echo "アプリアイコンが見つかりません。AppStore/app.json の appIcon を確かめてください: ${APP_ICON:-（未設定）}" >&2
    exit 1
fi
if grep -q '"TODO:' "$SOURCE"; then
    echo "注意: $SOURCE に仮の文言（\"TODO: …）が残っています（このままでは App Store Connect に反映できません）" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$SOURCE" "$WORK/creative.html"
cp "$APP_ICON" "$WORK/icon.png"

REMOVE_ALPHA="$WORK/remove_alpha"
xcrun swiftc -O Tools/remove_alpha.swift -o "$REMOVE_ALPHA"

# screenshots.json の scenes の順（先頭が真ん中の端末に載る）
SCREENS="$($CONFIG scenes | cut -f1 | paste -sd, -)"

# 書き出す種類: <type> <ファイル名> <幅> <高さ>（寸法は AppStore/creative_assets.json の説明を参照）
TARGETS="header header.png 3840 1646
search search_results.png 3840 2560"

while IFS=$'\t' read -r -u 3 language _ _ _; do
    # creative.html の copy に、その言語の文言が無いと崩れた画像になる
    if ! grep -Eq "^    ${language}: \{" "$SOURCE"; then
        echo "$SOURCE の copy に $language の文言がありません。" >&2
        exit 1
    fi
    if [ ! -d "$SCREENSHOTS/$language" ]; then
        echo "$SCREENSHOTS/$language がありません。先に Tools/capture_screenshots.sh APP_IPHONE_67 で撮ってください。" >&2
        exit 1
    fi
    # 画像が欠けていると、Chrome はリンク切れのまま実寸で書き出してしまう（寸法の検査では気づけない）
    for screen in ${SCREENS//,/ }; do
        if [ ! -f "$SCREENSHOTS/$language/$screen.png" ]; then
            echo "$SCREENSHOTS/$language/$screen.png がありません。screenshots.json の scenes を全部撮ってください。" >&2
            exit 1
        fi
    done
    mkdir -p "$WORK/screens/$language" "$OUTPUT_DIR/$language"
    cp "$SCREENSHOTS/$language"/*.png "$WORK/screens/$language/"

    while read -r type file width height; do
        output="$OUTPUT_DIR/$language/$file"
        query="type=$type&lang=$language&screens=$SCREENS&name=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$APP_NAME")"
        "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
            --allow-file-access-from-files --virtual-time-budget=3000 \
            --window-size="$width,$height" --screenshot="$ROOT_DIR/$output" \
            "file://$WORK/creative.html?$query" >/dev/null 2>&1
        "$REMOVE_ALPHA" "$output"
        actual="$(sips -g pixelWidth -g pixelHeight "$output" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
        if [ "$actual" != "${width}x${height}" ]; then
            echo "$output の寸法が ${width}x${height} ではありません（$actual）" >&2
            exit 1
        fi
        echo "$output（$actual）"
    done <<< "$TARGETS"
done 3< <($CONFIG languages)
