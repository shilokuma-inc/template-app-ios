//
//  ScanRecord.swift
//  IOSTemplateApp
//

import Foundation

/// 1 回の読み取り結果
struct ScanRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// URL から抽出したユーザー名 (例: `Shilokuma`)
    let name: String
    /// 読み取った元の文字列 (`.../attendee/<token>/go-profile` のような URL のこともある)
    let url: String
    /// リダイレクトを解決した後のプロフィール URL (例: `https://fortee.jp/u/Shilokuma`)
    let profileURL: String?
    let source: ScanSource
    let scannedAt: Date
    /// 読み取った端末の名前 (複数端末のデータを統合したときの識別用)
    let deviceName: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        profileURL: String? = nil,
        source: ScanSource,
        scannedAt: Date = .now,
        deviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.profileURL = profileURL
        self.source = source
        self.scannedAt = scannedAt
        self.deviceName = deviceName
    }

    /// 重複判定に使うキー。大文字小文字の違いは同一ユーザーとみなす
    var dedupeKey: String {
        name.lowercased()
    }

    /// 出力に使う URL。解決済みのプロフィール URL があればそちらを優先する
    var displayURL: String {
        profileURL ?? url
    }
}

extension Array where Element == ScanRecord {
    /// 初回に読み取った順の重複なしリスト
    var uniqueByName: [ScanRecord] {
        var seen = Set<String>()
        return filter { seen.insert($0.dedupeKey).inserted }
    }
}
