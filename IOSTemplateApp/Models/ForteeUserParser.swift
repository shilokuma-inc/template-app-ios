//
//  ForteeUserParser.swift
//  IOSTemplateApp
//

import Foundation

/// fortee の URL からユーザー名や参加者トークンを取り出す
enum ForteeUserParser {
    /// `https://fortee.jp/u/Shilokuma` のようなプロフィール URL からユーザー名を抽出する。
    ///
    /// - `/u/<name>` 形式ならその `<name>` を返す
    /// - それ以外 (`.../attendee/<token>/go-profile` など) は `nil`。
    ///   リダイレクト先を追う必要があるので `ForteeProfileResolver` を使う
    static func userName(from rawValue: String) -> String? {
        guard let segments = pathSegments(of: rawValue),
              let index = segments.firstIndex(of: "u"),
              segments.indices.contains(index + 1) else {
            return nil
        }
        return normalized(segments[index + 1])
    }

    /// `https://fortee.jp/<event>/attendee/<token>/go-profile` から参加者トークンを抽出する。
    /// ネットワークに繋がらずユーザー名を解決できないときの比較キーとして使う
    static func attendeeToken(from rawValue: String) -> String? {
        guard let segments = pathSegments(of: rawValue),
              let index = segments.firstIndex(of: "attendee"),
              segments.indices.contains(index + 1) else {
            return nil
        }
        return normalized(segments[index + 1])
    }

    /// URL として解釈でき、ホストを持つか
    static func isURL(_ rawValue: String) -> Bool {
        url(from: rawValue) != nil
    }

    static func url(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.host != nil else {
            return nil
        }
        return components.url
    }

    private static func pathSegments(of rawValue: String) -> [String]? {
        guard let url = url(from: rawValue) else { return nil }
        return url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
    }

    private static func normalized(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
