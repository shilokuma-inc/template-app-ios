//
//  ExportOptions.swift
//  IOSTemplateApp
//

import Foundation

/// 出力形式
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// `Shilokuma, Hoge, Piyo`
    case simple
    /// 1 行 1 件
    case lines
    case csv
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simple: "簡易"
        case .lines: "行区切り"
        case .csv: "CSV"
        case .json: "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .simple, .lines: "txt"
        case .csv: "csv"
        case .json: "json"
        }
    }

    /// 共有時にファイルとして扱うか (テキスト形式はそのまま文字列を共有する)
    var sharesAsFile: Bool {
        switch self {
        case .simple, .lines: false
        case .csv, .json: true
        }
    }
}

struct ExportOptions: Equatable, Sendable {
    var format: ExportFormat = .simple
    /// `true` なら重複を含む全履歴、`false` なら重複なしリスト
    var includeDuplicates = false
    /// 件数 (総件数 / 重複なし件数) を含める
    var includeCounts = false
}
