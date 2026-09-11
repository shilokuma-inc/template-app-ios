//
//  QRScanScreen.swift
//  IOSTemplateApp
//

import AVFoundation
import SwiftUI

/// QR コード読み取り画面。読み取るたびに結果をトーストで表示し、連続読み取りできる
struct QRScanScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
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
        .task {
            if authorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                authorization = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !QRScannerView.isSupported {
            unavailableView(
                title: tr("Camera unavailable"),
                description: tr("This device does not support scanning QR codes.")
            )
        } else if authorization == .denied || authorization == .restricted {
            unavailableView(
                title: tr("Camera access denied"),
                description: tr("Allow camera access in the Settings app.")
            )
        } else {
            ZStack(alignment: .bottom) {
                QRScannerView(onScan: handleScan)
                    .ignoresSafeArea()
                if let toast {
                    StatusBanner(message: toast)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    private func unavailableView(title: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: "camera.fill", description: Text(description))
    }

    private func handleScan(_ payload: String) {
        let result = store.add(rawValue: payload, source: .qrCode, deviceName: settings.deviceName)
        showToast(result.message)
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
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
