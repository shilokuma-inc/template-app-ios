//
//  DateFilterTests.swift
//  IOSTemplateAppTests
//

import Foundation
import Testing
@testable import IOSTemplateApp

struct DateFilterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    /// 2025-09-12 10:00 JST
    private var now: Date {
        calendar.date(from: DateComponents(year: 2025, month: 9, day: 12, hour: 10))!
    }

    private func record(_ name: String, hoursFromNow: Double) -> ScanRecord {
        ScanRecord(name: name, url: "https://fortee.jp/u/\(name)", source: .qrCode, scannedAt: now.addingTimeInterval(hoursFromNow * 3600))
    }

    @Test("無効なフィルターは全件を通す")
    func disabledFilterPassesEverything() {
        let filter = DateFilter(isEnabled: false, calendar: calendar, now: now)
        let records = [record("A", hoursFromNow: -48), record("B", hoursFromNow: 0)]
        #expect(filter.range == nil)
        #expect(filter.apply(records).count == 2)
    }

    @Test("今日プリセットは当日 0:00〜23:59:59 だけを通す")
    func todayPreset() {
        let filter = DateFilter.Preset.today.filter(calendar: calendar, now: now)
        let records = [
            record("Yesterday", hoursFromNow: -11), // 前日 23:00
            record("Morning", hoursFromNow: -10),   // 当日 0:00
            record("Night", hoursFromNow: 13.9),    // 当日 23:54
            record("Tomorrow", hoursFromNow: 14)    // 翌日 0:00
        ]
        #expect(filter.apply(records).map(\.name) == ["Morning", "Night"])
    }

    @Test("直近 7 日は 6 日前の 0:00 から今日の終わりまで")
    func last7DaysPreset() {
        let filter = DateFilter.Preset.last7Days.filter(calendar: calendar, now: now)
        let expectedStart = calendar.date(from: DateComponents(year: 2025, month: 9, day: 6))!
        #expect(filter.start == expectedStart)
        #expect(filter.contains(now))
        #expect(!filter.contains(expectedStart.addingTimeInterval(-1)))
    }

    @Test("開始と終了が逆でも範囲として扱う")
    func reversedBoundsAreNormalized() {
        let filter = DateFilter(isEnabled: true, start: now, end: now.addingTimeInterval(-3600), calendar: calendar, now: now)
        #expect(filter.range == now.addingTimeInterval(-3600)...now)
    }

    @Test("日別集計は日ごとの総件数と重複なし件数を新しい順に返す")
    func dailySummaries() {
        let records = [
            record("A", hoursFromNow: -30), // 前日
            record("A", hoursFromNow: -29), // 前日 (重複)
            record("B", hoursFromNow: 0),   // 当日
            record("C", hoursFromNow: 1)    // 当日
        ]
        let summaries = DailySummary.summaries(for: records, calendar: calendar)
        #expect(summaries.count == 2)
        #expect(summaries[0].day == calendar.startOfDay(for: now))
        #expect(summaries[0].total == 2 && summaries[0].unique == 2)
        #expect(summaries[1].total == 2 && summaries[1].unique == 1)
    }
}
