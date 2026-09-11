//
//  ScanDataDocument.swift
//  IOSTemplateApp
//

import Foundation
import UniformTypeIdentifiers

/// 端末間でデータを統合するための書き出し / 読み込み形式
struct ScanDataDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileExtension = "scans"
    static let typeIdentifier = "ml.mrs1669.IOSTemplateApp.scans"

    var version: Int = ScanDataDocument.currentVersion
    var exportedAt: Date
    var deviceName: String
    var records: [ScanRecord]

    init(exportedAt: Date = .now, deviceName: String, records: [ScanRecord]) {
        self.exportedAt = exportedAt
        self.deviceName = deviceName
        self.records = records
    }

    func encoded() throws -> Data {
        try ScanJSON.makeEncoder(prettyPrinted: true).encode(self)
    }

    /// `.scans` ドキュメント、または `ScanRecord` の配列だけの JSON を読み込む
    static func decode(_ data: Data) throws -> ScanDataDocument {
        let decoder = ScanJSON.makeDecoder()
        if let document = try? decoder.decode(ScanDataDocument.self, from: data) {
            return document
        }
        let records = try decoder.decode([ScanRecord].self, from: data)
        return ScanDataDocument(deviceName: "", records: records)
    }

    func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let device = deviceName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let prefix = device.isEmpty ? "scans" : "scans-\(device)"
        return "\(prefix)-\(formatter.string(from: exportedAt)).\(Self.fileExtension)"
    }
}

extension UTType {
    /// Info.plist の `UTExportedTypeDeclarations` と一致させる
    static let scanData = UTType(exportedAs: ScanDataDocument.typeIdentifier, conformingTo: .json)
}
