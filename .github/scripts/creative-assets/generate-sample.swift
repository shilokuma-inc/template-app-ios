//
// App Store のクリエイティブアセット（プロダクトページのヘッダー / 検索結果）の試験用画像を生成する。
// アプリアイコンとアプリ名をグラデーション背景の中央に置く（端がクロップされても崩れにくい構成）。
//
// 使い方:
//   swift .github/scripts/creative-assets/generate-sample.swift <出力ディレクトリ> <アイコン PNG> <タイトル> <サブタイトル>
//
// 出力（いずれもアルファチャンネルなしの PNG）:
//   header_21x9_3840x1646.png      プロダクトページのヘッダー（21:9）
//   search_3x2_3840x2560.png       検索結果（3:2）
//   universal_16x9_5244x2950.png   ヘッダーと検索結果の兼用（16:9）
//
// 仕様: https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    FileHandle.standardError.write(Data("使い方: generate-sample.swift <出力ディレクトリ> <アイコン PNG> <タイトル> <サブタイトル>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard let icon = NSImage(contentsOfFile: arguments[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("アイコンを読み込めません: \(arguments[2])\n".utf8))
    exit(1)
}
let title = arguments[3] as NSString
let subtitle = arguments[4] as NSString

/// 背景のグラデーションと装飾の円を描く
func drawBackground(in context: CGContext, colorSpace: CGColorSpace, size: CGSize) {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.10, green: 0.18, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.35, green: 0.20, blue: 0.70, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 1)
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
    for (x, y, radius) in [(0.85, 0.8, 0.35), (0.1, 0.1, 0.25), (0.65, 0.15, 0.15)] {
        let circleRadius = CGFloat(radius) * size.height
        context.fillEllipse(
            in: CGRect(
                x: CGFloat(x) * size.width - circleRadius,
                y: CGFloat(y) * size.height - circleRadius,
                width: circleRadius * 2,
                height: circleRadius * 2
            )
        )
    }
}

/// アイコン（角丸 + 影）とタイトル / サブタイトルを横並びで中央に描く
func drawContent(in context: CGContext, size: CGSize) {
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size.height * 0.11, weight: .heavy),
        .foregroundColor: NSColor.white
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size.height * 0.045, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85)
    ]
    let titleSize = title.size(withAttributes: titleAttributes)
    let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
    let iconSize = size.height * 0.36
    let gap = size.height * 0.06
    let contentWidth = iconSize + gap + max(titleSize.width, subtitleSize.width)

    let iconRect = CGRect(x: (size.width - contentWidth) / 2, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize)
    let iconPath = CGPath(roundedRect: iconRect, cornerWidth: iconSize * 0.2237, cornerHeight: iconSize * 0.2237, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size.height * 0.01), blur: size.height * 0.04, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(iconPath)
    context.setFillColor(.white)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    context.draw(icon, in: iconRect)
    context.restoreGState()

    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let textX = iconRect.maxX + gap
    let textY = (size.height - titleSize.height - subtitleSize.height) / 2
    title.draw(at: CGPoint(x: textX, y: textY + subtitleSize.height), withAttributes: titleAttributes)
    subtitle.draw(at: CGPoint(x: textX, y: textY), withAttributes: subtitleAttributes)
    NSGraphicsContext.current = nil
}

func render(fileName: String, width: Int, height: Int) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // App Store はアルファチャンネル付きの画像を受け付けないため noneSkipLast で描く
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let size = CGSize(width: width, height: height)
    drawBackground(in: context, colorSpace: colorSpace, size: size)
    drawContent(in: context, size: size)

    let url = outputDirectory.appendingPathComponent(fileName)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print("生成しました: \(url.path)（\(width)x\(height)）")
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try render(fileName: "header_21x9_3840x1646.png", width: 3840, height: 1646)
try render(fileName: "search_3x2_3840x2560.png", width: 3840, height: 2560)
try render(fileName: "universal_16x9_5244x2950.png", width: 5244, height: 2950)
