#!/usr/bin/env python3
"""App Store Connect API の薄いクライアント。

スクリーンショット（`upload_screenshots.py`）とメタデータ（`upload_metadata.py`）の
両方から使う。認証・バージョンの絞り込み・言語（`appStoreVersionLocalizations`）の
取り回しは共通なので、ここに 1 つだけ置く。

認証は App Store Connect API Key（.p8）。次の環境変数から読む想定。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import jwt
except ImportError:  # pragma: no cover - 実行環境の問題なので案内だけ出す
    raise SystemExit(
        "PyJWT が入っていません。`python3 -m pip install pyjwt cryptography` を実行してください。"
    )

API = "https://api.appstoreconnect.apple.com"

#: スクリーンショットを差し替えられるバージョンの状態。
#: 審査中（WAITING_FOR_REVIEW / IN_REVIEW）や配信済み（READY_FOR_SALE）は触らない。
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}

#: アップロード後、Apple 側の取り込みが終わるのを待つ上限（秒）
DELIVERY_TIMEOUT = 300

#: 1 リクエストあたりの待ち時間の上限（秒）。指定しないと応答が無いときに無期限に待つ
REQUEST_TIMEOUT = 60

#: トークンの有効期限（秒）。App Store Connect の上限は 20 分
TOKEN_LIFETIME = 15 * 60

#: 期限までこの秒数を切ったらトークンを作り直す。
#: スクリーンショットは取り込み待ちで 1 言語あたり数分かかるので、1 本のトークンでは足りなくなる
TOKEN_REFRESH_MARGIN = 5 * 60


class ApiError(RuntimeError):
    pass


class AppStoreConnect:
    def __init__(self, key_id: str, issuer_id: str, private_key: str, dry_run: bool = False):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.dry_run = dry_run
        self._token = ""
        self._token_expires_at = 0.0

    @property
    def token(self) -> str:
        """期限が近づいていたら作り直したトークンを返す。"""
        if time.time() > self._token_expires_at - TOKEN_REFRESH_MARGIN:
            self._token = make_token(self.key_id, self.issuer_id, self.private_key)
            self._token_expires_at = time.time() + TOKEN_LIFETIME
        return self._token

    # MARK: 低レベル

    def _request(self, method: str, url: str, payload: dict | None = None) -> dict:
        body = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise ApiError(f"{method} {url} が {error.code} で失敗しました\n{detail}") from None
        return json.loads(raw) if raw else {}

    def get(self, path: str, params: dict | None = None) -> dict:
        url = f"{API}{path}"
        if params:
            query = urllib.parse.urlencode(params)
            url = f"{url}?{query}"
        return self._request("GET", url)

    def get_all(self, path: str, params: dict | None = None) -> list[dict]:
        """ページングをたどって全件返す。"""
        params = dict(params or {})
        params.setdefault("limit", 200)
        result: list[dict] = []
        url = f"{API}{path}?{urllib.parse.urlencode(params)}"
        while url:
            page = self._request("GET", url)
            result.extend(page.get("data", []))
            url = page.get("links", {}).get("next")
        return result

    def post(self, path: str, payload: dict) -> dict:
        return self._request("POST", f"{API}{path}", payload)

    def patch(self, path: str, payload: dict) -> dict:
        return self._request("PATCH", f"{API}{path}", payload)

    def delete(self, path: str) -> None:
        self._request("DELETE", f"{API}{path}")

    # MARK: アプリとバージョン

    def find_app(self, bundle_id: str) -> dict:
        # filter[bundleId] は前方一致でも返ることがあるので、完全に一致するものだけを採る
        apps = [
            app for app in self.get_all("/v1/apps", {"filter[bundleId]": bundle_id})
            if app["attributes"]["bundleId"] == bundle_id
        ]
        if not apps:
            raise SystemExit(f"bundleId が {bundle_id} のアプリが見つかりません")
        return apps[0]

    def find_version(self, app_id: str, version_string: str | None) -> dict:
        versions = self.get_all(
            f"/v1/apps/{app_id}/appStoreVersions",
            {"filter[platform]": "IOS", "limit": 50},
        )
        editable = [v for v in versions if v["attributes"]["appStoreState"] in EDITABLE_STATES]

        if version_string:
            for version in versions:
                if version["attributes"]["versionString"] == version_string:
                    state = version["attributes"]["appStoreState"]
                    if state not in EDITABLE_STATES:
                        raise SystemExit(
                            f"バージョン {version_string} は {state} のため編集できません"
                        )
                    return version
            raise SystemExit(f"バージョン {version_string} が見つかりません")

        if not editable:
            states = ", ".join(sorted({v["attributes"]["appStoreState"] for v in versions}))
            raise SystemExit(
                "編集できる状態のバージョンがありません"
                f"（いまある状態: {states or 'なし'}）。"
                "App Store Connect で次のバージョンを作ってから実行してください。"
            )
        if len(editable) > 1:
            names = ", ".join(v["attributes"]["versionString"] for v in editable)
            raise SystemExit(
                f"編集できるバージョンが複数あります（{names}）。--app-version で選んでください。"
            )
        return editable[0]

    def localizations(self, version_id: str) -> dict[str, str]:
        return {locale: entry["id"] for locale, entry in self.localization_entries(version_id).items()}

    def localization_entries(self, version_id: str) -> dict[str, dict]:
        """ロケール → そのロケールの `appStoreVersionLocalizations`（説明文などの現在値を含む）。"""
        entries = self.get_all(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
        return {entry["attributes"]["locale"]: entry for entry in entries}

    def create_localization(self, version_id: str, locale: str,
                            attributes: dict | None = None) -> str:
        """そのバージョンに言語を追加する。

        スクリーンショットも説明文も置き場所は言語ごとにしかないため、App Store Connect
        側にその言語が無いと反映できない。`attributes` を渡さない場合、説明文やキーワードは
        空のまま作られるので、審査に出す前に埋める必要がある
        （`upload_metadata.py` はここで一緒に書き込む）。
        """
        if self.dry_run:
            return "dry-run"
        response = self.post(
            "/v1/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {**(attributes or {}), "locale": locale},
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
        )
        return response["data"]["id"]

    # MARK: スクリーンショット

    def existing_set(self, localization_id: str, display_type: str) -> str | None:
        sets = self.get_all(
            f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
            {"filter[screenshotDisplayType]": display_type},
        )
        return sets[0]["id"] if sets else None

    def create_set(self, localization_id: str, display_type: str) -> str:
        if self.dry_run:
            return "dry-run"
        response = self.post(
            "/v1/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display_type},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations", "id": localization_id}
                        }
                    },
                }
            },
        )
        return response["data"]["id"]

    def upload(self, set_id: str, path: Path) -> str:
        """1 枚ぶんの予約 → 本体の転送 → 確定、までをやる。"""
        data = path.read_bytes()
        if self.dry_run:
            return "dry-run"

        reserved = self.post(
            "/v1/appScreenshots",
            {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileSize": len(data), "fileName": path.name},
                    "relationships": {
                        "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}
                    },
                }
            },
        )
        screenshot_id = reserved["data"]["id"]

        # 本体は Apple が指定する URL へ、指示どおりに分割して送る
        for operation in reserved["data"]["attributes"]["uploadOperations"]:
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

        self.patch(
            f"/v1/appScreenshots/{screenshot_id}",
            {
                "data": {
                    "type": "appScreenshots",
                    "id": screenshot_id,
                    "attributes": {
                        "uploaded": True,
                        "sourceFileChecksum": hashlib.md5(data).hexdigest(),
                    },
                }
            },
        )
        return screenshot_id

    def reorder(self, set_id: str, screenshot_ids: list[str]) -> None:
        """App Store に並ぶ順を、ファイル名の順（01_… 02_…）に揃える。"""
        if self.dry_run:
            return
        self.patch(
            f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": i} for i in screenshot_ids]},
        )

    def wait_for_delivery(self, screenshot_ids: list[str]) -> None:
        """Apple 側の取り込みが終わるまで待つ。失敗していればここで気づける。"""
        if self.dry_run:
            return
        deadline = time.time() + DELIVERY_TIMEOUT
        pending = list(screenshot_ids)
        while pending and time.time() < deadline:
            still_pending = []
            for screenshot_id in pending:
                attributes = self.get(f"/v1/appScreenshots/{screenshot_id}")["data"]["attributes"]
                state = attributes.get("assetDeliveryState") or {}
                if state.get("errors"):
                    raise SystemExit(
                        f"{attributes.get('fileName')} の取り込みに失敗しました: {state['errors']}"
                    )
                if state.get("state") != "COMPLETE":
                    still_pending.append(screenshot_id)
            pending = still_pending
            if pending:
                time.sleep(5)
        if pending:
            raise SystemExit(
                f"{len(pending)} 枚の取り込みが {DELIVERY_TIMEOUT} 秒で終わりませんでした。"
                "App Store Connect の画面で状態を確認してください。"
            )


def make_token(key_id: str, issuer_id: str, private_key: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
