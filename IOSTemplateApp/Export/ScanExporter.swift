//
//  ScanExporter.swift
//  IOSTemplateApp
//

import Foundation

/// 読み取り履歴を指定形式の文字列に変換する
struct ScanExporter {
    let records: [ScanRecord]
    let options: ExportOptions
    let exportedAt: Date

    init(records: [ScanRecord], options: ExportOptions, exportedAt: Date = .now) {
        self.records = records
        self.options = options
        self.exportedAt = exportedAt
    }

    var totalCount: Int { records.count }
    var uniqueCount: Int { Set(records.map(\.dedupeKey)).count }

    /// 出力対象のレコード (`includeDuplicates` に応じて全履歴か重複なしリスト)
    var targetRecords: [ScanRecord] {
        guard !options.includeDuplicates else { return records }
        var seen = Set<String>()
        return records.filter { seen.insert($0.dedupeKey).inserted }
    }

    func render() -> String {
        switch options.format {
        case .simple: renderSimple()
        case .lines: renderLines()
        case .csv: renderCSV()
        case .json: renderJSON()
        }
    }

    func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "scans-\(formatter.string(from: exportedAt)).\(options.format.fileExtension)"
    }

    // MARK: - Formats

    private var countsSummary: String {
        "総件数 \(totalCount) / 重複なし \(uniqueCount)"
    }

    private func renderSimple() -> String {
        let body = targetRecords.map(\.name).joined(separator: ", ")
        return options.includeCounts ? "\(body)\n(\(countsSummary))" : body
    }

    private func renderLines() -> String {
        var lines = targetRecords.map(\.name)
        if options.includeCounts {
            lines.append("")
            lines.append(countsSummary)
        }
        return lines.joined(separator: "\n")
    }

    private func renderCSV() -> String {
        var seen = Set<String>()
        var lines = ["name,url,source,scanned_at,duplicate"]
        for record in targetRecords {
            let isDuplicate = !seen.insert(record.dedupeKey).inserted
            let fields = [
                record.name,
                record.url,
                record.source.rawValue,
                Self.iso8601.string(from: record.scannedAt),
                isDuplicate ? "true" : "false"
            ]
            lines.append(fields.map(Self.csvEscaped).joined(separator: ","))
        }
        if options.includeCounts {
            lines.append("")
            lines.append("total_count,\(totalCount)")
            lines.append("unique_count,\(uniqueCount)")
        }
        return lines.joined(separator: "\n")
    }

    private func renderJSON() -> String {
        var seen = Set<String>()
        let items = targetRecords.map { record in
            JSONItem(
                name: record.name,
                url: record.url,
                source: record.source.rawValue,
                scannedAt: record.scannedAt,
                duplicate: !seen.insert(record.dedupeKey).inserted
            )
        }
        let document = JSONDocument(
            exportedAt: exportedAt,
            includeDuplicates: options.includeDuplicates,
            counts: options.includeCounts ? JSONCounts(total: totalCount, unique: uniqueCount) : nil,
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func csvEscaped(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private struct JSONDocument: Encodable {
        let exportedAt: Date
        let includeDuplicates: Bool
        let counts: JSONCounts?
        let items: [JSONItem]
    }

    private struct JSONCounts: Encodable {
        let total: Int
        let unique: Int
    }

    private struct JSONItem: Encodable {
        let name: String
        let url: String
        let source: String
        let scannedAt: Date
        let duplicate: Bool
    }
}
