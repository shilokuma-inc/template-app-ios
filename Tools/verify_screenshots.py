#!/usr/bin/env python3
"""撮ったスクリーンショットが App Store Connect に通る形か確かめる。

App Store Connect は寸法が 1 px でも違えば弾き、アルファ付きの PNG も受け付けない。
アップロードまで進んでから落ちると原因が遠くなるので、撮った時点で落とす。

    python3 Tools/verify_screenshots.py \\
        --directory build/screenshots/APP_IPHONE_67 \\
        --sizes 1320x2868,1290x2796

`<directory>/<言語>/*.png` をすべて見る。枚数が `AppStore/screenshots.json` の scenes と
揃っているかも確かめる（途中の画面だけ撮れていない、に気づくため）。
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_config import scenes

#: PNG の色タイプ。2 = RGB（アルファ無し）、6 = RGBA
PNG_COLOR_TYPE_RGB = 2


#: PNG の色タイプごとのチャンネル数
PNG_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def read_png_header(path: Path) -> tuple[int, int, int]:
    """PNG の幅・高さ・色タイプを IHDR から読む。

    ヘッダーだけ見ると、途中で切れた画像も通ってしまう。チャンクを最後（IEND）まで
    たどって CRC を確かめ、画像データも展開して、行数ぶんのデータがそろっているかまで見る。
    """
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("PNG ではありません")

    header: tuple[int, int, int, int, int] | None = None
    image_data = bytearray()
    offset = 8
    while True:
        if offset + 8 > len(raw):
            raise ValueError("PNG が途中で切れています（IEND がありません）")
        length, kind = struct.unpack(">I4s", raw[offset:offset + 8])
        body = raw[offset + 8:offset + 8 + length]
        crc = raw[offset + 8 + length:offset + 12 + length]
        if len(body) != length or len(crc) != 4:
            raise ValueError(f"PNG が途中で切れています（{kind.decode(errors='replace')} チャンク）")
        if struct.unpack(">I", crc)[0] != zlib.crc32(kind + body):
            raise ValueError(f"PNG の {kind.decode(errors='replace')} チャンクが壊れています（CRC 不一致）")
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, color_type, _compression, _filter, interlace = struct.unpack(">IIBBBBB", body)
            header = (width, height, depth, color_type, interlace)
        elif kind == b"IDAT":
            image_data += body
        elif kind == b"IEND":
            break

    if header is None:
        raise ValueError("PNG に IHDR がありません")
    width, height, depth, color_type, interlace = header
    if color_type not in PNG_CHANNELS:
        raise ValueError(f"PNG の色タイプ {color_type} は不正です")

    decompressor = zlib.decompressobj()
    try:
        pixels = decompressor.decompress(bytes(image_data))
    except zlib.error as error:
        raise ValueError(f"PNG の画像データを展開できません: {error}") from None
    if not decompressor.eof:
        raise ValueError("PNG の画像データが途中で切れています")
    # インターレースは行の並びが変わるので、長さの突き合わせはしない（Simulator の画像は非インターレース）
    if interlace == 0:
        row_bytes = 1 + (width * PNG_CHANNELS[color_type] * depth + 7) // 8
        if len(pixels) != row_bytes * height:
            raise ValueError(f"PNG の画像データの長さが {width}x{height} と合いません")
    return width, height, color_type


def parse_sizes(raw: str) -> set[tuple[int, int]]:
    sizes = set()
    for item in raw.split(","):
        width, height = item.strip().lower().split("x")
        sizes.add((int(width), int(height)))
    return sizes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--directory", type=Path, required=True, help="<ここ>/<言語>/*.png を見る")
    parser.add_argument("--sizes", required=True, help="受け付ける寸法（カンマ区切り。例: 1320x2868,1290x2796）")
    args = parser.parse_args()

    accepted = parse_sizes(args.sizes)
    expected_files = [f"{scene.file}.png" for scene in scenes()]

    problems: list[str] = []
    languages = sorted(p for p in args.directory.iterdir() if p.is_dir()) if args.directory.is_dir() else []
    if not languages:
        problems.append(f"{args.directory} にスクリーンショットがありません")

    for language_dir in languages:
        files = sorted(p.name for p in language_dir.glob("*.png"))
        missing = [name for name in expected_files if name not in files]
        if missing:
            problems.append(f"{language_dir.name}: 撮れていない画面があります: {', '.join(missing)}")
        # 設定に無い画像もアップロードの対象になってしまうので、多すぎる場合も止める
        unexpected = [name for name in files if name not in expected_files]
        if unexpected:
            problems.append(f"{language_dir.name}: 設定に無い画面があります: {', '.join(unexpected)}")
        for name in files:
            path = language_dir / name
            try:
                width, height, color_type = read_png_header(path)
            except ValueError as error:
                problems.append(f"{language_dir.name}/{name}: {error}")
                continue
            print(f"{language_dir.name}/{name}  {width}x{height}")
            if (width, height) not in accepted:
                problems.append(
                    f"{language_dir.name}/{name}: {width}x{height} は受け付けられない寸法です"
                    f"（{args.sizes}）。撮影に使った Simulator の機種が想定と違う可能性があります。"
                )
            if color_type != PNG_COLOR_TYPE_RGB:
                problems.append(
                    f"{language_dir.name}/{name}: PNG の色タイプが {color_type} です。"
                    "App Store Connect はアルファ付きの画像を受け付けません。"
                )

    if problems:
        raise SystemExit("\n".join(problems))
    print(f"問題なし: {len(languages)} 言語 × {len(expected_files)} 枚")
    return 0


if __name__ == "__main__":
    sys.exit(main())
