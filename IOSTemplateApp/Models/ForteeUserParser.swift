//
//  ForteeUserParser.swift
//  IOSTemplateApp
//

import Foundation

/// `https://fortee.jp/u/Shilokuma` のような URL からユーザー名部分を取り出す
enum ForteeUserParser {
    /// URL 文字列からユーザー名を抽出する。
    ///
    /// - `/u/<name>` 形式ならその `<name>` を返す
    /// - それ以外の URL は末尾のパス要素をフォールバックとして返す
    /// - URL として解釈できない、または名前が空なら `nil`
    static func userName(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.host != nil else {
            return nil
        }

        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }

        if let index = segments.firstIndex(of: "u") {
            guard segments.indices.contains(index + 1) else { return nil }
            return normalized(segments[index + 1])
        }
        guard let last = segments.last else { return nil }
        return normalized(last)
    }

    private static func normalized(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
