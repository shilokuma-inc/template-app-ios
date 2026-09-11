//
//  ScanStore.swift
//  IOSTemplateApp
//

import Foundation
import Observation

/// 読み取り結果の追加結果
enum ScanAddResult: Equatable {
    /// 新しいユーザーとして追加された
    case added(ScanRecord)
    /// 既に読み取り済みのユーザー (履歴には残す)
    case duplicate(ScanRecord)
    /// ユーザー名を抽出できなかった
    case invalid(String)

    var message: String {
        switch self {
        case .added(let record): "\(record.name) を追加しました"
        case .duplicate(let record): "\(record.name) は既に読み取り済みです"
        case .invalid: "ユーザー名を読み取れませんでした"
        }
    }
}

/// 全読み取り履歴を保持し、重複なしリストを提供する
@MainActor
@Observable
final class ScanStore {
    /// 読み取った順の全履歴 (重複を含む)
    private(set) var records: [ScanRecord] = []

    private let userDefaults: UserDefaults?
    private static let storageKey = "scanRecords"

    /// - Parameter userDefaults: `nil` を渡すと永続化しない (テスト・Preview 用)
    init(userDefaults: UserDefaults? = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    /// 初回に読み取った順の重複なしリスト
    var uniqueRecords: [ScanRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.dedupeKey).inserted }
    }

    var totalCount: Int { records.count }
    var uniqueCount: Int { uniqueRecords.count }

    @discardableResult
    func add(rawValue: String, source: ScanSource, at date: Date = .now) -> ScanAddResult {
        guard let name = ForteeUserParser.userName(from: rawValue) else {
            return .invalid(rawValue)
        }
        let record = ScanRecord(name: name, url: rawValue, source: source, scannedAt: date)
        let isDuplicate = records.contains { $0.dedupeKey == record.dedupeKey }
        records.append(record)
        save()
        return isDuplicate ? .duplicate(record) : .added(record)
    }

    func remove(_ record: ScanRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func removeAll() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = userDefaults?.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        guard let userDefaults, let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
