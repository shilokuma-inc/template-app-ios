#!/usr/bin/env python3
"""プロダクトページのヘッダーと検索結果のクリエイティブアセットを App Store Connect に反映する。

iOS 27 から、スクリーンショットとは別に「クリエイティブアセット」を App Store に載せられる
（https://developer.apple.com/app-store/asset-best-practices/）。置き場所と元ネタは
`AppStore/creative_assets.json`、画像は `AppStore/creative/<言語>/<ファイル名>`。

    python3 Tools/upload_creative_assets.py               # 全言語を反映する
    python3 Tools/upload_creative_assets.py --dry-run     # 何も書き換えず、やることだけ出す
    python3 Tools/upload_creative_assets.py --ref-data    # 置き場所と画像の仕様を App Store Connect から読んで出す

App Asset Library の API で、次の順で反映する。

1. 全言語の画像を Asset Library に上げる（予約 → 転送 → 確定）。参照名には画像のハッシュを入れ、
   同じ参照名の画像が前回の実行で上がっていれば、上げ直さずにそれを使う
2. Apple 側の処理が終わるのを、全部の画像でまとめて待つ
3. 処理で決まった画像の仕様（specId）を受け付ける置き場所のグループを、参照データから探す
4. その言語の同じ置き場所にある既存の配置を外し、新しい画像を配置する（同じ画像が配置済みなら何もしない）

処理の待ちが上限で切れても、終わった画像は配置してから失敗にする。流し直せば、残りを上げ直さずに続きから待てる。

置き場所のグループ（iPhone / iPad など）や仕様の ID は、Apple が機種を足すたびに増えるので
決め打ちせず、毎回参照データ（appAssetLibraryRefData）から引く。

触るのは **編集できる状態のバージョンだけ**。外した配置の画像は Asset Library に残る。

認証は App Store Connect API Key（.p8）。次の環境変数でも渡せる。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import ROOT, bundle_id, languages, parse_list
from app_store_connect import REQUEST_TIMEOUT, ApiError, AppStoreConnect

CONFIG_PATH = ROOT / "AppStore" / "creative_assets.json"
ASSETS_DIR = ROOT / "AppStore" / "creative"

#: Asset Library の処理（PREPARE_FOR_SUBMISSION になる）を待つ上限（秒）
# Apple 側の処理が 10 分を超えることがある（2026-11-10 に idfa-vault-ios の 3840x2560 の検索結果の画像で止まった）ので、環境変数で延ばせるようにする
PROCESSING_TIMEOUT = int(os.environ.get("CREATIVE_PROCESSING_TIMEOUT") or 600)

#: App Store のバージョンに載せるときの機能名（参照データの features）
FEATURE = "APP_STORE_VERSIONS"

CATEGORY = "CREATIVE_ASSETS"

#: 前回の実行で上げた同じ画像（参照名が同じ）を、上げ直さずに使う状態。UPLOAD_COMPLETE は Apple 側で処理中
REUSABLE_STATES = {"UPLOAD_COMPLETE", "PREPARE_FOR_SUBMISSION"}
#: 消して上げ直す状態。AWAITING_UPLOAD は転送か確定の途中で止まったもの
RETRYABLE_STATES = {"AWAITING_UPLOAD", "FAILED"}


def load_config() -> list[dict]:
    return json.loads(CONFIG_PATH.read_text())["assets"]


# MARK: - 参照データ


def _key(entry: dict, *names: str):
    """参照データの項目名（featureId / placementTypeId など）を、名前の揺れも込みで引く。"""
    for name in names:
        if name in entry:
            return entry[name]
    return None


class RefData:
    def __init__(self, attributes: dict):
        self.raw = attributes

    def placement_type(self, name: str) -> dict:
        for entry in self.raw.get("placementTypes", []):
            if _key(entry, "placementTypeId", "placementType") == name:
                return entry
        raise SystemExit(f"参照データに置き場所 {name} がありません")

    def groups_for_spec(self, placement_type: str, spec_id: str) -> list[str]:
        """その置き場所で、この仕様の画像を受け付けるグループ。"""
        groups = []
        for mapping in self.placement_type(placement_type).get("specMappings", []):
            if spec_id in (mapping.get("specs") or []):
                group = _key(mapping, "placementGroupId", "placementGroup")
                if group:
                    groups.append(group)
        return groups

    def group_limit(self, placement_type: str, group: str) -> int | None:
        for feature in self.raw.get("features", []):
            if _key(feature, "featureId", "feature") != FEATURE:
                continue
            for policy in feature.get("placementPolicies", []):
                if _key(policy, "placementType", "placementTypeId") != placement_type:
                    continue
                for limit in policy.get("groupLimits", []):
                    if group in (limit.get("groupIds") or []):
                        return limit.get("maxCount")
        return None

    def image_spec(self, spec_id: str) -> dict | None:
        for spec in self.raw.get("imageSpecs", []):
            if spec.get("specId") == spec_id:
                return spec
        return None

    def describe(self, placement_types: list[str]) -> str:
        """置き場所ごとの、受け付けるグループと画像の仕様を人が読める形にする。"""
        lines = []
        features = [_key(f, "featureId", "feature") for f in self.raw.get("features", [])]
        lines.append(f"features: {', '.join(str(f) for f in features)}")
        for name in placement_types:
            entry = self.placement_type(name)
            lines.append(f"\n{name}（accepts: {entry.get('acceptsAssetCategories')}）")
            for mapping in entry.get("specMappings", []):
                group = _key(mapping, "placementGroupId", "placementGroup")
                limit = self.group_limit(name, group)
                lines.append(f"  group {group}（{FEATURE} の上限: {limit}）")
                for spec_id in mapping.get("specs") or []:
                    spec = self.image_spec(spec_id)
                    if spec is None:
                        lines.append(f"    {spec_id}（動画）")
                        continue
                    d = spec.get("dimensions", {})
                    lines.append(
                        f"    {spec.get('shortName')} {d.get('minWidth')}-{d.get('maxWidth')}x"
                        f"{d.get('minHeight')}-{d.get('maxHeight')} {spec.get('aspectRatio')} "
                        f"{spec.get('fileExtensions')} universal={spec.get('universalAsset')} "
                        f"compatible={spec.get('compatiblePlacementTypes')}"
                    )
        return "\n".join(lines)


# MARK: - Asset Library


class AssetLibrary:
    def __init__(self, client: AppStoreConnect, app_id: str):
        self.client = client
        self.library_id = client.get(f"/v1/apps/{app_id}/assetLibrary")["data"]["id"]

    def ref_data(self) -> RefData:
        data = self.client.get("/v1/appAssetLibraryRefData")["data"]
        if isinstance(data, list):
            data = data[0]
        return RefData(data["attributes"])

    def images_by_reference_name(self) -> dict[str, dict]:
        """Asset Library にある画像を参照名で引けるようにする。"""
        images = self.client.get_all(f"/v1/appAssetLibraries/{self.library_id}/images")
        return {(image.get("attributes") or {}).get("referenceName"): image for image in images}

    def upload_image(self, path: Path, reference_name: str) -> str:
        """予約 → 転送 → 確定し、画像の ID を返す。Apple 側の処理は wait_for_processing でまとめて待つ。"""
        data = path.read_bytes()
        reserved = self.client.post(
            "/v1/appAssetLibraryImages",
            {
                "data": {
                    "type": "appAssetLibraryImages",
                    "attributes": {
                        "fileName": path.name,
                        "fileSize": len(data),
                        "category": CATEGORY,
                        "referenceName": reference_name,
                    },
                    "relationships": {
                        "assetLibrary": {"data": {"type": "appAssetLibraries", "id": self.library_id}}
                    },
                }
            },
        )["data"]
        image_id = reserved["id"]

        for operation in reserved["attributes"]["uploadOperations"]:
            offset = operation["offset"]
            chunk = data[offset:offset + operation["length"]]
            request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"])
            for header in operation.get("requestHeaders", []):
                request.add_header(header["name"], header["value"])
            try:
                with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT):
                    pass
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")
                raise ApiError(f"{path.name} の転送が {error.code} で失敗しました\n{detail}") from None

        self.client.patch(
            f"/v1/appAssetLibraryImages/{image_id}",
            {"data": {"type": "appAssetLibraryImages", "id": image_id, "attributes": {"uploaded": True}}},
        )
        return image_id

    def delete_image(self, image_id: str) -> None:
        self.client.delete(f"/v1/appAssetLibraryImages/{image_id}")

    def wait_for_processing(self, images: dict[str, str]) -> tuple[dict[str, dict], dict[str, str]]:
        """Apple 側の処理が終わるまで、全部の画像をまとめて待つ。

        images は ID → 表示名（言語/ファイル名）。処理が終わった画像の attributes と、
        終わらなかった・失敗した画像の理由を返す。1 枚ずつ待つと、処理が遅い日は 1 枚で上限に達し、
        残りの言語が上がらない（2026-11-10）ので、全部を上げてから待つ。
        """
        print(f"処理を待ちます: {len(images)} 枚（上限 {PROCESSING_TIMEOUT} 秒）")
        deadline = time.time() + PROCESSING_TIMEOUT
        done: dict[str, dict] = {}
        problems: dict[str, str] = {}
        pending = dict(images)
        states: dict[str, str] = {}
        while pending and time.time() < deadline:
            for image_id, label in list(pending.items()):
                try:
                    attributes = self.client.get(f"/v1/appAssetLibraryImages/{image_id}")["data"]["attributes"]
                except (TimeoutError, urllib.error.URLError) as error:
                    # 状態の問い合わせが一時的に時間切れになっても、アップロードは済んでいる。期限まで問い合わせ直す
                    print(f"  {label} の処理の状態を読めませんでした（{error}）。問い合わせ直します")
                    continue
                state = attributes.get("state")
                states[image_id] = state or "?"
                if state == "FAILED":
                    problems[image_id] = f"処理に失敗しました: {attributes.get('stateDetails')}"
                    del pending[image_id]
                # 処理が終わると PREPARE_FOR_SUBMISSION になり、照合した仕様（specId）が入る
                elif state == "PREPARE_FOR_SUBMISSION" and attributes.get("specId"):
                    done[image_id] = {"id": image_id, **attributes}
                    del pending[image_id]
            if pending:
                time.sleep(10)
        for image_id in pending:
            problems[image_id] = f"処理が {PROCESSING_TIMEOUT} 秒で終わりませんでした（{states.get(image_id, '?')}）"
        return done, problems

    def placements(self, localization_id: str, placement_type: str) -> list[dict]:
        return self.client.get_all(
            f"/v1/appStoreVersionLocalizations/{localization_id}/placements",
            {"filter[placementType]": placement_type, "include": "image"},
        )

    def place(self, localization_id: str, placement_type: str, group: str, image_id: str) -> str:
        response = self.client.post(
            "/v1/appAssetLibraryPlacements",
            {
                "data": {
                    "type": "appAssetLibraryPlacements",
                    "attributes": {"placementType": placement_type, "placementGroup": group},
                    "relationships": {
                        "image": {"data": {"type": "appAssetLibraryImages", "id": image_id}},
                        "appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations", "id": localization_id}
                        },
                    },
                }
            },
        )
        return response["data"]["id"]

    def remove(self, placement_id: str) -> None:
        self.client.delete(f"/v1/appAssetLibraryPlacements/{placement_id}")


def placement_group(placement: dict) -> str | None:
    return (placement.get("attributes") or {}).get("placementGroup")


def placement_image_id(placement: dict) -> str | None:
    image = ((placement.get("relationships") or {}).get("image") or {}).get("data") or {}
    return image.get("id")


# MARK: - main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-id", help="省略すると project.pbxproj から読む")
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
    parser.add_argument("--dry-run", action="store_true", help="何も書き換えず、やることだけ出す")
    parser.add_argument("--ref-data", action="store_true", help="置き場所と画像の仕様を出して終わる")
    args = parser.parse_args()

    assets = load_config()
    targets = languages(parse_list(args.languages))

    # テンプレートの仮の文言（TODO:）のまま書き出した画像は反映しない
    source = ROOT / "AppStore" / "creative" / "src" / "creative.html"
    # 説明のコメントにも TODO: と書いてあるので、仮の文言（"TODO: … の形の文字列）だけを見る
    if not args.ref_data and source.is_file() and '"TODO:' in source.read_text(encoding="utf-8"):
        raise SystemExit(f"{source.relative_to(ROOT)} に TODO: が残っています。文言を書き換えて書き出し直してください")

    # 画像が揃っているかは API を叩く前に確かめる
    missing = [
        str(ASSETS_DIR / language.language / asset["file"])
        for language in targets for asset in assets
        if not (ASSETS_DIR / language.language / asset["file"]).is_file()
    ]
    if missing and not args.ref_data:
        raise SystemExit("画像がありません:\n  " + "\n  ".join(missing))

    missing_key = [
        name for name, value in
        [("--key-id", args.key_id), ("--issuer-id", args.issuer_id), ("--private-key", args.private_key)]
        if not value
    ]
    if missing_key:
        raise SystemExit(f"App Store Connect API Key が指定されていません: {', '.join(missing_key)}")

    client = AppStoreConnect(args.key_id, args.issuer_id, args.private_key.read_text())
    app = client.find_app(args.bundle_id or bundle_id())
    library = AssetLibrary(client, app["id"])
    ref_data = library.ref_data()

    if args.ref_data:
        placement_types = sorted({asset["placementType"] for asset in assets})
        print(ref_data.describe(placement_types))
        return 0

    version = client.find_version(app["id"], args.app_version)
    print(f"対象: {app['attributes']['name']} {version['attributes']['versionString']} "
          f"({version['attributes']['appStoreState']})")
    if args.dry_run:
        print("--dry-run: App Store Connect には何も書き込みません")

    localizations = client.localizations(version["id"])
    # 途中の言語で止まって一部の言語だけ差し替わらないよう、書き込む前に全言語ぶん確かめる
    missing_locales = [language.store_locale for language in targets if language.store_locale not in localizations]
    if missing_locales:
        raise SystemExit(f"App Store Connect の {version['attributes']['versionString']} に無い言語: {', '.join(missing_locales)}")
    if args.dry_run:
        for language in targets:
            localization_id = localizations[language.store_locale]
            print(f"  {language.language} → {language.store_locale}")
            for asset in assets:
                placement_type = asset["placementType"]
                path = ASSETS_DIR / language.language / asset["file"]
                existing = library.placements(localization_id, placement_type)
                print(f"    {placement_type}: {path.name} を配置する予定（既存の配置 {len(existing)} 件を外す）")
        print(f"完了: {len(targets)} 言語")
        return 0

    # 1. 全言語の画像を上げる（処理は待たない）。前回の実行で上げた同じ画像があれば、それを使う
    version_string = version["attributes"]["versionString"]
    library_images = library.images_by_reference_name()
    jobs = []  # (言語, 置き場所の設定, 画像のパス, 画像の ID)
    for language in targets:
        for asset in assets:
            path = ASSETS_DIR / language.language / asset["file"]
            # 参照名は Asset Library の中で一意。中身のハッシュを入れて、同じ画像なら上げ直さず、描き直したら別の画像にする
            reference_name = (f"{asset.get('referenceName', asset['placementType'])} "
                              f"{language.language} {version_string} {AppStoreConnect.checksum(path)[:8]}")
            label = f"{language.language}/{path.name}"
            found = library_images.get(reference_name)
            state = ((found or {}).get("attributes") or {}).get("state")
            if found and state in REUSABLE_STATES:
                print(f"  {label}: 前回上げた同じ画像を使う（{state}）")
                jobs.append((language, asset, path, found["id"]))
                continue
            if found and state in RETRYABLE_STATES:
                # 転送の途中で止まった・処理に失敗した画像は、消して上げ直す（参照名が空かないと作れない）
                print(f"  {label}: 前回上げた画像が {state} なので、消して上げ直す")
                library.delete_image(found["id"])
            elif found:
                raise SystemExit(f"{label}: 参照名 {reference_name!r} の画像が {state} の状態で残っています。"
                                 "App Store Connect の画面で確かめてください。")
            jobs.append((language, asset, path, library.upload_image(path, reference_name)))
            print(f"  {label}: 上げた")

    # 2. 処理をまとめて待つ
    done, problems = library.wait_for_processing(
        {image_id: f"{language.language}/{path.name}" for language, _, path, image_id in jobs}
    )

    # 3. 処理が終わった画像から配置する。終わらなかった画像は、流し直せば上げ直さずに続きから待てる
    for language, asset, path, image_id in jobs:
        label = f"{language.language}/{path.name}"
        image = done.get(image_id)
        if image is None:
            continue
        placement_type = asset["placementType"]
        localization_id = localizations[language.store_locale]
        spec = ref_data.image_spec(image.get("specId") or "") or {}
        groups = ref_data.groups_for_spec(placement_type, image.get("specId") or "")
        if not groups:
            problems[image_id] = (f"{spec.get('shortName') or image.get('specId')} を受け付ける "
                                  f"{placement_type} のグループがありません。--ref-data で仕様を確かめてください。")
            continue

        existing = library.placements(localization_id, placement_type)
        placed = {(placement_group(p), placement_image_id(p)) for p in existing}
        if placed == {(group, image_id) for group in groups}:
            print(f"  {label}: {placement_type} に配置済み（{', '.join(groups)}）")
            continue
        for placement in existing:
            library.remove(placement["id"])
        for group in groups:
            library.place(localization_id, placement_type, group, image_id)
        print(f"  {label}: {placement_type}（{spec.get('shortName')}）→ {', '.join(groups)}"
              f"（既存の配置 {len(existing)} 件を外した）")

    if problems:
        labels = {image_id: f"{language.language}/{path.name}" for language, _, path, image_id in jobs}
        listed = "\n".join(f"  {labels.get(i, i)}: {reason}" for i, reason in problems.items())
        raise SystemExit(f"配置できなかった画像が {len(problems)} 枚あります:\n{listed}")
    print(f"完了: {len(targets)} 言語 / {len(jobs)} 枚")
    return 0


if __name__ == "__main__":
    sys.exit(main())
