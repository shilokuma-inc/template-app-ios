#!/usr/bin/env python3
"""App 情報（カテゴリ・コンテンツの権利・年齢制限）・App Review に関する情報・価格と配信状況を App Store Connect に反映する。

`AppStore/app_info.json` を読む。名前・サブタイトル・プライバシーポリシーの URL・著作権は、
言語ごとの掲載文と一緒に `upload_metadata.py` が反映する。

    python3 Tools/upload_app_info.py            # 反映する
    python3 Tools/upload_app_info.py --dry-run  # 現在値との差分だけ出す
    python3 Tools/upload_app_info.py --check    # App Store Connect につながず、手元のファイルだけ検査する

書き込み先（App Store Connect の画面では「App 情報」「価格および配信状況」とバージョンのページに分かれている）:

    アプリ（apps）                                    … コンテンツの権利
    App 情報（appInfos）                              … カテゴリ
    年齢制限（ageRatingDeclarations）                 … 年齢制限の質問への回答
    App Review に関する情報（appStoreReviewDetails）  … 連絡先・メモ・デモアカウント（バージョンごと）
    価格（appPriceSchedules）・配信状況（appAvailabilities） … App Store Connect で未設定のときだけ

価格と配信状況は、一度決めたら App Store Connect の画面で変える前提なので、設定済みなら触らない
（JSON を書き換えても、配信中のアプリの価格や配信先が変わらないようにするため）。

審査の連絡先とデモアカウントは個人情報・秘密なので JSON には書かず、環境変数で渡す（GitHub Actions では Secrets）。
値はログに出さない。

    APP_REVIEW_CONTACT_FIRST_NAME / APP_REVIEW_CONTACT_LAST_NAME / APP_REVIEW_CONTACT_PHONE / APP_REVIEW_CONTACT_EMAIL
    APP_REVIEW_DEMO_ACCOUNT_NAME / APP_REVIEW_DEMO_ACCOUNT_PASSWORD（review.demoAccountRequired が true のときだけ使う）

連絡先の環境変数が 1 つも無いときは、連絡先を書き込まない（App Store Connect 側の値を残す）。

認証は App Store Connect API Key（.p8）。次の環境変数でも渡せる。

    APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH

触るのは **編集できる状態のバージョンと App 情報だけ**。JSON に書いていない項目は App Store Connect 側の値をそのまま残す。

PyJWT が要る（--check では不要）: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import ROOT, bundle_id
from upload_metadata import describe_changes

CONFIG_PATH = ROOT / "AppStore" / "app_info.json"

CONTENT_RIGHTS = ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT")

#: 年齢制限の質問のうち、頻度で答えるもの（App Store Connect API 4.5 の ageRatingDeclarations）
AGE_RATING_LEVEL_QUESTIONS = (
    "alcoholTobaccoOrDrugUseOrReferences",
    "contests",
    "gamblingSimulated",
    "gunsOrOtherWeapons",
    "horrorOrFearThemes",
    "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation",
    "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity",
    "sexualContentOrNudity",
    "violenceCartoonOrFantasy",
    "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
)
AGE_RATING_LEVELS = ("NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE", "INFREQUENT", "FREQUENT")

#: 年齢制限の質問のうち、はい / いいえ（true / false）で答えるもの
AGE_RATING_YES_NO_QUESTIONS = (
    "advertising",
    "ageAssurance",
    "gambling",
    "healthOrWellnessTopics",
    "lootBox",
    "messagingAndChat",
    "parentalControls",
    "socialMedia",
    "unrestrictedWebAccess",
    "userGeneratedContent",
)

#: 答えなくてよい項目（ほかの答えによって聞かれるもの・キッズカテゴリ・年齢制限の上書き）。書いたら形だけ確かめる
AGE_RATING_OPTIONAL = {
    "socialMediaAgeRestricted": bool,
    "kidsAgeBand": ("FIVE_AND_UNDER", "SIX_TO_EIGHT", "NINE_TO_ELEVEN"),
    "ageRatingOverrideV2": ("NONE", "NINE_PLUS", "THIRTEEN_PLUS", "SIXTEEN_PLUS", "EIGHTEEN_PLUS", "UNRATED"),
    "developerAgeRatingInfoUrl": str,
}

#: カテゴリの書き方（JSON のキー）→ App 情報の relationships の名前
CATEGORY_KEYS = {
    "primaryCategory": "primaryCategory",
    "secondaryCategory": "secondaryCategory",
}
SUBCATEGORY_KEYS = {
    "primarySubcategories": ("primarySubcategoryOne", "primarySubcategoryTwo"),
    "secondarySubcategories": ("secondarySubcategoryOne", "secondarySubcategoryTwo"),
}

#: 審査のメモの上限
REVIEW_NOTES_LIMIT = 4000

#: 審査の連絡先 → 渡す環境変数（GitHub Actions では同じ名前の Secrets）
CONTACT_ENV = {
    "contactFirstName": "APP_REVIEW_CONTACT_FIRST_NAME",
    "contactLastName": "APP_REVIEW_CONTACT_LAST_NAME",
    "contactPhone": "APP_REVIEW_CONTACT_PHONE",
    "contactEmail": "APP_REVIEW_CONTACT_EMAIL",
}
DEMO_ACCOUNT_ENV = {
    "demoAccountName": "APP_REVIEW_DEMO_ACCOUNT_NAME",
    "demoAccountPassword": "APP_REVIEW_DEMO_ACCOUNT_PASSWORD",
}

#: ログに値を出さない項目
HIDDEN_FIELDS = set(CONTACT_ENV) | set(DEMO_ACCOUNT_ENV)

TERRITORY_PATTERN = re.compile(r"[A-Z]{3}")
CATEGORY_PATTERN = re.compile(r"[A-Z][A-Z_]*")


# MARK: - 読み込みと検査


def placeholders(value, path: str = "") -> list[str]:
    """テンプレートの仮の値（TODO:）が残っている場所。`_comment` は見ない。"""
    if isinstance(value, dict):
        return [
            found for key, child in value.items() if key != "_comment"
            for found in placeholders(child, f"{path}.{key}" if path else key)
        ]
    if isinstance(value, list):
        return [found for index, child in enumerate(value) for found in placeholders(child, f"{path}[{index}]")]
    return [path] if isinstance(value, str) and "TODO:" in value else []


def without_comment(value: dict) -> dict:
    return {key: child for key, child in value.items() if key != "_comment"}


def check_category(value, name: str, problems: list[str]) -> str | None:
    if not (isinstance(value, str) and value.strip()):
        problems.append(f"{name} は文字列で書く（例: \"UTILITIES\"）")
        return None
    if "TODO:" not in value and not CATEGORY_PATTERN.fullmatch(value):
        problems.append(f"{name} は App Store Connect のカテゴリの ID で書く（例: \"UTILITIES\"）: {value}")
    return value


def load_categories(raw: dict, problems: list[str]) -> dict[str, str]:
    """カテゴリを、App 情報の relationships の名前 → カテゴリの ID にする。"""
    categories: dict[str, str] = {}
    if "primaryCategory" not in raw:
        problems.append("primaryCategory がありません（App 情報のプライマリカテゴリは必須）")
    for key, relationship in CATEGORY_KEYS.items():
        if key in raw:
            value = check_category(raw[key], key, problems)
            if value:
                categories[relationship] = value
    for key, relationships in SUBCATEGORY_KEYS.items():
        if key not in raw:
            continue
        values = raw[key]
        if not isinstance(values, list) or len(values) > len(relationships):
            problems.append(f"{key} は {len(relationships)} つまでの配列で書く（例: [\"GAMES_PUZZLE\"]）")
            continue
        for index, (relationship, value) in enumerate(zip(relationships, values)):
            value = check_category(value, f"{key}[{index}]", problems)
            if value:
                categories[relationship] = value
    return categories


def load_age_rating(raw, problems: list[str]) -> dict:
    if not isinstance(raw, dict):
        problems.append("ageRating がありません（年齢制限の質問への回答は必須）")
        return {}
    answers = without_comment(raw)
    for key in AGE_RATING_LEVEL_QUESTIONS:
        if answers.get(key) not in AGE_RATING_LEVELS:
            problems.append(f"ageRating.{key} は {' / '.join(AGE_RATING_LEVELS)} のどれかで書く: {answers.get(key)!r}")
    for key in AGE_RATING_YES_NO_QUESTIONS:
        if not isinstance(answers.get(key), bool):
            problems.append(f"ageRating.{key} は true か false で書く: {answers.get(key)!r}")
    for key, kind in AGE_RATING_OPTIONAL.items():
        if key not in answers:
            continue
        value = answers[key]
        valid = isinstance(value, kind) if isinstance(kind, type) else value in kind
        if not valid:
            expected = kind.__name__ if isinstance(kind, type) else " / ".join(kind)
            problems.append(f"ageRating.{key} の値が不正です（{expected}）: {value!r}")
    known = set(AGE_RATING_LEVEL_QUESTIONS) | set(AGE_RATING_YES_NO_QUESTIONS) | set(AGE_RATING_OPTIONAL)
    unknown = sorted(set(answers) - known)
    if unknown:
        problems.append(
            f"ageRating に知らない項目があります: {', '.join(unknown)}。"
            "Apple が質問を足したときは Tools/upload_app_info.py の一覧にも足す"
        )
    return answers


def load_review(raw, problems: list[str]) -> dict:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        problems.append("review はオブジェクトで書く")
        return {}
    review = without_comment(raw)
    attributes: dict = {}
    if "demoAccountRequired" in review:
        if isinstance(review["demoAccountRequired"], bool):
            attributes["demoAccountRequired"] = review["demoAccountRequired"]
        else:
            problems.append("review.demoAccountRequired は true か false で書く")
    if "notes" in review:
        notes = review["notes"]
        if not (isinstance(notes, str) and notes.strip()):
            problems.append("review.notes が空です（使わないなら項目ごと消す）")
        elif len(notes) > REVIEW_NOTES_LIMIT:
            problems.append(f"review.notes が {len(notes)} 字あります（上限 {REVIEW_NOTES_LIMIT} 字）")
        else:
            attributes["notes"] = notes
    unknown = sorted(set(review) - {"demoAccountRequired", "notes"})
    if unknown:
        problems.append(
            f"review に知らない項目があります: {', '.join(unknown)}"
            "（連絡先とデモアカウントは JSON に書かず、環境変数か Secrets で渡す）"
        )
    return attributes


def load_pricing(raw, problems: list[str]) -> dict | None:
    if raw is None:
        return None
    pricing = without_comment(raw) if isinstance(raw, dict) else {}
    if pricing.get("price") != "FREE":
        problems.append("pricing.price は \"FREE\" だけ書ける（有料にするときは App Store Connect の画面で設定し、pricing を消す）")
    base = pricing.get("baseTerritory")
    if not (isinstance(base, str) and TERRITORY_PATTERN.fullmatch(base)):
        problems.append(f"pricing.baseTerritory は国と地域の 3 文字のコードで書く（例: \"JPN\"）: {base!r}")
    return pricing


def load_availability(raw, problems: list[str]) -> dict | None:
    if raw is None:
        return None
    availability = without_comment(raw) if isinstance(raw, dict) else {}
    territories = availability.get("territories")
    if territories != "ALL" and not (
        isinstance(territories, list) and territories
        and all(isinstance(code, str) and TERRITORY_PATTERN.fullmatch(code) for code in territories)
    ):
        problems.append("availability.territories は \"ALL\" か、国と地域の 3 文字のコードの配列で書く（例: [\"JPN\"]）")
    if not isinstance(availability.get("availableInNewTerritories"), bool):
        problems.append("availability.availableInNewTerritories は true か false で書く")
    return availability


def load(path: Path) -> tuple[dict, list[str]]:
    if not path.is_file():
        return {}, [f"{path} がありません"]
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return {}, [f"{path} が JSON として読めません: {error}"]

    problems: list[str] = []
    config = {
        "categories": load_categories(raw, problems),
        "contentRights": raw.get("contentRightsDeclaration"),
        "ageRating": load_age_rating(raw.get("ageRating"), problems),
        "review": load_review(raw.get("review"), problems),
        "pricing": load_pricing(raw.get("pricing"), problems),
        "availability": load_availability(raw.get("availability"), problems),
        "placeholders": placeholders(raw),
    }
    if config["contentRights"] not in CONTENT_RIGHTS:
        problems.append(f"contentRightsDeclaration は {' / '.join(CONTENT_RIGHTS)} のどちらかで書く")
    return config, [f"{path}: {problem}" for problem in problems]


def review_from_environment(review: dict) -> tuple[dict, list[str]]:
    """JSON の審査の情報に、環境変数の連絡先とデモアカウントを足す。"""
    attributes = dict(review)
    notices: list[str] = []
    contact = {field: os.environ.get(name, "").strip() for field, name in CONTACT_ENV.items()}
    if all(contact.values()):
        attributes.update(contact)
    elif any(contact.values()):
        missing = [CONTACT_ENV[field] for field, value in contact.items() if not value]
        raise SystemExit(f"審査の連絡先の環境変数が足りません: {', '.join(missing)}（4 つそろえるか、すべて外す）")
    else:
        notices.append(f"連絡先の環境変数（{', '.join(CONTACT_ENV.values())}）が無いので、連絡先は書き込みません")

    if review.get("demoAccountRequired"):
        demo = {field: os.environ.get(name, "") for field, name in DEMO_ACCOUNT_ENV.items()}
        if all(demo.values()):
            attributes.update(demo)
        else:
            notices.append(
                f"デモアカウントの環境変数（{', '.join(DEMO_ACCOUNT_ENV.values())}）が無いので、"
                "デモアカウントは書き込みません"
            )
    return attributes, notices


# MARK: - 差分の表示


def show(value) -> str:
    if value is None or value == "":
        return "（空）"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def describe(current: dict, new: dict) -> list[str]:
    """現在値から変わる項目を、人が読める形で返す。連絡先などの値は出さない。"""
    lines: list[str] = []
    for field, value in new.items():
        before = current.get(field)
        if before == value:
            continue
        if field in HIDDEN_FIELDS:
            lines.append(f"    {field}: {'（空）' if not before else '（入力済み）'} → （環境変数の値）")
        elif isinstance(value, str) and ("\n" in value or "\n" in (before or "")):
            lines.extend(describe_changes({field: before}, {field: value}))
        else:
            lines.append(f"    {field}: {show(before)} → {show(value)}")
    return lines


# MARK: - 反映の計画


#: 1 つの書き込み先について、表示する見出し・差分と、書き込む処理（書き込まないなら None）
Step = tuple[str, list[str], "Callable[[], object] | None"]


def plan_content_rights(client, app: dict, value: str) -> Step:
    label = "コンテンツの権利"
    current = app["attributes"].get("contentRightsDeclaration")
    if current == value:
        return label, [], None
    return label, [f"    contentRightsDeclaration: {show(current)} → {value}"], lambda: client.patch(
        f"/v1/apps/{app['id']}",
        {"data": {"type": "apps", "id": app["id"], "attributes": {"contentRightsDeclaration": value}}},
    )


def plan_categories(client, app_info: dict, categories: dict[str, str]) -> Step:
    label = "カテゴリ"
    # 書き込む前に、カテゴリの ID が App Store Connect にあるかを確かめる（dry-run でも書き損じに気づけるように）
    unknown = [value for value in dict.fromkeys(categories.values())
               if client.get_or_none(f"/v1/appCategories/{value}") is None]
    if unknown:
        known = sorted(
            entry["id"] for entry in
            client.get_all("/v1/appCategories", {"filter[platforms]": "IOS", "exists[parent]": "false"})
        )
        raise SystemExit(
            f"App Store Connect に無いカテゴリ: {', '.join(unknown)}\n"
            f"使えるカテゴリ: {', '.join(known)}（サブカテゴリは GET /v1/appCategories/<ID>/subcategories で見られる）"
        )

    current = {
        relationship: (client.get_or_none(f"/v1/appInfos/{app_info['id']}/relationships/{relationship}") or {}).get("id")
        for relationship in categories
    }
    changed = {relationship: value for relationship, value in categories.items() if current[relationship] != value}
    if not changed:
        return label, [], None
    lines = [f"    {relationship}: {show(current[relationship])} → {value}" for relationship, value in changed.items()]
    return label, lines, lambda: client.patch(
        f"/v1/appInfos/{app_info['id']}",
        {
            "data": {
                "type": "appInfos",
                "id": app_info["id"],
                "relationships": {
                    relationship: {"data": {"type": "appCategories", "id": value}}
                    for relationship, value in changed.items()
                },
            }
        },
    )


def plan_age_rating(client, app_info: dict, answers: dict) -> Step:
    label = "年齢制限"
    declaration = client.get_or_none(f"/v1/appInfos/{app_info['id']}/ageRatingDeclaration")
    if declaration is None:
        raise SystemExit("App 情報に年齢制限の申告（ageRatingDeclaration）がありません。App Store Connect の画面で状態を確認してください。")
    current = declaration.get("attributes") or {}
    changed = {key: value for key, value in answers.items() if current.get(key) != value}
    if not changed:
        return label, [], None
    return label, describe(current, changed), lambda: client.patch(
        f"/v1/ageRatingDeclarations/{declaration['id']}",
        {"data": {"type": "ageRatingDeclarations", "id": declaration["id"], "attributes": changed}},
    )


def plan_review(client, version: dict, attributes: dict, reminders: list[str]) -> Step:
    label = "App Review に関する情報"
    detail = client.get_or_none(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")
    current = (detail or {}).get("attributes") or {}

    # 審査に出すのに要る値が、JSON・環境変数・App Store Connect のどこにも無ければ知らせる
    if not all(attributes.get(field) or current.get(field) for field in CONTACT_ENV):
        reminders.append("App Review に関する情報の連絡先（氏名・電話番号・メールアドレス）")
    demo_required = attributes.get("demoAccountRequired", current.get("demoAccountRequired"))
    if demo_required and not all(attributes.get(field) or current.get(field) for field in DEMO_ACCOUNT_ENV):
        reminders.append("App Review に関する情報のデモアカウント（ユーザ名・パスワード）")

    changed = {field: value for field, value in attributes.items() if current.get(field) != value}
    if not changed:
        return label, [], None
    lines = describe(current, changed)
    if detail is None:
        return label, lines, lambda: client.post(
            "/v1/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": changed,
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}},
                }
            },
        )
    return label, lines, lambda: client.patch(
        f"/v1/appStoreReviewDetails/{detail['id']}",
        {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": changed}},
    )


def plan_pricing(client, app: dict, pricing: dict) -> Step:
    label = "価格"
    schedule = client.get_or_none(f"/v1/apps/{app['id']}/appPriceSchedule")
    if schedule is not None:
        manual_prices = client.get(f"/v1/appPriceSchedules/{schedule['id']}/manualPrices", {"limit": 1}).get("data")
        if manual_prices:
            return label, ["    設定済みなので触りません（変えるときは App Store Connect の「価格および配信状況」で）"], None

    base = pricing["baseTerritory"]
    points = client.get_all(f"/v1/apps/{app['id']}/appPricePoints", {"filter[territory]": base})
    free = [point for point in points if _is_zero(point["attributes"].get("customerPrice"))]
    if not free:
        raise SystemExit(f"{base} の価格ポイントに無料（0）がありません。App Store Connect の画面で価格を設定してください。")
    return label, [f"    （未設定） → 無料（基準の国と地域: {base}）"], lambda: client.post(
        "/v1/appPriceSchedules",
        {
            "data": {
                "type": "appPriceSchedules",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app["id"]}},
                    "baseTerritory": {"data": {"type": "territories", "id": base}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]},
                },
            },
            "included": [
                {
                    "type": "appPrices",
                    "id": "${free}",
                    "attributes": {"startDate": None},
                    "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free[0]["id"]}}},
                }
            ],
        },
    )


def _is_zero(price) -> bool:
    try:
        return float(price) == 0
    except (TypeError, ValueError):
        return False


def plan_availability(client, app: dict, availability: dict, reminders: list[str]) -> Step:
    label = "配信状況"
    current = client.get_or_none(f"/v1/apps/{app['id']}/appAvailabilityV2")
    if current is not None:
        entries = client.get_all(f"/v2/appAvailabilities/{current['id']}/territoryAvailabilities")
        count = sum(1 for entry in entries if (entry.get("attributes") or {}).get("available"))
        if count == 0:
            reminders.append("価格および配信状況の、配信する国と地域（1 つも選ばれていません）")
        return label, [f"    設定済みなので触りません（{count} の国と地域で配信。変えるときは App Store Connect で）"], None

    territories = [entry["id"] for entry in client.get_all("/v1/territories")]
    selected = territories if availability["territories"] == "ALL" else availability["territories"]
    unknown = sorted(set(selected) - set(territories))
    if unknown:
        raise SystemExit(f"App Store Connect に無い国と地域のコード: {', '.join(unknown)}")
    new_territories = "はい" if availability["availableInNewTerritories"] else "いいえ"
    lines = [f"    （未設定） → {len(selected)} の国と地域で配信（新しい国と地域にも自動で配信: {new_territories}）"]

    # 配信しない国と地域も available: false で明示し、すべての国と地域の扱いを 1 回で決める
    return label, lines, lambda: client.post(
        "/v2/appAvailabilities",
        {
            "data": {
                "type": "appAvailabilities",
                "attributes": {"availableInNewTerritories": availability["availableInNewTerritories"]},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app["id"]}},
                    "territoryAvailabilities": {
                        "data": [{"type": "territoryAvailabilities", "id": f"${{{code}}}"} for code in territories]
                    },
                },
            },
            "included": [
                {
                    "type": "territoryAvailabilities",
                    "id": f"${{{code}}}",
                    "attributes": {"available": code in selected},
                    "relationships": {"territory": {"data": {"type": "territories", "id": code}}},
                }
                for code in territories
            ],
        },
    )


# MARK: - main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH, help="読む JSON（既定は AppStore/app_info.json）")
    parser.add_argument("--bundle-id", help="省略すると project.pbxproj から読む")
    parser.add_argument("--app-version", help="App Review に関する情報の反映先のバージョン。省略すると編集できるバージョンを自動で選ぶ")
    parser.add_argument("--key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument(
        "--private-key",
        type=Path,
        default=os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY_PATH"),
        help="App Store Connect API Key の .p8",
    )
    parser.add_argument("--check", action="store_true", help="App Store Connect につながず、手元のファイルだけ検査する")
    parser.add_argument("--dry-run", action="store_true", help="何も書き換えず、現在値との差分だけ出す")
    args = parser.parse_args()

    config, problems = load(args.config)
    if problems:
        raise SystemExit("\n".join(problems))

    found = config["placeholders"]
    if found and not args.check:
        raise SystemExit(f"テンプレートの仮の値（TODO:）が残っています: {', '.join(found)}")

    if args.check:
        if found:
            print(f"注意: テンプレートの仮の値（TODO:）が残っています: {', '.join(found)}")
        print(f"  カテゴリ: {', '.join(f'{key} {value}' for key, value in config['categories'].items())}")
        print(f"  コンテンツの権利: {config['contentRights']}")
        print(f"  年齢制限: {len(config['ageRating'])} 項目")
        print(f"  審査の情報: {', '.join(config['review']) or 'なし'}（連絡先は環境変数から）")
        print(f"  価格: {'無料（未設定のときだけ）' if config['pricing'] else '書き込まない'}")
        print(f"  配信状況: {'未設定のときだけ' if config['availability'] else '書き込まない'}")
        print("問題なし")
        return 0

    review, notices = review_from_environment(config["review"])

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
    app_info = client.find_app_info(app["id"])
    print(f"対象: {app['attributes']['name']} {version['attributes']['versionString']} "
          f"({version['attributes']['appStoreState']})")
    if args.dry_run:
        print("--dry-run: App Store Connect には何も書き込みません")
    for notice in notices:
        print(f"  注意: {notice}")

    # 書き込む前にすべての書き込み先の現在値を読み、カテゴリの ID や無料の価格ポイントがあるかを確かめる。
    # 途中で止まって一部だけ書き換わった状態にしないため
    reminders: list[str] = []
    steps: list[Step] = [
        plan_content_rights(client, app, config["contentRights"]),
        plan_categories(client, app_info, config["categories"]),
        plan_age_rating(client, app_info, config["ageRating"]),
        plan_review(client, version, review, reminders),
    ]
    if config["pricing"]:
        steps.append(plan_pricing(client, app, config["pricing"]))
    if config["availability"]:
        steps.append(plan_availability(client, app, config["availability"], reminders))

    for label, lines, write in steps:
        if write is None:
            print(f"  {label}: {'変更なし' if not lines else ''}".rstrip())
        else:
            print(f"  {label}: {'書き込む予定' if args.dry_run else '書き込み'}")
        for line in lines:
            print(line)
        if write is not None and not args.dry_run:
            write()

    print("完了")
    # ワークフローで反映できないもの（README の「審査に出す前に App Store Connect で手入力するもの」）。
    # アプリの作成は、済んでいなければ find_app で先に止まるので載せない
    reminders.extend([
        "App のプライバシー（収集するデータの申告。API が無いので、いつも App Store Connect で入力する）",
        "ビルドの選択と審査への提出",
        "デジタルサービス法（EU）の取引業者の情報（アカウントで一度だけ。登録済みなら不要）",
    ])
    print("審査に出す前に App Store Connect で入力が要るもの:")
    for reminder in reminders:
        print(f"  - {reminder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
