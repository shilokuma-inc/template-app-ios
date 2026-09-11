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
        case .added(let record): tr("Added \(record.name)")
        case .duplicate(let record): tr("\(record.name) was already scanned")
        case .invalid: tr("Could not read a user name")
        }
    }
}

/// 他端末データの統合結果
struct MergeResult: Equatable, Sendable {
    /// 新たに追加された履歴の件数
    let added: Int
    /// 追加により増えた重複なしユーザーの数
    let uniqueAdded: Int
    /// 既に取り込み済みのためスキップした件数
    let skipped: Int

    var message: String {
        tr("Merged \(added) records (\(uniqueAdded) new users, \(skipped) skipped)")
    }
}

/// 全読み取り履歴を保持し、重複なしリストを提供する
@MainActor
@Observable
final class ScanStore {
    /// 読み取った順の全履歴 (重複を含む)
    private(set) var records: [ScanRecord] = []
    /// 一覧・集計・出力に適用する期間フィルター (永続化しない)
    var filter = DateFilter()

    private let fileURL: URL?
    private let legacyDefaults: UserDefaults?
    private static let legacyStorageKey = "scanRecords"

    /// - Parameters:
    ///   - fileURL: 保存先。`nil` を渡すと永続化しない (テスト・Preview 用)
    ///   - legacyDefaults: 旧バージョンが UserDefaults に保存したデータの移行元
    init(fileURL: URL? = ScanStore.defaultFileURL, legacyDefaults: UserDefaults? = .standard) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        load()
    }

    static func inMemory() -> ScanStore {
        ScanStore(fileURL: nil, legacyDefaults: nil)
    }

    /// Application Support 配下の保存先 (iCloud バックアップ対象、アプリ削除まで残る)
    nonisolated static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("ScanData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("records.json")
    }

    // MARK: - Derived

    /// 初回に読み取った順の重複なしリスト (全期間)
    var uniqueRecords: [ScanRecord] { records.uniqueByName }
    var totalCount: Int { records.count }
    var uniqueCount: Int { uniqueRecords.count }

    /// 期間フィルター適用後の履歴
    var filteredRecords: [ScanRecord] { filter.apply(records) }
    var filteredUniqueRecords: [ScanRecord] { filteredRecords.uniqueByName }
    var filteredTotalCount: Int { filteredRecords.count }
    var filteredUniqueCount: Int { filteredUniqueRecords.count }

    // MARK: - Mutations

    @discardableResult
    func add(rawValue: String, source: ScanSource, deviceName: String? = nil, at date: Date = .now) -> ScanAddResult {
        guard let name = ForteeUserParser.userName(from: rawValue) else {
            return .invalid(rawValue)
        }
        let record = ScanRecord(name: name, url: rawValue, source: source, scannedAt: date, deviceName: deviceName)
        let isDuplicate = records.contains { $0.dedupeKey == record.dedupeKey }
        records.append(record)
        save()
        return isDuplicate ? .duplicate(record) : .added(record)
    }

    /// 他端末の履歴を統合する。同じ ID のレコードはスキップし、読み取り時刻順に並べ直す
    @discardableResult
    func merge(_ incoming: [ScanRecord]) -> MergeResult {
        let existingIDs = Set(records.map(\.id))
        let newRecords = incoming.filter { !existingIDs.contains($0.id) }
        let uniqueBefore = uniqueCount
        records.append(contentsOf: newRecords)
        records.sort { $0.scannedAt < $1.scannedAt }
        save()
        return MergeResult(
            added: newRecords.count,
            uniqueAdded: uniqueCount - uniqueBefore,
            skipped: incoming.count - newRecords.count
        )
    }

    func remove(_ record: ScanRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func removeAll() {
        records.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            records = (try? ScanJSON.makeDecoder().decode([ScanRecord].self, from: data)) ?? []
            return
        }
        migrateFromLegacyStorage()
    }

    /// 旧バージョン (UserDefaults 保存) のデータをファイルへ移す
    private func migrateFromLegacyStorage() {
        guard let legacyDefaults,
              let data = legacyDefaults.data(forKey: Self.legacyStorageKey),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else {
            return
        }
        records = decoded
        save()
        legacyDefaults.removeObject(forKey: Self.legacyStorageKey)
    }

    private func save() {
        guard let fileURL, let data = try? ScanJSON.makeEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
