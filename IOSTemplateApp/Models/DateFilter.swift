//
//  DateFilter.swift
//  IOSTemplateApp
//

import Foundation

/// 読み取り時刻による期間フィルター
struct DateFilter: Equatable, Sendable {
    var isEnabled = false
    var start: Date
    var end: Date

    init(
        isEnabled: Bool = false,
        start: Date? = nil,
        end: Date? = nil,
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        self.isEnabled = isEnabled
        self.start = start ?? calendar.startOfDay(for: now)
        self.end = end ?? Self.endOfDay(now, calendar: calendar)
    }

    /// 有効なときだけ範囲を返す
    var range: ClosedRange<Date>? {
        guard isEnabled else { return nil }
        return min(start, end)...max(start, end)
    }

    func contains(_ date: Date) -> Bool {
        guard let range else { return true }
        return range.contains(date)
    }

    func apply(_ records: [ScanRecord]) -> [ScanRecord] {
        guard isEnabled else { return records }
        return records.filter { contains($0.scannedAt) }
    }

    /// 指定日の 0:00〜23:59:59 に絞るフィルター
    static func day(_ date: Date, calendar: Calendar = .current) -> DateFilter {
        DateFilter(isEnabled: true, start: calendar.startOfDay(for: date), end: endOfDay(date, calendar: calendar))
    }

    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    enum Preset: CaseIterable, Identifiable {
        case today
        case yesterday
        case last7Days

        var id: Self { self }

        var title: String {
            switch self {
            case .today: tr("Today")
            case .yesterday: tr("Yesterday")
            case .last7Days: tr("Last 7 days")
            }
        }

        func filter(calendar: Calendar = .current, now: Date = .now) -> DateFilter {
            switch self {
            case .today:
                return .day(now, calendar: calendar)
            case .yesterday:
                let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
                return .day(yesterday, calendar: calendar)
            case .last7Days:
                let from = calendar.date(byAdding: .day, value: -6, to: now) ?? now
                return DateFilter(
                    isEnabled: true,
                    start: calendar.startOfDay(for: from),
                    end: DateFilter.endOfDay(now, calendar: calendar)
                )
            }
        }
    }
}

/// 1 日分の集計
struct DailySummary: Identifiable, Equatable, Sendable {
    /// その日の 0:00
    let day: Date
    let total: Int
    let unique: Int

    var id: Date { day }

    /// 日付ごとに集計し、新しい日から順に並べる
    static func summaries(for records: [ScanRecord], calendar: Calendar = .current) -> [DailySummary] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.scannedAt) }
        return grouped
            .map { day, records in
                DailySummary(day: day, total: records.count, unique: records.uniqueByName.count)
            }
            .sorted { $0.day > $1.day }
    }
}
