//
//  CameraScannerContainer.swift
//  IOSTemplateApp
//

import AVFoundation
import SwiftUI

/// カメラ権限と非対応端末の扱いをまとめた QR スキャナーの土台。
/// 権限が得られていればスキャナーを表示し、読み取った文字列を `onScan` で通知する
struct CameraScannerContainer<Overlay: View>: View {
    let onScan: (String) -> Void
    @ViewBuilder let overlay: () -> Overlay

    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        content
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
            ContentUnavailableView(
                tr("Camera unavailable"),
                systemImage: "camera.fill",
                description: Text(tr("This device does not support scanning QR codes."))
            )
        } else if authorization == .denied || authorization == .restricted {
            ContentUnavailableView(
                tr("Camera access denied"),
                systemImage: "camera.fill",
                description: Text(tr("Allow camera access in the Settings app."))
            )
        } else {
            ZStack(alignment: .bottom) {
                QRScannerView(onScan: onScan)
                    .ignoresSafeArea()
                overlay()
            }
        }
    }
}

/// QR コードを 1 つだけ読み取って閉じるシート (チケット登録・名札照合用)
struct QRCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onCapture: (String) -> Void

    @State private var didCapture = false

    var body: some View {
        NavigationStack {
            CameraScannerContainer(onScan: handleScan) {
                Text(tr("Point the camera at the QR code"))
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
            }
        }
    }

    private func handleScan(_ payload: String) {
        guard !didCapture else { return }
        didCapture = true
        onCapture(payload)
        dismiss()
    }
}

#Preview {
    QRCaptureSheet(title: "QR") { _ in }
}
