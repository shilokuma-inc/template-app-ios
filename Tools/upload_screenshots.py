#!/usr/bin/env python3
"""撮ったスクリーンショットを App Store Connect の対象バージョンに反映する。

`Tools/capture_screenshots.sh` が並べた `<出力先>/<言語>/01_*.png …` を読み、
App Store Connect API で言語ごとにアップロードする。

    python3 Tools/upload_screenshots.py \\
        --screenshots-dir build/screenshots/APP_IPHONE_67 \\
        --display-type APP_IPHONE_67

`--languages` を省くと languages.json の全言語を反映する。一部の言語だけ撮り直したときは、
残っている古い画像まで反映しないよう、撮った言語に絞る。

    python3 Tools/upload_screenshots.py \\
        --screenshots-dir build/screenshots/APP_IPHONE_67 \\
        --display-type APP_IPHONE_67 \\
        --languages ja

認証は App Store Connect API Key（.p8）。次の環境変数でも渡せる。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

触るのは **編集できる状態のバージョンだけ**。審査中や配信済みのバージョンは対象にしない。
言語ごとに、その表示サイズの既存のスクリーンショットセットを削除してから入れ直す。
（App Store Connect は 1 つの言語・表示サイズにつきセットを 1 つしか持てないため、
 差し替えは「消してから入れる」しかない。編集中のバージョンなので公開中の画面には影響しない。）

PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import MAX_SCREENSHOTS, bundle_id, languages, parse_list
from app_store_connect import AppStoreConnect


def screenshots_for(directory: Path) -> list[Path]:
    """ファイル名の順に並べる。この順がそのまま App Store の並び順になる。"""
    return sorted(p for p in directory.glob("*.png"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--screenshots-dir", type=Path, required=True, help="<ここ>/<言語>/*.png を読む")
    parser.add_argument("--bundle-id", help="省略すると project.pbxproj から読む")
    parser.add_argument("--display-type", required=True, help="App Store Connect の表示サイズ（例: APP_IPHONE_67）")
    parser.add_argument("--languages", help="対象の言語（カンマ区切り）。省略すると全言語")
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
        help="App Store Connect にその言語が無いときの扱い。"
             "fail: 止める（既定） / skip: 飛ばす / create: その言語を追加してから反映する",
    )
    parser.add_argument("--dry-run", action="store_true", help="何も書き換えず、やることだけ出す")
    args = parser.parse_args()

    targets = languages(parse_list(args.languages))

    missing_key = [
        name for name, value in
        [("--key-id", args.key_id), ("--issuer-id", args.issuer_id), ("--private-key", args.private_key)]
        if not value
    ]
    if missing_key:
        raise SystemExit(f"認証情報が足りません: {', '.join(missing_key)}")

    client = AppStoreConnect(
        args.key_id, args.issuer_id, Path(args.private_key).read_text(), dry_run=args.dry_run
    )

    app = client.find_app(args.bundle_id or bundle_id())
    version = client.find_version(app["id"], args.app_version)
    version_string = version["attributes"]["versionString"]
    print(f"対象: {app['attributes']['name']} {version_string} "
          f"({version['attributes']['appStoreState']}) / {args.display_type}")
    if args.dry_run:
        print("--dry-run: App Store Connect には何も書き込みません")

    available = client.localizations(version["id"])

    # 書き込みを始める前に、全言語ぶんの前提をまとめて確かめる。
    # 途中で止めると一部の言語だけ差し替わった状態になるうえ、
    # 撮り直しに小一時間かかるので「直すべき点」は 1 回で出し切る。
    plan = []
    skipped: list[str] = []
    missing_locales: list[str] = []
    problems: list[str] = []
    for target in targets:
        directory = args.screenshots_dir / target.language
        images = screenshots_for(directory) if directory.is_dir() else []
        if not images:
            problems.append(f"{directory} にスクリーンショットがありません")
            continue
        if len(images) > MAX_SCREENSHOTS:
            problems.append(
                f"{directory} に {len(images)} 枚あります。"
                f"App Store Connect は 1 つの表示サイズにつき {MAX_SCREENSHOTS} 枚までです。"
            )
            continue

        localization_id = available.get(target.store_locale)
        if localization_id is None:
            if args.missing_locales == "create":
                # ここでは作らず、前提の確認が全部通ってからまとめて作る
                plan.append((target, images, None))
            elif args.missing_locales == "skip":
                print(f"  飛ばす — {target.language}: {target.store_locale} が {version_string} にありません")
                skipped.append(target.language)
            else:
                missing_locales.append(f"{target.language} → {target.store_locale}")
            continue

        plan.append((target, images, localization_id))

    if missing_locales:
        problems.append(
            f"App Store Connect の {version_string} に無い言語: {', '.join(missing_locales)}\n"
            "App Store Connect でこれらの言語を追加してから実行するか、"
            "--missing-locales create（追加してから反映）か "
            "--missing-locales skip（飛ばす）を付けてください。"
        )
    if problems:
        raise SystemExit("\n".join(problems))

    for index, (target, images, localization_id) in enumerate(plan):
        if localization_id is None:
            localization_id = client.create_localization(version["id"], target.store_locale)
            print(f"  {target.store_locale} を {version_string} に追加しました")
            plan[index] = (target, images, localization_id)

    uploaded_total = 0
    for target, images, localization_id in plan:
        if localization_id == "dry-run":
            # --dry-run では言語を作っていないので、App Store Connect に問い合わせる先が無い
            print(f"  {target.language} → {target.store_locale}: 言語を追加して {len(images)} 枚（予定）")
            continue
        existing = client.existing_set(localization_id, args.display_type)
        if existing and not args.dry_run:
            client.delete(f"/v1/appScreenshotSets/{existing}")
        set_id = client.create_set(localization_id, args.display_type)

        screenshot_ids = [client.upload(set_id, image) for image in images]
        client.reorder(set_id, screenshot_ids)
        client.wait_for_delivery(screenshot_ids)
        uploaded_total += len(images)
        print(f"  {target.language} → {target.store_locale}: {len(images)} 枚")

    print(f"完了: {len(plan)} 言語 / {uploaded_total} 枚")
    if skipped:
        print(f"飛ばした言語: {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
