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
    /// 読み取った元の文字列
    let url: String
    let source: ScanSource
    let scannedAt: Date
    /// 読み取った端末の名前 (複数端末のデータを統合したときの識別用)
    let deviceName: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        source: ScanSource,
        scannedAt: Date = .now,
        deviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.source = source
        self.scannedAt = scannedAt
        self.deviceName = deviceName
    }

    /// 重複判定に使うキー。大文字小文字の違いは同一ユーザーとみなす
    var dedupeKey: String {
        name.lowercased()
    }
}

extension Array where Element == ScanRecord {
    /// 初回に読み取った順の重複なしリスト
    var uniqueByName: [ScanRecord] {
        var seen = Set<String>()
        return filter { seen.insert($0.dedupeKey).inserted }
    }
}
