//
//  QRScanScreen.swift
//  IOSTemplateApp
//

import AVFoundation
import SwiftUI

/// QR コード読み取り画面。読み取るたびに結果をトーストで表示し、連続読み取りできる
struct QRScanScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ScanStore

    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("QRコード読み取り")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("\(store.uniqueCount) 件")
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
                title: "カメラを利用できません",
                description: "この端末では QR コードの読み取りに対応していません。"
            )
        } else if authorization == .denied || authorization == .restricted {
            unavailableView(
                title: "カメラへのアクセスが許可されていません",
                description: "設定アプリからカメラの利用を許可してください。"
            )
        } else {
            ZStack(alignment: .bottom) {
                QRScannerView(onScan: handleScan)
                    .ignoresSafeArea()
                if let toast {
                    toastView(toast)
                }
            }
        }
    }

    private func unavailableView(title: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: "camera.fill", description: Text(description))
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 32)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func handleScan(_ payload: String) {
        let result = store.add(rawValue: payload, source: .qrCode)
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
    QRScanScreen(store: ScanStore(userDefaults: nil))
}
