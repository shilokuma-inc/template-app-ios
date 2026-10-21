#!/usr/bin/env python3
"""App Store の名前・サブタイトル・説明文・キーワード・プロモーションテキスト・最新情報・URL・著作権を App Store Connect に反映する。

`AppStore/metadata/<言語>.json` と `AppStore/metadata/shared.json` を読み、
対象バージョンと App 情報の言語ごとに書き込む。

    python3 Tools/upload_metadata.py            # 反映する
    python3 Tools/upload_metadata.py --dry-run  # 現在値との差分だけ出す
    python3 Tools/upload_metadata.py --check    # App Store Connect につながず、手元のファイルだけ検査する

書き込み先は 3 つある。App Store Connect の画面では同じページに並んでいても、API では別のリソース。

    バージョンの言語（appStoreVersionLocalizations） … 説明文・キーワード・プロモーションテキスト・最新情報・サポート URL・マーケティング URL
    App 情報の言語（appInfoLocalizations）            … 名前・サブタイトル・プライバシーポリシーの URL
    バージョン（appStoreVersions）                    … 著作権

認証は App Store Connect API Key（.p8）。次の環境変数でも渡せる。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

触るのは **編集できる状態のバージョンと App 情報だけ**。審査中や配信済みのバージョンは対象にしない。
JSON に書いていない項目（例: 省略した promotionalText）は App Store Connect 側の値をそのまま残す。
最新情報（whatsNew）はバージョンごとの文言なので、JSON の `whatsNew.version` が反映先のバージョンと
一致するときだけ書き込む（前のバージョンの文言を次のバージョンに載せてしまわないため）。

PyJWT が要る（--check では不要）: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import ROOT, Language, bundle_id, languages, parse_list

METADATA_DIR = ROOT / "AppStore" / "metadata"

#: 言語によらない値をまとめたファイル
SHARED_FILE = "shared.json"

#: App Store Connect 側の上限。超えると反映時に弾かれるので、手元で先に落とす。
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "description": 4000,
    "keywords": 100,
    "promotionalText": 170,
    "whatsNew": 4000,
}

#: 言語ごとに書く値のうち、App 情報の言語（appInfoLocalizations）に書くもの。
#: 残りはバージョンの言語（appStoreVersionLocalizations）に書く
APP_INFO_FIELDS = ("name", "subtitle", "privacyPolicyUrl")

#: shared.json の URL。値は全言語に同じものを書く。True は必須
SHARED_URLS = {
    # 審査で実際に開かれる
    "supportUrl": True,
    "marketingUrl": False,
    # すべてのアプリで必須（App 情報のプライバシーポリシー URL）
    "privacyPolicyUrl": True,
}


def load_shared(directory: Path) -> tuple[dict[str, str], str | None, list[str]]:
    """全言語に書く値と、バージョンに書く著作権を読む。"""
    path = directory / SHARED_FILE
    if not path.is_file():
        return {}, None, [f"{path} がありません"]
    raw = json.loads(path.read_text(encoding="utf-8"))
    problems = []
    attributes = {}
    for key, required in SHARED_URLS.items():
        value = raw.get(key)
        if isinstance(value, str) and value.strip():
            # テンプレートの仮の値（TODO:）は形を問わず、反映の前の TODO: の検査で止める
            parsed = urllib.parse.urlparse(value)
            if "TODO:" not in value and not (parsed.scheme == "https" and parsed.hostname):
                problems.append(f"{path}: {key} は https:// で始まる URL にしてください（ホスト名も要る）")
            attributes[key] = value
        elif required:
            problems.append(f"{path}: {key} がありません")

    # 著作権はバージョンごとの値で、審査に出すのに必須
    copyright_text = raw.get("copyright")
    if not (isinstance(copyright_text, str) and copyright_text.strip()):
        problems.append(f"{path}: copyright がありません（例: \"© 2026 Takumi Muraishi\"）")
        copyright_text = None
    return attributes, copyright_text, problems


def load(directory: Path, target: Language, shared: dict[str, str]) -> tuple[dict[str, str] | None, str | None, list[str]]:
    """1 言語ぶんの書き込む値と、最新情報の対象バージョンを読む。問題があれば値の代わりに理由を返す。"""
    path = directory / f"{target.language}.json"
    if not path.is_file():
        return None, None, [f"{path} がありません"]
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return None, None, [f"{path} が JSON として読めません: {error}"]

    problems: list[str] = []
    attributes: dict[str, str] = {}

    # 名前とサブタイトルは省略できる（省略すると App Store Connect 側の値をそのまま残す）
    for field in ("name", "subtitle"):
        if field not in raw:
            continue
        value = raw[field]
        if isinstance(value, str) and value.strip():
            attributes[field] = value
        else:
            problems.append(f"{path}: {field} が空です（使わないなら項目ごと消す）")

    description = raw.get("description")
    if isinstance(description, str) and description.strip():
        attributes["description"] = description
    else:
        problems.append(f"{path}: description がありません")

    keywords = raw.get("keywords")
    if isinstance(keywords, list) and keywords:
        # App Store Connect にはカンマ区切りの 1 本の文字列として渡す。
        # 区切りのあとに空白を入れると、そのぶん 100 字の枠を食うので詰めて繋ぐ。
        # null や空文字を str() で "None" や空の区切りにしてしまわないよう、空でない文字列だけを許す
        if all(isinstance(keyword, str) and keyword.strip() for keyword in keywords):
            attributes["keywords"] = ",".join(keyword.strip() for keyword in keywords)
        else:
            problems.append(f"{path}: keywords に空の要素か文字列以外の要素があります")
    else:
        problems.append(f"{path}: keywords がありません（配列で書く）")

    promotional_text = raw.get("promotionalText")
    if promotional_text is not None:
        if isinstance(promotional_text, str) and promotional_text.strip():
            attributes["promotionalText"] = promotional_text
        else:
            problems.append(f"{path}: promotionalText が空です（使わないなら項目ごと消す）")

    whats_new_version = None
    # 省略（キーが無い）と null を分ける。null は書き損じなので、省略と同じには扱わない
    if "whatsNew" in raw:
        whats_new = raw["whatsNew"]
        version = whats_new.get("version") if isinstance(whats_new, dict) else None
        text = whats_new.get("text") if isinstance(whats_new, dict) else None
        if not (isinstance(version, str) and version.strip() and isinstance(text, str) and text.strip()):
            problems.append(f"{path}: whatsNew は {{\"version\": \"2.1.0\", \"text\": \"…\"}} の形で書く（使わないなら項目ごと消す）")
        else:
            attributes["whatsNew"] = text
            whats_new_version = version

    for field, limit in LIMITS.items():
        value = attributes.get(field, "")
        if len(value) > limit:
            problems.append(f"{path}: {field} が {len(value)} 字あります（上限 {limit} 字）")

    if problems:
        return None, None, problems
    return {**attributes, **shared}, whats_new_version, []


def split(attributes: dict[str, str]) -> tuple[dict[str, str], dict[str, str]]:
    """1 言語ぶんの値を、バージョンの言語に書くものと App 情報の言語に書くものに分ける。"""
    version_fields = {field: value for field, value in attributes.items() if field not in APP_INFO_FIELDS}
    info_fields = {field: value for field, value in attributes.items() if field in APP_INFO_FIELDS}
    return version_fields, info_fields


def describe_changes(current: dict, new: dict[str, str]) -> list[str]:
    """現在値から変わる項目を、人が読める形で返す。長い文章は行単位の差分にする。"""
    lines: list[str] = []
    for field, value in new.items():
        before = current.get(field) or ""
        if before == value:
            continue
        if "\n" in before or "\n" in value:
            lines.append(f"    {field}:")
            diff = difflib.unified_diff(before.splitlines(), value.splitlines(), lineterm="", n=1)
            lines.extend(f"      {line}" for line in list(diff)[2:])
        else:
            lines.append(f"    {field}: {before or '（空）'} → {value}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--metadata-dir", type=Path, default=METADATA_DIR, help="<ここ>/<言語>.json を読む")
    parser.add_argument("--languages", help="対象の言語（カンマ区切り）。省略すると全言語")
    parser.add_argument("--bundle-id", help="省略すると project.pbxproj から読む")
    parser.add_argument("--app-version", help="反映先のバージョン。省略すると編集できるバージョンを自動で選ぶ")
    parser.add_argument("--key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument(
        "--private-key",
        type=Path,
        default=os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY_PATH"),
        help="App Store Connect API Key の .p8",
    )
    parser.add_argument(
        "--missing-locales",
        choices=("fail", "skip", "create"),
        default="fail",
        help="App Store Connect にその言語が無いときの扱い（バージョンと App 情報の両方）。"
             "fail: 止める（既定） / skip: 飛ばす / create: その言語を追加してから反映する",
    )
    parser.add_argument("--check", action="store_true",
                        help="App Store Connect につながず、手元のファイルの欠損と文字数だけ見る")
    parser.add_argument("--dry-run", action="store_true", help="何も書き換えず、現在値との差分だけ出す")
    args = parser.parse_args()

    targets = languages(parse_list(args.languages))

    shared, copyright_text, problems = load_shared(args.metadata_dir)
    entries: list[tuple[Language, dict[str, str]]] = []
    whats_new_versions: dict[str, str] = {}
    for target in targets:
        attributes, whats_new_version, issues = load(args.metadata_dir, target, shared)
        problems.extend(issues)
        if attributes:
            entries.append((target, attributes))
        if whats_new_version:
            whats_new_versions[target.language] = whats_new_version
    if problems:
        raise SystemExit("\n".join(problems))

    # テンプレートの仮の文言（TODO:）が残ったまま App Store Connect に書き込まない
    placeholders = [
        f"{target.language}.{field}" for target, attributes in entries
        for field, value in attributes.items() if "TODO:" in value
    ]
    if copyright_text and "TODO:" in copyright_text:
        placeholders.append("shared.copyright")
    if placeholders and not args.check:
        raise SystemExit(f"テンプレートの仮の文言（TODO:）が残っています: {', '.join(placeholders)}")

    if args.check:
        if placeholders:
            print(f"注意: テンプレートの仮の文言（TODO:）が残っています: {', '.join(placeholders)}")
        for target, attributes in entries:
            counts = " / ".join(
                f"{field} {len(attributes[field])} 字" for field in LIMITS if field in attributes
            )
            version_note = (f"（whatsNew は {whats_new_versions[target.language]} 向け）"
                            if target.language in whats_new_versions else "")
            print(f"  {target.language}: {counts}{version_note}")
        print(f"  著作権: {copyright_text}")
        print(f"問題なし: {len(entries)} 言語")
        return 0

    missing_key = [
        name for name, value in
        [("--key-id", args.key_id), ("--issuer-id", args.issuer_id), ("--private-key", args.private_key)]
        if not value
    ]
    if missing_key:
        raise SystemExit(f"認証情報が足りません: {', '.join(missing_key)}")

    from app_store_connect import AppStoreConnect

    client = AppStoreConnect(
        args.key_id, args.issuer_id, Path(args.private_key).read_text(), dry_run=args.dry_run
    )

    app = client.find_app(args.bundle_id or bundle_id())
    version = client.find_version(app["id"], args.app_version)
    version_string = version["attributes"]["versionString"]
    app_info = client.find_app_info(app["id"])
    print(f"対象: {app['attributes']['name']} {version_string} "
          f"({version['attributes']['appStoreState']})")
    if args.dry_run:
        print("--dry-run: App Store Connect には何も書き込みません")

    # 最新情報は、書いてあるバージョンが反映先と一致する言語だけに入れる
    for target, attributes in entries:
        whats_new_version = whats_new_versions.get(target.language)
        if "whatsNew" in attributes and whats_new_version != version_string:
            del attributes["whatsNew"]
            print(f"  {target.language}: whatsNew は {whats_new_version} 向けなので {version_string} には書き込みません")

    available = client.localization_entries(version["id"])
    available_info = client.app_info_localization_entries(app_info["id"])

    # スクリーンショットのときと同じく、書き込む前に全言語ぶんの前提を確かめる。
    # バージョンの言語と App 情報の言語は別々にあるので、どちらが無いかも別々に見る
    plan: list[tuple[Language, dict[str, str], dict | None]] = []
    info_plan: list[tuple[Language, dict[str, str], dict | None]] = []
    skipped: list[str] = []
    missing_locales: list[str] = []
    problems = []
    for target, attributes in entries:
        version_fields, info_fields = split(attributes)
        for kind, fields, entry, destination in (
            (f"バージョン {version_string}", version_fields, available.get(target.store_locale), plan),
            ("App 情報", info_fields, available_info.get(target.store_locale), info_plan),
        ):
            if entry is None:
                if args.missing_locales == "skip":
                    print(f"  飛ばす — {target.language}: {target.store_locale} が {kind} にありません")
                    skipped.append(f"{target.language}（{kind}）")
                    continue
                if args.missing_locales == "fail":
                    missing_locales.append(f"{target.language} → {target.store_locale}（{kind}）")
                    continue
                # App 情報の言語は名前が無いと作れない（アプリを作ったときの言語にしか名前が入っていない）
                if destination is info_plan and "name" not in fields:
                    problems.append(
                        f"{target.language}: App 情報に {target.store_locale} が無いので追加しますが、"
                        f"名前が要ります。AppStore/metadata/{target.language}.json に name を書いてください"
                    )
                    continue
            destination.append((target, fields, entry))

    if missing_locales:
        raise SystemExit(
            f"App Store Connect に無い言語: {', '.join(missing_locales)}\n"
            "App Store Connect でこれらの言語を追加してから実行するか、"
            "--missing-locales create（追加してから反映）か "
            "--missing-locales skip（飛ばす）を付けてください。"
        )
    if problems:
        raise SystemExit("\n".join(problems))

    for target, attributes, localization in plan:
        label = f"{target.language} → {target.store_locale}"
        if localization is None:
            client.create_localization(version["id"], target.store_locale, attributes)
            print(f"  {label}: {'言語を追加して書き込む予定' if args.dry_run else '言語を追加して書き込み'}")
            for line in describe_changes({}, attributes):
                print(line)
            continue

        changes = describe_changes(localization["attributes"], attributes)
        if not changes:
            print(f"  {label}: 変更なし")
            continue
        print(f"  {label}: {'書き込む予定' if args.dry_run else '書き込み'}")
        for line in changes:
            print(line)
        if not args.dry_run:
            client.patch(
                f"/v1/appStoreVersionLocalizations/{localization['id']}",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization["id"],
                        "attributes": attributes,
                    }
                },
            )

    for target, attributes, localization in info_plan:
        label = f"{target.language} → {target.store_locale}（App 情報）"
        if localization is None:
            client.create_app_info_localization(app_info["id"], target.store_locale, attributes)
            print(f"  {label}: {'言語を追加して書き込む予定' if args.dry_run else '言語を追加して書き込み'}")
            for line in describe_changes({}, attributes):
                print(line)
            continue

        changes = describe_changes(localization["attributes"], attributes)
        if not changes:
            print(f"  {label}: 変更なし")
            continue
        print(f"  {label}: {'書き込む予定' if args.dry_run else '書き込み'}")
        for line in changes:
            print(line)
        if not args.dry_run:
            client.patch(
                f"/v1/appInfoLocalizations/{localization['id']}",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "id": localization["id"],
                        "attributes": attributes,
                    }
                },
            )

    current_copyright = version["attributes"].get("copyright") or ""
    if current_copyright == copyright_text:
        print("  著作権: 変更なし")
    else:
        print(f"  著作権: {'書き込む予定' if args.dry_run else '書き込み'}")
        print(f"    copyright: {current_copyright or '（空）'} → {copyright_text}")
        if not args.dry_run:
            client.patch(
                f"/v1/appStoreVersions/{version['id']}",
                {
                    "data": {
                        "type": "appStoreVersions",
                        "id": version["id"],
                        "attributes": {"copyright": copyright_text},
                    }
                },
            )

    written = {target.language for target, _, _ in plan + info_plan}
    print(f"完了: {len(written)} 言語")
    if skipped:
        print(f"飛ばした言語: {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
