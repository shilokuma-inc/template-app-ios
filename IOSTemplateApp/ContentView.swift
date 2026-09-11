//
//  ContentView.swift
//  IOSTemplateApp
//
//  Created by 村石 拓海 on 2024/05/12.
//

import SwiftUI

/// 読み取り済みユーザーの一覧と、QR / NFC 読み取りの起点になるホーム画面
struct ContentView: View {
    @State private var store = ScanStore()
    @State private var nfcReader = NFCReader()

    @State private var isQRScannerPresented = false
    @State private var isManualEntryPresented = false
    @State private var isExportPresented = false
    @State private var isClearConfirmationPresented = false
    @State private var showsAllRecords = false
    @State private var statusMessage: String?
    @State private var statusTask: Task<Void, Never>?

    private var displayedRecords: [ScanRecord] {
        showsAllRecords ? store.records.reversed() : store.uniqueRecords
    }

    var body: some View {
        NavigationStack {
            recordList
                .navigationTitle("読み取り一覧")
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .sheet(isPresented: $isQRScannerPresented) {
            QRScanScreen(store: store)
        }
        .sheet(isPresented: $isManualEntryPresented) {
            ManualEntrySheet(store: store, onResult: { showStatus($0.message) })
        }
        .sheet(isPresented: $isExportPresented) {
            ExportScreen(records: store.records)
        }
        .confirmationDialog("すべての履歴を削除しますか？", isPresented: $isClearConfirmationPresented, titleVisibility: .visible) {
            Button("削除", role: .destructive) { store.removeAll() }
        }
        .onAppear(perform: configureNFCReader)
        .onChange(of: nfcReader.lastError) { _, error in
            if let error { showStatus(error) }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recordList: some View {
        if store.records.isEmpty {
            ContentUnavailableView(
                "まだ読み取りがありません",
                systemImage: "qrcode.viewfinder",
                description: Text("下のボタンから QR コードまたは NFC を読み取ってください。")
            )
        } else {
            List {
                Section {
                    ForEach(displayedRecords) { record in
                        ScanRecordRow(record: record)
                    }
                    .onDelete(perform: deleteRecords)
                } header: {
                    Text(showsAllRecords ? "全履歴 (\(store.totalCount) 件)" : "重複なし (\(store.uniqueCount) 件)")
                } footer: {
                    Text("総件数 \(store.totalCount) / 重複なし \(store.uniqueCount)")
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            statusBanner
            scanButtons
        }
        .padding()
        .background(.bar)
    }

    private var scanButtons: some View {
        HStack(spacing: 12) {
            Button {
                isQRScannerPresented = true
            } label: {
                Label("QRコード", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            Button {
                nfcReader.beginSession()
            } label: {
                Label("NFC", systemImage: "wave.3.right")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!NFCReader.isAvailable)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle("全履歴を表示", isOn: $showsAllRecords)
                Button("URLを手入力", systemImage: "keyboard") { isManualEntryPresented = true }
                Divider()
                Button("すべて削除", systemImage: "trash", role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(store.records.isEmpty)
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("出力", systemImage: "square.and.arrow.up") { isExportPresented = true }
                .disabled(store.records.isEmpty)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func configureNFCReader() {
        nfcReader.onPayload = { payload in
            let result = store.add(rawValue: payload, source: .nfc)
            showStatus(result.message)
        }
        nfcReader.alertMessageProvider = { payload in
            guard let name = ForteeUserParser.userName(from: payload) else {
                return "ユーザー名を読み取れませんでした。別のタグを近づけてください"
            }
            return "\(name) を読み取りました。続けて読み取れます"
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            store.remove(displayedRecords[index])
        }
    }

    private func showStatus(_ message: String) {
        statusTask?.cancel()
        withAnimation { statusMessage = message }
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { statusMessage = nil }
        }
    }
}

/// 一覧の 1 行
struct ScanRecordRow: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.source.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityLabel(record.source.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.body.weight(.medium))
                Text(record.scannedAt, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.source.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
