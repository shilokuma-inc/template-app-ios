//
//  ScanExporterTests.swift
//  IOSTemplateAppTests
//

import Foundation
import Testing
@testable import IOSTemplateApp

struct ScanExporterTests {
    private let base = Date(timeIntervalSince1970: 1_757_635_200) // 2025-09-12T00:00:00Z
    private let exportedAt = Date(timeIntervalSince1970: 1_757_638_800) // 2025-09-12T01:00:00Z

    private var records: [ScanRecord] {
        [
            ScanRecord(name: "Shilokuma", url: "https://fortee.jp/u/Shilokuma", source: .qrCode, scannedAt: base),
            ScanRecord(name: "Hoge", url: "https://fortee.jp/u/Hoge", source: .nfc, scannedAt: base.addingTimeInterval(60)),
            ScanRecord(name: "Shilokuma", url: "https://fortee.jp/u/Shilokuma", source: .nfc, scannedAt: base.addingTimeInterval(120)),
            ScanRecord(name: "Piyo", url: "https://fortee.jp/u/Piyo", source: .qrCode, scannedAt: base.addingTimeInterval(180))
        ]
    }

    private func render(_ options: ExportOptions) -> String {
        ScanExporter(records: records, options: options, exportedAt: exportedAt).render()
    }

    @Test func simpleUniqueWithoutCounts() {
        let options = ExportOptions(format: .simple, includeDuplicates: false, includeCounts: false)
        #expect(render(options) == "Shilokuma, Hoge, Piyo")
    }

    @Test func simpleWithDuplicatesAndCounts() {
        let options = ExportOptions(format: .simple, includeDuplicates: true, includeCounts: true)
        #expect(render(options) == "Shilokuma, Hoge, Shilokuma, Piyo\n(総件数 4 / 重複なし 3)")
    }

    @Test func linesUnique() {
        let options = ExportOptions(format: .lines, includeDuplicates: false, includeCounts: false)
        #expect(render(options) == "Shilokuma\nHoge\nPiyo")
    }

    @Test func csvWithDuplicatesAndCounts() {
        let options = ExportOptions(format: .csv, includeDuplicates: true, includeCounts: true)
        let expected = """
        name,url,source,scanned_at,duplicate
        Shilokuma,https://fortee.jp/u/Shilokuma,qr,2025-09-12T00:00:00Z,false
        Hoge,https://fortee.jp/u/Hoge,nfc,2025-09-12T00:01:00Z,false
        Shilokuma,https://fortee.jp/u/Shilokuma,nfc,2025-09-12T00:02:00Z,true
        Piyo,https://fortee.jp/u/Piyo,qr,2025-09-12T00:03:00Z,false

        total_count,4
        unique_count,3
        """
        #expect(render(options) == expected)
    }

    @Test func csvEscapesSpecialCharacters() {
        let record = ScanRecord(name: "A,\"B\"", url: "https://example.com/u/A,%22B%22", source: .manual, scannedAt: base)
        let options = ExportOptions(format: .csv, includeDuplicates: false, includeCounts: false)
        let csv = ScanExporter(records: [record], options: options, exportedAt: exportedAt).render()
        #expect(csv.contains("\"A,\"\"B\"\"\",\"https://example.com/u/A,%22B%22\",manual"))
    }

    @Test func jsonUniqueWithCounts() throws {
        let options = ExportOptions(format: .json, includeDuplicates: false, includeCounts: true)
        let data = Data(render(options).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["exportedAt"] as? String == "2025-09-12T01:00:00Z")
        #expect(object["includeDuplicates"] as? Bool == false)
        let counts = try #require(object["counts"] as? [String: Int])
        #expect(counts == ["total": 4, "unique": 3])
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.map { $0["name"] as? String } == ["Shilokuma", "Hoge", "Piyo"])
        #expect(items.map { $0["source"] as? String } == ["qr", "nfc", "qr"])
        #expect(items.allSatisfy { ($0["duplicate"] as? Bool) == false })
    }

    @Test func jsonOmitsCountsWhenDisabled() throws {
        let options = ExportOptions(format: .json, includeDuplicates: true, includeCounts: false)
        let data = Data(render(options).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["counts"] == nil)
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.count == 4)
        #expect(items[2]["duplicate"] as? Bool == true)
    }

    @Test func suggestedFileNameUsesFormatExtension() {
        for format in ExportFormat.allCases {
            let exporter = ScanExporter(records: [], options: ExportOptions(format: format), exportedAt: exportedAt)
            #expect(exporter.suggestedFileName().hasSuffix(".\(format.fileExtension)"))
        }
    }
}
