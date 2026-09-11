//
//  ScanSource.swift
//  IOSTemplateApp
//

import Foundation

/// 読み取り経路
enum ScanSource: String, Codable, CaseIterable, Sendable {
    case qrCode = "qr"
    case nfc
    case manual

    var displayName: String {
        switch self {
        case .qrCode: tr("QR code")
        case .nfc: tr("NFC")
        case .manual: tr("Manual entry")
        }
    }

    var symbolName: String {
        switch self {
        case .qrCode: "qrcode.viewfinder"
        case .nfc: "wave.3.right"
        case .manual: "keyboard"
        }
    }
}
