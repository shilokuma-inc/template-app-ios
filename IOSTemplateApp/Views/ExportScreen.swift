//
//  ExportScreen.swift
//  IOSTemplateApp
//

import SwiftUI
import UIKit

/// 出力形式を選び、コピー / 共有する画面。期間フィルターが有効ならその範囲だけを出力する
struct ExportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store

    @State private var options = ExportOptions()
    @State private var fileURL: URL?
    @State private var didCopy = false

    private var exporter: ScanExporter {
        ScanExporter(records: store.filteredRecords, options: options, period: store.filter.range)
    }

    var body: some View {
        NavigationStack {
            Form {
                optionsSection
                previewSection
                actionsSection
            }
            .navigationTitle(tr("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Close")) { dismiss() }
                }
            }
            .task(id: options) {
                didCopy = false
                fileURL = options.format.sharesAsFile ? writeTemporaryFile() : nil
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Picker(tr("Format"), selection: $options.format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            Toggle(tr("Include duplicates"), isOn: $options.includeDuplicates)
            Toggle(tr("Include counts"), isOn: $options.includeCounts)
            LabeledContent(tr("Counts"), value: tr("Total \(exporter.totalCount) / Unique \(exporter.uniqueCount)"))
        } header: {
            Text(tr("Format"))
        } footer: {
            if store.filter.isEnabled {
                Text(tr("Only records in the selected period are exported."))
            }
        }
    }

    private var previewSection: some View {
        Section(tr("Preview")) {
            ScrollView(.horizontal) {
                Text(exporter.render())
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = exporter.render()
                didCopy = true
            } label: {
                Label(
                    didCopy ? tr("Copied") : tr("Copy to clipboard"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            if options.format.sharesAsFile, let fileURL {
                ShareLink(item: fileURL, preview: SharePreview(fileURL.lastPathComponent)) {
                    Label(tr("Share file"), systemImage: "square.and.arrow.up")
                }
            } else {
                ShareLink(item: exporter.render()) {
                    Label(tr("Share text"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .disabled(store.filteredRecords.isEmpty)
    }

    private func writeTemporaryFile() -> URL? {
        let exporter = exporter
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exporter.suggestedFileName())
        do {
            try exporter.render().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

#Preview {
    let store = ScanStore.inMemory()
    store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode)
    store.add(rawValue: "https://fortee.jp/u/Hoge", source: .nfc)
    store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .nfc)
    return ExportScreen()
        .environment(store)
}
