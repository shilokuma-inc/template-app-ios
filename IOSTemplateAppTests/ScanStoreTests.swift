//
//  ScanStoreTests.swift
//  IOSTemplateAppTests
//

import Foundation
import Testing
@testable import IOSTemplateApp

@MainActor
struct ScanStoreTests {
    @Test("同じユーザーは履歴には残るが重複なしリストには 1 件だけ")
    func deduplicates() {
        let store = ScanStore.inMemory()

        let first = store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode)
        let second = store.add(rawValue: "https://fortee.jp/u/shilokuma", source: .nfc)
        let third = store.add(rawValue: "https://fortee.jp/u/Hoge", source: .qrCode)

        guard case .added = first, case .duplicate = second, case .added = third else {
            Issue.record("追加結果が想定と異なる: \(first), \(second), \(third)")
            return
        }
        #expect(store.totalCount == 3)
        #expect(store.uniqueCount == 2)
        #expect(store.uniqueRecords.map(\.name) == ["Shilokuma", "Hoge"])
    }

    @Test("解釈できない文字列は履歴に追加しない")
    func rejectsInvalid() {
        let store = ScanStore.inMemory()
        let result = store.add(rawValue: "not a url", source: .manual)
        #expect(result == .invalid("not a url"))
        #expect(store.records.isEmpty)
    }

    @Test("削除すると重複なしリストから次の同名レコードが繰り上がる")
    func removePromotesNextRecord() {
        let store = ScanStore.inMemory()
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode)
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .nfc)

        store.remove(store.uniqueRecords[0])

        #expect(store.totalCount == 1)
        #expect(store.uniqueRecords.first?.source == .nfc)
    }

    @Test("端末名を履歴に記録する")
    func recordsDeviceName() {
        let store = ScanStore.inMemory()
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode, deviceName: "iPhone A")
        #expect(store.records.first?.deviceName == "iPhone A")
    }

    @Test("統合は同じ ID をスキップし、時刻順に並べ直す")
    func mergeSkipsKnownIDsAndSorts() {
        let store = ScanStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_757_635_200)
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode, at: base.addingTimeInterval(120))

        let alreadyKnown = store.records[0]
        let incoming = [
            alreadyKnown,
            ScanRecord(name: "Hoge", url: "https://fortee.jp/u/Hoge", source: .nfc, scannedAt: base, deviceName: "iPhone B"),
            ScanRecord(name: "shilokuma", url: "https://fortee.jp/u/shilokuma", source: .nfc, scannedAt: base.addingTimeInterval(60))
        ]

        let result = store.merge(incoming)

        #expect(result == MergeResult(added: 2, uniqueAdded: 1, skipped: 1))
        #expect(store.records.map(\.name) == ["Hoge", "shilokuma", "Shilokuma"])
        #expect(store.uniqueCount == 2)
    }

    @Test("期間フィルターは一覧と件数に反映される")
    func filterAppliesToDerivedValues() {
        let store = ScanStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_757_635_200)
        store.add(rawValue: "https://fortee.jp/u/A", source: .qrCode, at: base)
        store.add(rawValue: "https://fortee.jp/u/B", source: .qrCode, at: base.addingTimeInterval(3600))
        store.add(rawValue: "https://fortee.jp/u/A", source: .qrCode, at: base.addingTimeInterval(7200))

        store.filter = DateFilter(isEnabled: true, start: base.addingTimeInterval(1800), end: base.addingTimeInterval(9000))

        #expect(store.filteredTotalCount == 2)
        #expect(store.filteredUniqueCount == 2)
        #expect(store.filteredUniqueRecords.map(\.name) == ["B", "A"])
        #expect(store.totalCount == 3)
    }

    @Test("ファイルに保存し、再生成しても読み戻せる")
    func persistsToFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScanStore(fileURL: url, legacyDefaults: nil)
        // ミリ秒までしか保存しないため、比較しやすいよう秒単位の時刻で追加する
        let scannedAt = Date(timeIntervalSince1970: 1_757_635_200.5)
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode, deviceName: "iPhone A", at: scannedAt)

        let reloaded = ScanStore(fileURL: url, legacyDefaults: nil)
        #expect(reloaded.records == store.records)
    }

    @Test("旧バージョンの UserDefaults 保存データをファイルへ移行する")
    func migratesLegacyUserDefaults() throws {
        let suiteName = "ScanStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = [ScanRecord(name: "Hoge", url: "https://fortee.jp/u/Hoge", source: .qrCode)]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "scanRecords")

        let store = ScanStore(fileURL: url, legacyDefaults: defaults)

        #expect(store.records.map(\.name) == ["Hoge"])
        #expect(defaults.data(forKey: "scanRecords") == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
