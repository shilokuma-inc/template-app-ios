// Simulator のスクリーンショット（RGBA の PNG）を、アルファの無い RGB の PNG に描き直す。
// App Store Connect はアルファ付きの画像を受け付けないため。sips ではアルファを落とせない。
//
//   swiftc -O Tools/remove_alpha.swift -o remove_alpha && ./remove_alpha a.png b.png …
//
// 上書きで保存する。画面全体が不透明なので、アルファを捨てても見た目は変わらない。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else {
        FileHandle.standardError.write(Data("\(path) を読めませんでした\n".utf8))
        exit(1)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flattened = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("\(path) を描き直せませんでした\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("\(path) を保存できませんでした\n".utf8))
        exit(1)
    }
}
