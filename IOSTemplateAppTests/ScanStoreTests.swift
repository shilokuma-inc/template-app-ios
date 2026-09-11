//
//  ScanStoreTests.swift
//  IOSTemplateAppTests
//

import Testing
@testable import IOSTemplateApp

@MainActor
struct ScanStoreTests {
    @Test("同じユーザーは履歴には残るが重複なしリストには 1 件だけ")
    func deduplicates() {
        let store = ScanStore(userDefaults: nil)

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
        let store = ScanStore(userDefaults: nil)
        let result = store.add(rawValue: "not a url", source: .manual)
        #expect(result == .invalid("not a url"))
        #expect(store.records.isEmpty)
    }

    @Test("削除すると重複なしリストから次の同名レコードが繰り上がる")
    func removePromotesNextRecord() {
        let store = ScanStore(userDefaults: nil)
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode)
        store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .nfc)

        store.remove(store.uniqueRecords[0])

        #expect(store.totalCount == 1)
        #expect(store.uniqueRecords.first?.source == .nfc)
    }
}
