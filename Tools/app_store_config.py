#!/usr/bin/env python3
"""アプリのリポジトリの `AppStore/*.json` を読む共通処理。

撮影（capture_screenshots.sh）・App Store Connect への反映（upload_*.py）・GitHub Actions の
ワークフローのどれからも使う。設定は JSON が単一の定義で、ここには「読んで整合を確かめる」以上のことは書かない。

リポジトリのルートを基準に読む（環境変数 APP_STORE_ROOT で変えられる）。読むファイル:

    AppStore/app.json          … プロジェクト・Scheme・Bundle ID など、アプリごとに違うビルドの設定
    AppStore/languages.json    … 載せる言語
    AppStore/screenshots.json  … 撮る画面と表示サイズ

シェルから使うときはタブ区切りで出す。

    python3 Tools/app_store_config.py app project            # app.json の値（project / scheme / configuration / simulatorPrefix）
    python3 Tools/app_store_config.py languages [ja,en]      # 言語ごとの撮影・反映の設定
    python3 Tools/app_store_config.py scenes                 # 撮る画面
    python3 Tools/app_store_config.py devices APP_IPHONE_67
    python3 Tools/app_store_config.py sizes APP_IPHONE_67
    python3 Tools/app_store_config.py derive-from APP_IPHONE_61   # 縮めて作る元の表示サイズ（無ければ空）
    python3 Tools/app_store_config.py display-types [APP_IPHONE_67,...]  # GitHub Actions の matrix 用 JSON
    python3 Tools/app_store_config.py bundle-id
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import NamedTuple

ROOT = Path(os.environ.get("APP_STORE_ROOT") or Path(__file__).resolve().parent.parent).resolve()
APP_FILE = ROOT / "AppStore" / "app.json"
LANGUAGES_FILE = ROOT / "AppStore" / "languages.json"
SCREENSHOTS_FILE = ROOT / "AppStore" / "screenshots.json"

#: 1 つの言語・表示サイズに載せられる枚数の上限（App Store Connect の制限）
MAX_SCREENSHOTS = 10

#: screenshots.json の表示サイズで runsOn / xcodeVersion を省いたときの既定
DEFAULT_RUNS_ON = "macos-latest"
DEFAULT_XCODE_VERSION = "26.6"


class Language(NamedTuple):
    #: このリポジトリ内での言語コード。metadata の JSON と撮影結果のフォルダ名
    language: str
    #: -AppleLanguages に渡す値
    apple_language: str
    #: -AppleLocale に渡す値
    apple_locale: str
    #: App Store Connect のロケール
    store_locale: str


class Scene(NamedTuple):
    #: 出力するファイル名（拡張子なし）。この順が App Store の並び順
    file: str
    #: -screenshot-scene に渡す値
    scene: str


# MARK: - app.json


def _read_json(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"{path.relative_to(ROOT)} がありません")
    return json.loads(path.read_text(encoding="utf-8"))


def app_config() -> dict:
    return _read_json(APP_FILE)


def project_path() -> Path:
    """ビルドする .xcodeproj。app.json の project を使い、省略時はルートに 1 つだけあるものを使う。"""
    name = app_config().get("project")
    if name:
        return ROOT / name
    found = sorted(ROOT.glob("*.xcodeproj"))
    if len(found) != 1:
        raise SystemExit(
            f"{APP_FILE.name} に project がなく、ルートの .xcodeproj も 1 つに決まりません: "
            f"{', '.join(p.name for p in found) or 'なし'}"
        )
    return found[0]


def app_value(key: str) -> str:
    """シェルから使う app.json の値。省略できるものは既定を返す。"""
    config = app_config()
    if key == "project":
        return project_path().name
    if key == "scheme":
        return config.get("scheme") or project_path().stem
    if key == "configuration":
        return config.get("configuration") or "Release"
    if key == "simulatorPrefix":
        return config.get("simulatorPrefix") or project_path().stem
    if key == "xcodegen":
        # project.yml から .xcodeproj を作るリポジトリ（.xcodeproj をコミットしていない）
        return "true" if config.get("xcodegen") else "false"
    if key == "appIcon":
        return config.get("appIcon") or ""
    raise SystemExit(f"app.json の {key} は読めません")


# MARK: - languages.json


def languages(selected: list[str] | None = None) -> list[Language]:
    """指定した言語（省略時は全言語）の設定を返す。知らない言語を指定したらその場で止める。"""
    entries = _read_json(LANGUAGES_FILE)["languages"]
    known = {entry["language"]: entry for entry in entries}
    targets = [entry["language"] for entry in entries] if selected is None else selected

    unknown = [language for language in targets if language not in known]
    if unknown:
        raise SystemExit(
            f"{LANGUAGES_FILE.name} に無い言語: {', '.join(unknown)}\n"
            f"指定できるのは: {', '.join(known)}"
        )
    return [
        Language(
            language=language,
            apple_language=known[language]["appleLanguage"],
            apple_locale=known[language]["appleLocale"],
            store_locale=known[language]["storeLocale"],
        )
        for language in targets
    ]


# MARK: - screenshots.json


def _screenshots_config() -> dict:
    return _read_json(SCREENSHOTS_FILE)


def known_scenes() -> set[str] | None:
    """アプリの撮影モードが受け付ける scene（`ScreenshotDemo.Scene` の rawValue）を Swift のソースから読む。

    設定にだけある名前を渡すと、アプリは変換に失敗して最初の画面を出し、それが別の画面のファイル名で
    保存されてしまう（寸法の検証では気づけない）。app.json の screenshotDemoSource があれば突き合わせる。
    """
    source_path = app_config().get("screenshotDemoSource")
    if not source_path:
        return None
    source = (ROOT / source_path).read_text(encoding="utf-8")
    match = re.search(r"enum Scene: String \{\n(.*?)\n\s*\}", source, re.DOTALL)
    if match is None:
        raise SystemExit(f"{source_path} に enum Scene: String が見つかりません")
    # `case main` は rawValue が名前そのもの、`case timeAttack = "time-attack"` は引用符の中が rawValue
    return {
        raw_value or name
        for name, raw_value in re.findall(r"^\s*case (\w+)(?: = \"([^\"]+)\")?", match.group(1), re.MULTILINE)
    }


def scenes() -> list[Scene]:
    entries = _screenshots_config()["scenes"]
    if not entries:
        raise SystemExit(f"{SCREENSHOTS_FILE.name} の scenes が空です（アプリに撮影モードを作ってから足す）")
    if len(entries) > MAX_SCREENSHOTS:
        raise SystemExit(
            f"{SCREENSHOTS_FILE.name} の scenes が {len(entries)} 件あります。"
            f"App Store Connect は 1 つの表示サイズにつき {MAX_SCREENSHOTS} 枚までです。"
        )
    known = known_scenes()
    if known is not None:
        unknown = [entry["scene"] for entry in entries if entry["scene"] not in known]
        if unknown:
            raise SystemExit(
                f"{SCREENSHOTS_FILE.name} の scene が ScreenshotDemo.Scene にありません: {', '.join(unknown)}\n"
                f"使えるのは: {', '.join(sorted(known))}"
            )
    return [Scene(file=entry["file"], scene=entry["scene"]) for entry in entries]


def display_type(name: str) -> dict:
    display_types = _screenshots_config()["displayTypes"]
    if name not in display_types:
        raise SystemExit(
            f"{SCREENSHOTS_FILE.name} に無い表示サイズ: {name}\n"
            f"指定できるのは: {', '.join(display_types)}"
        )
    entry = display_types[name]
    source = entry.get("deriveFrom")
    if source:
        if source not in display_types or display_types[source].get("deriveFrom"):
            raise SystemExit(f"{SCREENSHOTS_FILE.name} の {name} の deriveFrom は、撮影する表示サイズにしてください: {source}")
    return entry


def display_type_names(selected: list[str] | None = None) -> list[str]:
    names = list(_screenshots_config()["displayTypes"]) if selected is None else selected
    for name in names:
        display_type(name)
    return names


def matrix(selected: list[str] | None = None) -> dict:
    """GitHub Actions の matrix。撮る表示サイズ（capture）と、縮めて作る表示サイズ（derive）に分ける。

    縮めて作る表示サイズだけを指定したときも、元の表示サイズは撮る必要があるので capture に足す。
    """
    names = display_type_names(selected)
    capture: list[str] = []
    derive: list[dict] = []
    for name in names:
        entry = display_type(name)
        if entry.get("deriveFrom"):
            derive.append({"display_type": name, "label": entry["label"], "source": entry["deriveFrom"]})
            if entry["deriveFrom"] not in capture:
                capture.append(entry["deriveFrom"])
        elif name not in capture:
            capture.append(name)
    capture_entries = []
    for name in capture:
        entry = display_type(name)
        capture_entries.append({
            "display_type": name,
            "label": entry["label"],
            "runs_on": entry.get("runsOn") or DEFAULT_RUNS_ON,
            "xcode_version": entry.get("xcodeVersion") or DEFAULT_XCODE_VERSION,
        })
    # 反映は、指定された表示サイズだけ（元にするために撮っただけのものは反映しない）
    upload = [{"display_type": name, "label": display_type(name)["label"]} for name in names]
    return {"capture": capture_entries, "derive": derive, "upload": upload}


# MARK: - Bundle ID


def bundle_id() -> str:
    """アプリの Bundle ID。app.json の bundleId を優先し、無ければ project.pbxproj から読む。

    pbxproj にはテストターゲット（`…Tests`）の PRODUCT_BUNDLE_IDENTIFIER も入っているので、
    productType が application のターゲットの build configuration だけをたどる。
    その中で値が 1 つに決まらなければ（アプリターゲットが複数、構成ごとに別の値）止める。
    値が `$(APP_BUNDLE_IDENTIFIER)` のように xcconfig の変数を参照していれば、app.json の xcconfig
    （既定は Configs/Project.xcconfig）から展開する。
    """
    explicit = app_config().get("bundleId")
    if explicit:
        return explicit

    project_file = project_path() / "project.pbxproj"
    if not project_file.is_file():
        raise SystemExit(f"{project_file.relative_to(ROOT)} がありません。app.json に bundleId を書いてください")
    text = project_file.read_text(encoding="utf-8")

    # アプリターゲット → その buildConfigurationList の ID
    config_list_ids = re.findall(
        r"isa = PBXNativeTarget;\s*buildConfigurationList = ([0-9A-F]{24})[^;]*;"
        r"(?:(?!isa = ).)*?productType = \"com\.apple\.product-type\.application\";",
        text,
        re.DOTALL,
    )
    found: set[str] = set()
    for config_list_id in config_list_ids:
        match = re.search(
            rf"{config_list_id} /\*[^*]*\*/ = \{{\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\);",
            text,
        )
        if match is None:
            continue
        for config_id in re.findall(r"([0-9A-F]{24})", match.group(1)):
            config = re.search(
                rf"{config_id} /\*[^*]*\*/ = \{{\s*isa = XCBuildConfiguration;(.*?)\n\t\t\}};",
                text,
                re.DOTALL,
            )
            if config is None:
                continue
            found.update(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;', config.group(1)))

    if not found:
        # 古い形式のプロジェクトなど、ターゲットをたどれないときは全体から探す
        found = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;', text))
        found = {value for value in found if not re.search(r"Tests?$|UITests?$", value)}

    found = {_expand_xcconfig_variables(value) for value in found}
    if len(found) != 1:
        raise SystemExit(
            f"{project_file.name} のアプリターゲットの PRODUCT_BUNDLE_IDENTIFIER が 1 つに決まりません: "
            f"{', '.join(sorted(found)) or 'なし'}。app.json に bundleId を書いてください"
        )
    return found.pop()


def _xcconfig_file() -> Path:
    return ROOT / (app_config().get("xcconfig") or "Configs/Project.xcconfig")


def _xcconfig_values() -> dict[str, str]:
    """xcconfig の `NAME = value` を読む（`//` のコメントは除く）。"""
    values: dict[str, str] = {}
    path = _xcconfig_file()
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("//", 1)[0].strip()
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def _expand_xcconfig_variables(value: str) -> str:
    """`$(NAME)` / `${NAME}` を xcconfig の値で置き換える。展開できなければ止める。"""
    if "$" not in value:
        return value
    values = _xcconfig_values()

    def replace(match: re.Match) -> str:
        name = match.group(1) or match.group(2)
        if name not in values:
            raise SystemExit(
                f"{_xcconfig_file().relative_to(ROOT)} に {name} がありません（{value} を展開できません）。"
                "app.json に bundleId を書くこともできます"
            )
        return values[name]

    expanded = re.sub(r"\$\((\w+)\)|\$\{(\w+)\}", replace, value)
    if "$" in expanded:
        raise SystemExit(f"{value} を展開しきれません: {expanded}")
    return expanded


def parse_list(raw: str | None) -> list[str] | None:
    """カンマ区切り（または空白区切り）の指定を配列にする。空なら None（＝すべて）。"""
    if raw is None:
        return None
    items = [item.strip() for item in raw.replace(",", " ").split()]
    return items or None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "command",
        choices=("app", "languages", "scenes", "devices", "sizes", "derive-from", "display-types", "bundle-id"),
    )
    parser.add_argument("argument", nargs="?", default=None)
    args = parser.parse_args()

    if args.command == "app":
        if not args.argument:
            raise SystemExit("読む項目（例: project）を指定してください")
        print(app_value(args.argument))
    elif args.command == "languages":
        for entry in languages(parse_list(args.argument)):
            print("\t".join(entry))
    elif args.command == "scenes":
        for entry in scenes():
            print("\t".join(entry))
    elif args.command in ("devices", "sizes"):
        if not args.argument:
            raise SystemExit("表示サイズ（例: APP_IPHONE_67）を指定してください")
        for value in display_type(args.argument).get(args.command, []):
            print(value)
    elif args.command == "derive-from":
        if not args.argument:
            raise SystemExit("表示サイズ（例: APP_IPHONE_61）を指定してください")
        print(display_type(args.argument).get("deriveFrom") or "")
    elif args.command == "bundle-id":
        print(bundle_id())
    else:
        print(json.dumps(matrix(parse_list(args.argument)), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
