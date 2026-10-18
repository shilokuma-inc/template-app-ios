#!/bin/bash
set -euo pipefail

# App Store 用のスクリーンショットを、1 つの表示サイズについて全言語・全画面ぶん撮る（iOS / iPadOS）。
#
#   Tools/capture_screenshots.sh APP_IPHONE_67 [ja,en]
#
# アプリのリポジトリのルートで実行する。撮る画面と機種は AppStore/screenshots.json、言語は
# AppStore/languages.json、プロジェクトと Scheme は AppStore/app.json で決める。
# 画面ごと・言語ごとにアプリを起動し直し、起動引数で「撮影モード」「最初に開く画面」「言語」を渡す:
#
#   -screenshot-demo -screenshot-scene <scene> -AppleLanguages (<言語>) -AppleLocale <ロケール>
#
# アプリ側はこの起動引数を読んで、デモデータで目的の画面を開く（IOSTemplateApp/Screenshot/ScreenshotDemo.swift）。
# 1 回ビルドしたものを使い回すので、言語を増やしても時間は大きく伸びない。
#
# 出力先: $SCREENSHOTS_DIR/<表示サイズ>/<言語>/01_….png …（既定は build/screenshots）

DISPLAY_TYPE="${1:?表示サイズ（例: APP_IPHONE_67）を指定してください}"
LANGUAGES="${2:-}"

TOOLS_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
cd "$TOOLS_DIR/.."
CONFIG="python3 $TOOLS_DIR/app_store_config.py"

PROJECT="$($CONFIG app project)"
SCHEME="${SCHEME:-$($CONFIG app scheme)}"
CONFIGURATION="${CONFIGURATION:-$($CONFIG app configuration)}"
SIMULATOR_PREFIX="$($CONFIG app simulatorPrefix)"
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-$PWD/build/screenshots}"
# DerivedData はリポジトリ外に置く。リポジトリ内に置くと、ビルドフェーズの SwiftLint が
# SPM 依存のソース（DerivedData/SourcePackages/checkouts）まで lint して、ビルドが失敗することがある
DERIVED_DATA="${DERIVED_DATA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/${SIMULATOR_PREFIX}ScreenshotDerivedData}"
# 起動してから画面が落ち着くまで待つ上限と、落ち着いたとみなすまでの最短の待ち（秒）
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-40}"
SETTLE_MINIMUM="${SETTLE_MINIMUM:-4}"
# 撮影の前の 1 回目の起動で待つ時間（秒）
WARMUP_SECONDS="${WARMUP_SECONDS:-15}"

if [ -n "$($CONFIG derive-from "$DISPLAY_TYPE")" ]; then
    echo "$DISPLAY_TYPE は deriveFrom で縮めて作る表示サイズなので撮りません（Tools/derive_screenshots.py を使う）" >&2
    exit 1
fi

# project.yml から .xcodeproj を作るリポジトリでは、先に生成する
if [ "$($CONFIG app xcodegen)" = "true" ] && [ ! -d "$PROJECT" ]; then
    command -v xcodegen >/dev/null || brew install xcodegen
    xcodegen generate
fi

# MARK: - Simulator

SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

# ビルドに使う SDK より新しいランタイム（ベータなど）には入れられないので、SDK 以下で一番新しいものを使う
latest_ios_runtime() {
    xcrun simctl list -j runtimes | python3 -c "
import json, sys
sdk = [int(part) for part in sys.argv[1].split('.')]
runtimes = [
    r for r in json.load(sys.stdin).get('runtimes', [])
    if r.get('isAvailable') and 'SimRuntime.iOS' in r.get('identifier', '')
    and [int(part) for part in r['version'].split('.')][:2] <= sdk[:2]
]
if not runtimes:
    sys.exit(1)
latest = max(runtimes, key=lambda r: [int(part) for part in r['version'].split('.')])
print(latest['identifier'])
" "$SDK_VERSION"
}

device_type_id_for_name() {
    xcrun simctl list -j devicetypes | python3 -c "
import json, sys
for item in json.load(sys.stdin).get('devicetypes', []):
    if item.get('name') == sys.argv[1]:
        print(item['identifier'])
        sys.exit(0)
sys.exit(1)
" "$1"
}

if ! RUNTIME_ID="$(latest_ios_runtime)"; then
    echo "iOS Simulator のランタイムが見つからないためダウンロードします"
    xcodebuild -downloadPlatform iOS
    RUNTIME_ID="$(latest_ios_runtime)"
fi
# 変数名の直後に全角文字が続くと、macOS の bash 3.2 はロケールによって全角文字の先頭バイトを変数名の一部と見なす
# （unbound variable になる。GitHub Actions のランナーで再現）ので、必ず波括弧で閉じる
echo "ランタイム: ${RUNTIME_ID}（SDK ${SDK_VERSION}）"

UDID=""
DEVICE_NAME=""
while IFS= read -r -u 3 candidate; do
    if DEVICE_TYPE_ID="$(device_type_id_for_name "$candidate")" \
        && UDID="$(xcrun simctl create "${SIMULATOR_PREFIX}-Screenshot-${DISPLAY_TYPE}" "$DEVICE_TYPE_ID" "$RUNTIME_ID" 2>/dev/null)"; then
        DEVICE_NAME="$candidate"
        break
    fi
    UDID=""
done 3< <($CONFIG devices "$DISPLAY_TYPE")

if [ -z "$UDID" ]; then
    echo "$DISPLAY_TYPE 向けの Simulator を作れませんでした。AppStore/screenshots.json の devices を見直してください。" >&2
    xcrun simctl list devicetypes >&2 || true
    exit 1
fi

cleanup() {
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl delete "$UDID" 2>/dev/null || true
}
# bash 3.2 では unbound variable で止まったとき EXIT トラップに終了コード 0 が渡り、失敗したのにステップが成功扱いになる。
# 最後まで到達した印（FINISHED）が無ければ失敗として返す
FINISHED=0
trap 'status=$?; if [ "$status" -eq 0 ] && [ "$FINISHED" -ne 1 ]; then status=1; fi; cleanup; exit "$status"' EXIT

echo "機種: ${DEVICE_NAME}（${UDID}）"

# MARK: - ビルド

# SwiftLint などのビルドツールプラグインとマクロの信頼確認は、Xcode.app で一度信頼すれば要らない。
# 確認を飛ばすのは、CI のように中身を確かめたチェックアウトで SKIP_PACKAGE_PLUGIN_VALIDATION=1 を付けたときだけ
PLUGIN_OPTIONS=()
if [ "${SKIP_PACKAGE_PLUGIN_VALIDATION:-0}" = 1 ]; then
    PLUGIN_OPTIONS+=(-skipPackagePluginValidation -skipMacroValidation)
fi

echo "${SCHEME}（${CONFIGURATION}）をビルドします"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    ${PLUGIN_OPTIONS[@]+"${PLUGIN_OPTIONS[@]}"} \
    -quiet \
    CODE_SIGNING_ALLOWED=NO

SETTINGS="$(xcodebuild -showBuildSettings \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA")"
BUILT_DIR="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP_NAME="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME /{print $2; exit}')"
BUNDLE_ID="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $2; exit}')"

# Simulator を起動したままビルドすると、非力なランナー（iPhone Duo を撮る xcode-27）が固まったので、ビルドしてから起動する
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# App Store のスクリーンショットらしく、上端を整える
xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 \
    --operatorName ""

# iPhone Duo のように画面が 2 つある機種では、どちらの画面を撮るかが起動のたびに変わる（内側は真っ黒に写る）。
# screenshots.json の sizes の先頭と同じ寸法の画面を選んで撮る。見つからなければ simctl の既定の画面を撮る
EXPECTED_SIZE="$($CONFIG sizes "$DISPLAY_TYPE" | head -n 1)"
DISPLAY_ID="$(xcrun simctl io "$UDID" enumerate 2>/dev/null | awk -v size="$EXPECTED_SIZE" '
    /^ *UUID:/ { uuid = $2 }
    /^ *Default width:/ { width = $3 }
    /^ *Default height:/ { if (width "x" $3 == size) { print uuid; exit } }
')" || DISPLAY_ID=""
DISPLAY_OPTION=()
if [ -n "$DISPLAY_ID" ]; then
    DISPLAY_OPTION=(--display="$DISPLAY_ID")
fi
echo "撮る画面: ${DISPLAY_ID:-既定}（${EXPECTED_SIZE}）"

xcrun simctl install "$UDID" "$BUILT_DIR/$APP_NAME"

# インストール直後の初回起動は遅く、アプリが出る前のホーム画面を「落ち着いた」と誤って撮ってしまう。
# 撮影の前に 1 回だけ起動しておく
xcrun simctl launch "$UDID" "$BUNDLE_ID" -screenshot-demo >/dev/null
sleep "$WARMUP_SECONDS"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

# MARK: - 撮影

screenshot() {
    xcrun simctl io "$UDID" screenshot ${DISPLAY_OPTION[@]+"${DISPLAY_OPTION[@]}"} "$1" >/dev/null 2>&1
}

# 起動直後はシートが出てくる途中だったりするので、連続で撮った 2 枚が同じになるまで待つ。
# 時刻はステータスバーで固定しているので、アニメーションが終われば画面は変わらない
capture_when_settled() {
    output="$1"
    work="$(mktemp -d)"
    sleep "$SETTLE_MINIMUM"
    screenshot "$work/previous.png"
    elapsed="$SETTLE_MINIMUM"
    while [ "$elapsed" -lt "$SETTLE_TIMEOUT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        screenshot "$work/current.png"
        if cmp -s "$work/previous.png" "$work/current.png"; then
            mv "$work/current.png" "$output"
            rm -rf "$work"
            return 0
        fi
        mv "$work/current.png" "$work/previous.png"
    done
    # 動いている途中の画面を正常な撮影結果として残すと、検証を通ってそのままアップロードされてしまう
    echo "::error::$(basename "$output") は ${SETTLE_TIMEOUT} 秒たっても画面が落ち着きませんでした"
    rm -rf "$work"
    return 1
}

# プロセス置換の中で失敗しても set -e では止まらず、前回の撮影結果のまま検証を通ってしまうので、先に取り出しておく
LANGUAGE_LIST="$($CONFIG languages "$LANGUAGES")"
SCENE_LIST="$($CONFIG scenes)"

# simctl が標準入力を読んでしまわないよう、一覧は別のファイル記述子から読む
while IFS=$'\t' read -r -u 3 language apple_language apple_locale store_locale; do
    destination="$SCREENSHOTS_DIR/$DISPLAY_TYPE/$language"
    # 撮り直しのたびに古い画像が混ざらないよう、言語ごとに作り直す
    rm -rf "$destination"
    mkdir -p "$destination"
    echo "::group::${DISPLAY_TYPE} / ${language}（${store_locale}）"
    while IFS=$'\t' read -r -u 4 file scene; do
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl launch "$UDID" "$BUNDLE_ID" \
            -screenshot-demo \
            -screenshot-scene "$scene" \
            -AppleLanguages "($apple_language)" \
            -AppleLocale "$apple_locale" >/dev/null
        capture_when_settled "$destination/$file.png"
        echo "  $file.png"
    done 4< <(printf '%s\n' "$SCENE_LIST")
    echo "::endgroup::"
done 3< <(printf '%s\n' "$LANGUAGE_LIST")
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

# MARK: - 仕上げと検証

# Simulator のスクリーンショットはアルファ付きの PNG で、App Store Connect は受け付けないので描き直す
REMOVE_ALPHA="$(mktemp -d)/remove_alpha"
xcrun swiftc -O "$TOOLS_DIR/remove_alpha.swift" -o "$REMOVE_ALPHA"
find "$SCREENSHOTS_DIR/$DISPLAY_TYPE" -name '*.png' -print0 | xargs -0 "$REMOVE_ALPHA"

# App Store Connect は寸法が 1px でも違えば弾く。
# アップロードまで進んでから落ちると原因が遠くなるので、撮った時点で確かめる
python3 "$TOOLS_DIR/verify_screenshots.py" \
    --directory "$SCREENSHOTS_DIR/$DISPLAY_TYPE" \
    --sizes "$($CONFIG sizes "$DISPLAY_TYPE" | paste -sd, -)"

echo "$SCREENSHOTS_DIR/$DISPLAY_TYPE に保存しました"
FINISHED=1
