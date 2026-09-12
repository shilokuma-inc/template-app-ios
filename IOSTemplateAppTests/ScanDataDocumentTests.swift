//
//  ScanDataDocumentTests.swift
//  IOSTemplateAppTests
//

import Foundation
import Testing
@testable import IOSTemplateApp

struct ScanDataDocumentTests {
    private let base = Date(timeIntervalSince1970: 1_757_635_200)

    private var sampleRecords: [ScanRecord] {
        [
            ScanRecord(name: "Shilokuma", url: "https://fortee.jp/u/Shilokuma", source: .qrCode, scannedAt: base, deviceName: "iPhone A"),
            ScanRecord(name: "Hoge", url: "https://fortee.jp/u/Hoge", source: .nfc, scannedAt: base.addingTimeInterval(60), deviceName: "iPhone A")
        ]
    }

    @Test("書き出したデータをそのまま読み戻せる")
    func roundTrip() throws {
        let document = ScanDataDocument(exportedAt: base, deviceName: "iPhone A", records: sampleRecords)
        let decoded = try ScanDataDocument.decode(try document.encoded())
        #expect(decoded == document)
        #expect(decoded.version == ScanDataDocument.currentVersion)
    }

    @Test("レコード配列だけの JSON も読み込める")
    func decodesBareRecordArray() throws {
        let records = sampleRecords
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        let decoded = try ScanDataDocument.decode(data)
        #expect(decoded.records == records)
    }

    @Test("ファイル名は端末名と拡張子 .scans を含む")
    func fileName() {
        let document = ScanDataDocument(exportedAt: base, deviceName: "Taro's iPhone", records: [])
        let name = document.suggestedFileName()
        #expect(name.hasPrefix("scans-Taro-s-iPhone-"))
        #expect(name.hasSuffix(".scans"))
    }

    @Test("旧バージョンの deviceName 無しレコードも読み込める")
    func decodesRecordWithoutDeviceName() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Hoge","url":"https://fortee.jp/u/Hoge",
          "source":"qr","scannedAt":"2025-09-12T00:00:00Z"}]
        """
        let decoded = try ScanDataDocument.decode(Data(json.utf8))
        #expect(decoded.records.first?.deviceName == nil)
        #expect(decoded.records.first?.source == .qrCode)
    }
}
