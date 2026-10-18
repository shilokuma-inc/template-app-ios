#!/usr/bin/env python3
"""撮った表示サイズのスクリーンショットを縮めて、別の表示サイズのものを作る（macOS が要らない）。

`AppStore/screenshots.json` で `deriveFrom` を書いた表示サイズが対象。たとえば iPhone 6.3 inch
（1206x2622）は 6.9 inch（1320x2868）と縦横比がほぼ同じ（差は 0.1% 未満）なので、Simulator で撮り直さず
縮めて作る。GitHub Actions の macOS ランナーを 1 本ぶん使わずに済む。

    python3 Tools/derive_screenshots.py --display-type APP_IPHONE_61 \\
        --screenshots-dir build/screenshots

`<screenshots-dir>/<deriveFrom>/<言語>/*.png` を読み、`<screenshots-dir>/<display-type>/<言語>/` に
同じファイル名で書く。寸法は screenshots.json の sizes の先頭に合わせ、アルファは落とす。
縦横比が 1% 以上違うときは、縮めると歪んで見えるので止める（その表示サイズは Simulator で撮る）。

Pillow が要る: `python3 -m pip install pillow`
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import display_type, languages, parse_list

try:
    from PIL import Image
except ImportError:  # pragma: no cover - 実行環境の問題なので案内だけ出す
    raise SystemExit("Pillow が入っていません。`python3 -m pip install pillow` を実行してください。")

#: 縮めて作ってよい縦横比の差の上限
MAX_ASPECT_DIFFERENCE = 0.01


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--display-type", required=True, help="作る表示サイズ（例: APP_IPHONE_61）")
    parser.add_argument("--screenshots-dir", type=Path, default=Path("build/screenshots"))
    parser.add_argument("--languages", help="対象の言語（カンマ区切り）。省略すると全言語")
    args = parser.parse_args()

    entry = display_type(args.display_type)
    source_type = entry.get("deriveFrom")
    if not source_type:
        raise SystemExit(f"{args.display_type} には deriveFrom がありません（Simulator で撮る表示サイズです）")
    width, height = (int(value) for value in entry["sizes"][0].split("x"))

    total = 0
    for language in languages(parse_list(args.languages)):
        source_dir = args.screenshots_dir / source_type / language.language
        images = sorted(source_dir.glob("*.png"))
        if not images:
            raise SystemExit(f"{source_dir} にスクリーンショットがありません（先に {source_type} を撮る）")
        destination = args.screenshots_dir / args.display_type / language.language
        shutil.rmtree(destination, ignore_errors=True)
        destination.mkdir(parents=True)

        for path in images:
            with Image.open(path) as image:
                difference = abs(image.width / image.height - width / height) / (width / height)
                if difference > MAX_ASPECT_DIFFERENCE:
                    raise SystemExit(
                        f"{path} は {image.width}x{image.height} で、{width}x{height} と縦横比が "
                        f"{difference:.1%} 違います。{args.display_type} は Simulator で撮ってください"
                    )
                # App Store Connect はアルファ付きの PNG を受け付けない
                image.convert("RGB").resize((width, height), Image.Resampling.LANCZOS).save(destination / path.name)
            total += 1
        print(f"  {language.language}: {len(images)} 枚（{source_type} → {args.display_type} {width}x{height}）")

    print(f"完了: {total} 枚")
    return 0


if __name__ == "__main__":
    sys.exit(main())
