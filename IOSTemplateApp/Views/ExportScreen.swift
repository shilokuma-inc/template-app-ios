//
//  ExportScreen.swift
//  IOSTemplateApp
//

import SwiftUI
import UIKit

/// 出力形式を選び、コピー / 共有する画面
struct ExportScreen: View {
    @Environment(\.dismiss) private var dismiss
    let records: [ScanRecord]

    @State private var options = ExportOptions()
    @State private var fileURL: URL?
    @State private var didCopy = false

    private var exporter: ScanExporter {
        ScanExporter(records: records, options: options)
    }

    var body: some View {
        NavigationStack {
            Form {
                optionsSection
                previewSection
                actionsSection
            }
            .navigationTitle("出力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task(id: options) {
                didCopy = false
                fileURL = options.format.sharesAsFile ? writeTemporaryFile() : nil
            }
        }
    }

    private var optionsSection: some View {
        Section("形式") {
            Picker("形式", selection: $options.format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            Toggle("重複を含める", isOn: $options.includeDuplicates)
            Toggle("件数を含める", isOn: $options.includeCounts)
            LabeledContent("件数", value: "総 \(exporter.totalCount) / 重複なし \(exporter.uniqueCount)")
        }
    }

    private var previewSection: some View {
        Section("プレビュー") {
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
                Label(didCopy ? "コピーしました" : "クリップボードにコピー", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            if options.format.sharesAsFile, let fileURL {
                ShareLink(item: fileURL, preview: SharePreview(fileURL.lastPathComponent)) {
                    Label("ファイルを共有", systemImage: "square.and.arrow.up")
                }
            } else {
                ShareLink(item: exporter.render()) {
                    Label("テキストを共有", systemImage: "square.and.arrow.up")
                }
            }
        }
        .disabled(records.isEmpty)
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
    ExportScreen(records: [
        ScanRecord(name: "Shilokuma", url: "https://fortee.jp/u/Shilokuma", source: .qrCode),
        ScanRecord(name: "Hoge", url: "https://fortee.jp/u/Hoge", source: .nfc),
        ScanRecord(name: "Shilokuma", url: "https://fortee.jp/u/Shilokuma", source: .nfc)
    ])
}
