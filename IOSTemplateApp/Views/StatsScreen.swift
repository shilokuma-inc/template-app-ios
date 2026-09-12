//
//  StatsScreen.swift
//  IOSTemplateApp
//

import SwiftUI

/// 期間フィルターと日別集計を確認する画面
struct StatsScreen: View {
    @Environment(ScanStore.self) private var store

    private var summaries: [DailySummary] {
        DailySummary.summaries(for: store.records)
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                countsSection
                periodSection(filter: $store.filter)
                dailySection
            }
            .navigationTitle(tr("Summary"))
        }
    }

    // MARK: - Sections

    private var countsSection: some View {
        Section {
            HStack(spacing: 12) {
                CountTile(title: tr("Unique users"), value: store.filteredUniqueCount, tint: .accentColor)
                CountTile(title: tr("Total scans"), value: store.filteredTotalCount, tint: .secondary)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(store.filter.isEnabled ? tr("Selected period") : tr("All time"))
        }
    }

    private func periodSection(filter: Binding<DateFilter>) -> some View {
        Section {
            Toggle(tr("Filter by period"), isOn: filter.isEnabled)
            if filter.wrappedValue.isEnabled {
                DatePicker(tr("Start"), selection: filter.start)
                DatePicker(tr("End"), selection: filter.end)
                HStack {
                    ForEach(DateFilter.Preset.allCases) { preset in
                        Button(preset.title) {
                            store.filter = preset.filter()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text(tr("Period"))
        } footer: {
            Text(tr("The period applies to the list, the summary, and the export."))
        }
    }

    @ViewBuilder
    private var dailySection: some View {
        Section {
            if summaries.isEmpty {
                Text(tr("No scans yet"))
                    .foregroundStyle(.secondary)
            }
            ForEach(summaries) { summary in
                Button {
                    store.filter = .day(summary.day)
                } label: {
                    DailySummaryRow(summary: summary, isSelected: isSelected(summary))
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(tr("By day"))
        } footer: {
            Text(tr("Tap a day to filter by that day."))
        }
    }

    private func isSelected(_ summary: DailySummary) -> Bool {
        store.filter == .day(summary.day)
    }
}

/// 件数タイル
struct CountTile: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// 日別集計の 1 行
struct DailySummaryRow: View {
    let summary: DailySummary
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(summary.day, format: .dateTime.year().month().day().weekday(.abbreviated))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(tr("Unique \(summary.unique)"))
                    .font(.body.weight(.semibold))
                Text(tr("Total \(summary.total)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(tr("Selected"))
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    let store = ScanStore.inMemory()
    store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode)
    store.add(rawValue: "https://fortee.jp/u/Hoge", source: .nfc)
    store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .nfc)
    return StatsScreen()
        .environment(store)
        .environment(AppSettings())
}
