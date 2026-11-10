#!/usr/bin/env python3
"""App Store Connect API の薄いクライアント。

スクリーンショット（`upload_screenshots.py`）・メタデータ（`upload_metadata.py`）・
App 情報（`upload_app_info.py`）などから使う。認証・バージョンと App 情報の絞り込み・
言語（`appStoreVersionLocalizations` / `appInfoLocalizations`）の取り回しは共通なので、ここに 1 つだけ置く。

認証は App Store Connect API Key（.p8）。次の環境変数から読む想定。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import hashlib
import json
import os
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

#: App 情報（appInfos。名前・サブタイトル・カテゴリ・年齢制限など）を書き換えられる状態。
#: 配信中のアプリには配信中の App 情報（READY_FOR_DISTRIBUTION）と、次のバージョン用の App 情報の 2 つがある
EDITABLE_APP_INFO_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
}

#: アップロード後、Apple 側の取り込みが終わるのを待つ上限（秒）
# Apple 側の取り込みは 5 分を超えることがある（2026-11-10 に idfa-vault-ios の iPhone 6.9 inch・iPad 13 inch で止まった）ので、
# 環境変数で延ばせるようにする
DELIVERY_TIMEOUT = int(os.environ.get("SCREENSHOT_DELIVERY_TIMEOUT") or 300)

#: 取り込み・処理の待ちで、状態を問い合わせ直すまでの間隔（秒）
POLL_INTERVAL = 30

#: 1 リクエストあたりの待ち時間の上限（秒）。指定しないと応答が無いときに無期限に待つ
REQUEST_TIMEOUT = 60

#: トークンの有効期限（秒）。App Store Connect の上限は 20 分
TOKEN_LIFETIME = 15 * 60

#: 期限までこの秒数を切ったらトークンを作り直す。
#: スクリーンショットは取り込み待ちで 1 言語あたり数分かかるので、1 本のトークンでは足りなくなる
TOKEN_REFRESH_MARGIN = 5 * 60


class ApiError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        #: HTTP のステータスコード（転送の失敗など、API の応答でないときは None）
        self.status = status


#: 待っているあいだの状態の問い合わせで、問い合わせ直してよい HTTP のステータス（混雑・一時的なサーバーの不調）
TRANSIENT_STATUSES = {429, 500, 502, 503, 504}


def is_transient(error: Exception) -> bool:
    """状態の問い合わせの失敗が一時的なもの（時間切れ・接続の失敗・429 / 5xx）か。"""
    if isinstance(error, ApiError):
        return error.status in TRANSIENT_STATUSES
    return isinstance(error, (TimeoutError, urllib.error.URLError))


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
        for attempt in range(2):
            request = urllib.request.Request(url, data=body, method=method)
            request.add_header("Authorization", f"Bearer {self.token}")
            if body is not None:
                request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                    raw = response.read()
                return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")
                # 期限内のトークンでも、まれに 401 NOT_AUTHORIZED が返る（2026-11-10 に作ってから 4 分のトークンで出た）。
                # 401 のリクエストは処理されていないので、トークンを作り直して 1 回だけ送り直す
                if error.code == 401 and attempt == 0:
                    print(f"  {method} {url} が 401 だったので、トークンを作り直して送り直します")
                    self._token_expires_at = 0.0
                    continue
                raise ApiError(f"{method} {url} が {error.code} で失敗しました\n{detail}", error.code) from None
        raise AssertionError("unreachable")

    def get(self, path: str, params: dict | None = None) -> dict:
        url = f"{API}{path}"
        if params:
            query = urllib.parse.urlencode(params)
            url = f"{url}?{query}"
        return self._request("GET", url)

    def get_or_none(self, path: str, params: dict | None = None) -> dict | None:
        """1 件を返すエンドポイントの `data`。まだ作られていない（404 か data が null）なら None。

        価格・配信状況・審査の情報などは、App Store Connect で一度も設定していないと 404 になる。
        """
        try:
            return self.get(path, params).get("data")
        except ApiError as error:
            if error.status == 404:
                return None
            raise

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

    def versions(self, app_id: str) -> list[dict]:
        return self.get_all(
            f"/v1/apps/{app_id}/appStoreVersions",
            {"filter[platform]": "IOS", "limit": 50},
        )

    @staticmethod
    def is_editable(version: dict) -> bool:
        return version["attributes"]["appStoreState"] in EDITABLE_STATES

    def find_version(self, app_id: str, version_string: str | None, reference: bool = False) -> dict:
        """書き換えられるバージョンを返す。

        `reference` を True にすると（dry-run で使う）、編集できるバージョンが無いときに止めず、
        いちばん新しいバージョン（審査中・配信中など）を比べる相手として返す。
        返したバージョンが書き換えられるかは `is_editable` で見る。
        """
        versions = self.versions(app_id)
        editable = [v for v in versions if self.is_editable(v)]

        if version_string:
            for version in versions:
                if version["attributes"]["versionString"] == version_string:
                    state = version["attributes"]["appStoreState"]
                    if state not in EDITABLE_STATES and not reference:
                        raise SystemExit(
                            f"バージョン {version_string} は {state} のため編集できません"
                        )
                    return version
            raise SystemExit(f"バージョン {version_string} が見つかりません")

        if not editable and reference and versions:
            return max(versions, key=lambda v: v["attributes"].get("createdDate") or "")
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

    def find_app_info(self, app_id: str, reference: bool = False) -> dict:
        """書き換えられる App 情報（appInfos）を返す。

        App 情報はバージョンとは別のリソースで、名前・サブタイトル・プライバシーポリシーの URL（言語ごと）と、
        カテゴリ・年齢制限を持つ。次のバージョンを作ると、そのバージョン用の App 情報が「提出準備中」でできる。

        `reference` を True にすると（dry-run で使う）、書き換えられる App 情報が無いときに止めず、
        審査中のバージョンの App 情報か、無ければ配信中の App 情報を比べる相手として返す。
        """
        infos = self.get_all(f"/v1/apps/{app_id}/appInfos")

        def state(info: dict) -> str | None:
            # state が無い古い応答では、非推奨の appStoreState（バージョンと同じ値）で見る
            return info["attributes"].get("state") or info["attributes"].get("appStoreState")

        def editable(info: dict) -> bool:
            if info["attributes"].get("state"):
                return info["attributes"]["state"] in EDITABLE_APP_INFO_STATES
            return info["attributes"].get("appStoreState") in EDITABLE_STATES

        candidates = [info for info in infos if editable(info)]
        if not candidates and reference and infos:
            # 配信中（READY_FOR_DISTRIBUTION）より、審査中など次のバージョン用のものを優先する
            live_states = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}
            live = [info for info in infos if state(info) in live_states]
            pending = [info for info in infos if state(info) not in live_states | {"REPLACED_WITH_NEW_INFO"}]
            return (pending or live or infos)[0]
        if not candidates:
            states = ", ".join(sorted({str(state(info)) for info in infos}))
            raise SystemExit(
                "編集できる状態の App 情報がありません"
                f"（いまある状態: {states or 'なし'}）。"
                "App Store Connect で次のバージョンを作ってから実行してください。"
            )
        if len(candidates) > 1:
            raise SystemExit(
                f"編集できる App 情報が {len(candidates)} つあります。App Store Connect の画面で状態を確認してください。"
            )
        return candidates[0]

    def app_info_localization_entries(self, app_info_id: str) -> dict[str, dict]:
        """ロケール → そのロケールの `appInfoLocalizations`（名前・サブタイトルなどの現在値を含む）。"""
        entries = self.get_all(f"/v1/appInfos/{app_info_id}/appInfoLocalizations")
        return {entry["attributes"]["locale"]: entry for entry in entries}

    def create_app_info_localization(self, app_info_id: str, locale: str, attributes: dict) -> str:
        """App 情報に言語を追加する。名前（name）が無いと作れない。

        バージョンの言語（appStoreVersionLocalizations）とは別物で、片方を作ってももう片方はできない。
        アプリを作ったときの言語（プライマリ言語）にしか無いので、2 つ目の言語はここで作る。
        """
        if self.dry_run:
            return "dry-run"
        response = self.post(
            "/v1/appInfoLocalizations",
            {
                "data": {
                    "type": "appInfoLocalizations",
                    "attributes": {**attributes, "locale": locale},
                    "relationships": {
                        "appInfo": {"data": {"type": "appInfos", "id": app_info_id}}
                    },
                }
            },
        )
        return response["data"]["id"]

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

    def set_screenshots(self, set_id: str) -> list[dict]:
        """セットに載っているスクリーンショット（App Store に並ぶ順）。"""
        return self.get_all(f"/v1/appScreenshotSets/{set_id}/appScreenshots")

    @staticmethod
    def checksum(path: Path) -> str:
        """App Store Connect の sourceFileChecksum と同じ MD5。"""
        return hashlib.md5(path.read_bytes()).hexdigest()

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
                        "sourceFileChecksum": self.checksum(path),
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

    def wait_for_delivery(self, screenshots: dict[str, str]) -> None:
        """Apple 側の取り込みが終わるまで待つ。失敗していればここで気づける。

        screenshots は ID → 表示名（言語/ファイル名）。全言語ぶんを上げてから 1 回で待つ。
        1 言語ずつ待つと、Apple 側の処理が遅い日は 1 言語目で上限に達し、残りの言語が上がらない（2026-11-10）。
        """
        if self.dry_run or not screenshots:
            return
        print(f"  取り込みを待ちます: {len(screenshots)} 枚（上限 {DELIVERY_TIMEOUT} 秒）")
        deadline = time.time() + DELIVERY_TIMEOUT
        pending = dict(screenshots)
        states: dict[str, str] = {}
        while pending and time.time() < deadline:
            still_pending = {}
            for screenshot_id, label in pending.items():
                try:
                    attributes = self.get(f"/v1/appScreenshots/{screenshot_id}")["data"]["attributes"]
                except (TimeoutError, urllib.error.URLError, ApiError) as error:
                    # 状態の問い合わせが一時的に失敗しても、アップロードは済んでいる。期限まで問い合わせ直す
                    if not is_transient(error):
                        raise
                    print(f"  {label} の取り込みの状態を読めませんでした（{error}）。問い合わせ直します")
                    still_pending[screenshot_id] = label
                    continue
                state = attributes.get("assetDeliveryState") or {}
                if state.get("errors"):
                    raise SystemExit(f"{label} の取り込みに失敗しました: {state['errors']}")
                if state.get("state") != "COMPLETE":
                    still_pending[screenshot_id] = label
                    states[screenshot_id] = state.get("state") or "?"
            pending = still_pending
            if pending:
                # 1 枚ずつ問い合わせるので、間隔を詰めると問い合わせの数が多くなりすぎる（36 枚なら 1 周で 36 回）
                time.sleep(POLL_INTERVAL)
        if pending:
            listed = "\n".join(f"  {label}（{states.get(i, '?')}）" for i, label in pending.items())
            raise SystemExit(
                f"{len(pending)} 枚の取り込みが {DELIVERY_TIMEOUT} 秒で終わりませんでした。\n{listed}\n"
                "上げた画像はそのまま残しています。同じ画像で流し直すと、上げ直さずに取り込みの完了を待ちます。"
            )


def make_token(key_id: str, issuer_id: str, private_key: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
