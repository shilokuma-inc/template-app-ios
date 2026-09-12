//
//  QRScanScreen.swift
//  IOSTemplateApp
//

import SwiftUI

/// QR コード読み取り画面。読み取るたびに結果をトーストで表示し、連続読み取りできる
struct QRScanScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            CameraScannerContainer(onScan: handleScan) {
                if let toast {
                    StatusBanner(message: toast)
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle(tr("Scan QR code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Close")) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(tr("Unique \(store.filteredUniqueCount)"))
                        .font(.headline)
                        .monospacedDigit()
                }
            }
        }
    }

    private func handleScan(_ payload: String) {
        showToast(tr("Looking up profile…"), autoHide: false)
        Task {
            let result = await store.add(
                rawValue: payload,
                source: .qrCode,
                deviceName: settings.deviceName,
                resolver: .live
            )
            showToast(result.message)
        }
    }

    private func showToast(_ message: String, autoHide: Bool = true) {
        toastTask?.cancel()
        withAnimation { toast = message }
        guard autoHide else { return }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
}

#Preview {
    QRScanScreen()
        .environment(ScanStore.inMemory())
        .environment(AppSettings())
}
