#!/usr/bin/env python3
"""プロダクトページのヘッダーと検索結果のクリエイティブアセットを App Store Connect に反映する。

iOS 27 から、スクリーンショットとは別に「クリエイティブアセット」を App Store に載せられる
（https://developer.apple.com/app-store/asset-best-practices/）。置き場所と元ネタは
`AppStore/creative_assets.json`、画像は `AppStore/creative/<言語>/<ファイル名>`。

    python3 Tools/upload_creative_assets.py               # 全言語を反映する
    python3 Tools/upload_creative_assets.py --dry-run     # 何も書き換えず、やることだけ出す
    python3 Tools/upload_creative_assets.py --ref-data    # 置き場所と画像の仕様を App Store Connect から読んで出す

App Asset Library の API で、言語ごとに次の順で反映する。

1. 画像を Asset Library に上げ（予約 → 転送 → 確定）、Apple 側の処理が終わるのを待つ
2. 処理で決まった画像の仕様（specId）を受け付ける置き場所のグループを、参照データから探す
3. その言語の同じ置き場所にある既存の配置を外し、新しい画像を配置する

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
PROCESSING_TIMEOUT = 600

#: App Store のバージョンに載せるときの機能名（参照データの features）
FEATURE = "APP_STORE_VERSIONS"

CATEGORY = "CREATIVE_ASSETS"


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

    def upload_image(self, path: Path, reference_name: str) -> dict:
        """予約 → 転送 → 確定し、処理が終わった画像の attributes を返す。"""
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

        deadline = time.time() + PROCESSING_TIMEOUT
        while True:
            attributes = self.client.get(f"/v1/appAssetLibraryImages/{image_id}")["data"]["attributes"]
            state = attributes.get("state")
            if state == "FAILED":
                raise SystemExit(f"{path.name} の処理に失敗しました: {attributes.get('stateDetails')}")
            if state not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
                return {"id": image_id, **attributes}
            if time.time() > deadline:
                raise SystemExit(f"{path.name} の処理が {PROCESSING_TIMEOUT} 秒で終わりませんでした（{state}）")
            time.sleep(5)

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
    if not args.ref_data and source.is_file() and "TODO:" in source.read_text(encoding="utf-8"):
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
    for language in targets:
        localization_id = localizations.get(language.store_locale)
        if localization_id is None:
            raise SystemExit(f"App Store Connect に {language.store_locale} の言語がありません")
        print(f"  {language.language} → {language.store_locale}")

        for asset in assets:
            placement_type = asset["placementType"]
            path = ASSETS_DIR / language.language / asset["file"]
            existing = library.placements(localization_id, placement_type)
            if args.dry_run:
                print(f"    {placement_type}: {path.name} を配置する予定（既存の配置 {len(existing)} 件を外す）")
                continue

            reference_name = (f"{asset.get('referenceName', placement_type)} "
                              f"{language.language} {version['attributes']['versionString']}")
            image = library.upload_image(path, reference_name)
            spec = ref_data.image_spec(image.get("specId") or "") or {}
            groups = ref_data.groups_for_spec(placement_type, image.get("specId") or "")
            if not groups:
                raise SystemExit(
                    f"{path.name}（{spec.get('shortName') or image.get('specId')}）を受け付ける "
                    f"{placement_type} のグループがありません。--ref-data で仕様を確かめてください。"
                )

            for placement in existing:
                library.remove(placement["id"])
            for group in groups:
                library.place(localization_id, placement_type, group, image["id"])
            print(f"    {placement_type}: {path.name}（{spec.get('shortName')}）→ {', '.join(groups)}"
                  f"（既存の配置 {len(existing)} 件を外した）")

    print(f"完了: {len(targets)} 言語")
    return 0


if __name__ == "__main__":
    sys.exit(main())
