// Simulator のスクリーンショットに、--mask=alpha で撮った画像の Dynamic Island を重ねて、アルファの無い RGB の PNG にする。
//
//   swiftc -O Tools/overlay_screenshot.swift -o overlay_screenshot
//   ./overlay_screenshot <下の画像> <上の画像> <出力>
//
// 下の画像（マスク無しの simctl io screenshot）の上に、上の画像（--mask=alpha）の「上端の中央」だけを重ねる
// （capture_screenshots.sh の Dynamic Island のコメント）。--mask=alpha の画像は Dynamic Island が不透明の黒で写る。
// 重ねるのを上端の中央に限るのは、画面の四隅（透明に写る）や、iPhone Duo の外側の画面のカメラの穴（右上に黒く写る）のように、
// CI の画像にも写らない切り欠きまで足さないため。
// 下の画像と色が違う画素の数を標準出力に出す（0 なら、重ねても何も変わらない機種か、もともと写っている CI）。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("\(path) を読めませんでした")
    }
    return image
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("使い方: overlay_screenshot <下の画像> <上の画像> <出力>")
}
let under = loadImage(arguments[1])
let over = loadImage(arguments[2])
guard under.width == over.width, under.height == over.height else {
    fail("\(arguments[1])（\(under.width)x\(under.height)）と \(arguments[2])（\(over.width)x\(over.height)）の寸法が違います")
}

let rect = CGRect(x: 0, y: 0, width: under.width, height: under.height)
// Dynamic Island のある範囲: 横は中央の半分、縦は上端の 10%（6.9 inch では x 472〜847・y 42〜151 に写る）。
// CGContext は左下が原点なので、上端は rect の上側になる
let islandArea = CGRect(
    x: rect.width * 0.25,
    y: rect.height * 0.9,
    width: rect.width * 0.5,
    height: rect.height * 0.1
)
guard let context = CGContext(
    data: nil,
    width: under.width,
    height: under.height,
    bitsPerComponent: 8,
    bytesPerRow: under.width * 4,
    space: under.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
), let pixels = context.data else {
    fail("描くための領域を作れませんでした")
}
let byteCount = under.width * under.height * 4
context.draw(under, in: rect)
let underPixels = Data(bytes: pixels, count: byteCount)
context.saveGState()
context.clip(to: islandArea)
context.draw(over, in: rect)
context.restoreGState()

var changed = 0
underPixels.withUnsafeBytes { (before: UnsafeRawBufferPointer) in
    let after = pixels.assumingMemoryBound(to: UInt8.self)
    for offset in stride(from: 0, to: byteCount, by: 4)
    where before[offset] != after[offset] || before[offset + 1] != after[offset + 1] || before[offset + 2] != after[offset + 2] {
        changed += 1
    }
}

guard let merged = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: arguments[3]) as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fail("\(arguments[3]) に書き出せませんでした")
}
CGImageDestinationAddImage(destination, merged, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("\(arguments[3]) を保存できませんでした")
}
print(changed)
