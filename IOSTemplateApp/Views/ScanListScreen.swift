//
//  ScanListScreen.swift
//  IOSTemplateApp
//

import SwiftUI

/// 読み取り済みユーザーの一覧と、QR / NFC 読み取りの起点になる画面
struct ScanListScreen: View {
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    @State private var nfcReader = NFCReader()
    @State private var isQRScannerPresented = false
    @State private var isManualEntryPresented = false
    @State private var isExportPresented = false
    @State private var showsAllRecords = false
    @State private var searchText = ""
    @State private var statusMessage: String?
    @State private var statusTask: Task<Void, Never>?

    private var displayedRecords: [ScanRecord] {
        let base = showsAllRecords ? store.filteredRecords.reversed() : store.filteredUniqueRecords
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            recordList
                .navigationTitle(tr("Scans"))
                .searchable(text: $searchText, prompt: tr("Search by name"))
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top, spacing: 0) { filterBanner }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .sheet(isPresented: $isQRScannerPresented) {
            QRScanScreen()
        }
        .sheet(isPresented: $isManualEntryPresented) {
            ManualEntrySheet(onResult: { showStatus($0.message) })
        }
        .sheet(isPresented: $isExportPresented) {
            ExportScreen()
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
                tr("No scans yet"),
                systemImage: "qrcode.viewfinder",
                description: Text(tr("Tap a button below to scan a QR code or an NFC tag."))
            )
        } else {
            List {
                Section {
                    modePicker
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                }
                Section {
                    if displayedRecords.isEmpty {
                        Text(tr("No matching records"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(displayedRecords) { record in
                        ScanRecordRow(record: record)
                    }
                    .onDelete(perform: deleteRecords)
                } header: {
                    Text(showsAllRecords ? tr("All records") : tr("Unique users"))
                } footer: {
                    Text(tr("Total \(store.filteredTotalCount) / Unique \(store.filteredUniqueCount)"))
                }
            }
        }
    }

    private var modePicker: some View {
        Picker(tr("Display"), selection: $showsAllRecords) {
            Text(tr("Unique \(store.filteredUniqueCount)")).tag(false)
            Text(tr("All \(store.filteredTotalCount)")).tag(true)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var filterBanner: some View {
        if let range = store.filter.range {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                Text(periodText(range))
                    .font(.footnote)
                    .lineLimit(2)
                Spacer()
                Button(tr("Clear")) {
                    store.filter.isEnabled = false
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.tint.opacity(0.12))
        }
    }

    /// 言語設定のロケールで整形する (`formatted()` の既定は端末ロケールのため)
    private func periodText(_ range: ClosedRange<Date>) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        let start = range.lowerBound.formatted(style)
        let end = range.upperBound.formatted(style)
        return tr("Period: \(start) – \(end)")
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let statusMessage {
                StatusBanner(message: statusMessage)
            }
            HStack(spacing: 12) {
                Button {
                    isQRScannerPresented = true
                } label: {
                    Label(tr("QR code"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    nfcReader.beginSession()
                } label: {
                    Label(tr("NFC"), systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!NFCReader.isAvailable)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(tr("Enter URL"), systemImage: "keyboard") { isManualEntryPresented = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(tr("Export"), systemImage: "square.and.arrow.up") { isExportPresented = true }
                .disabled(store.filteredRecords.isEmpty)
        }
    }

    // MARK: - Actions

    private func configureNFCReader() {
        nfcReader.onPayload = { payload in
            showStatus(tr("Looking up profile…"), autoHide: false)
            Task {
                let result = await store.add(
                    rawValue: payload,
                    source: .nfc,
                    deviceName: settings.deviceName,
                    resolver: .live
                )
                showStatus(result.message)
            }
        }
        nfcReader.alertMessageProvider = { payload in
            guard ForteeUserParser.isURL(payload) else {
                return tr("Could not read a user name. Try another tag.")
            }
            return tr("Tag read. You can keep scanning.")
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            store.remove(displayedRecords[index])
        }
    }

    private func showStatus(_ message: String, autoHide: Bool = true) {
        statusTask?.cancel()
        withAnimation { statusMessage = message }
        guard autoHide else { return }
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
                HStack(spacing: 6) {
                    Text(record.scannedAt, format: .dateTime.month().day().hour().minute())
                    if let device = record.deviceName, !device.isEmpty {
                        Text(verbatim: "·")
                        Text(device)
                    }
                }
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

/// 画面下部に一時表示するステータス
struct StatusBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    let store = ScanStore.inMemory()
    store.add(rawValue: "https://fortee.jp/u/Shilokuma", source: .qrCode, deviceName: "iPhone A")
    store.add(rawValue: "https://fortee.jp/u/Hoge", source: .nfc, deviceName: "iPhone B")
    return RootView()
        .environment(store)
        .environment(AppSettings())
}
