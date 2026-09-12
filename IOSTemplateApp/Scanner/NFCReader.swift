//
//  NFCReader.swift
//  IOSTemplateApp
//

import CoreNFC
import Foundation
import Observation

/// CoreNFC で NDEF タグを読み取り、URL / テキストのペイロードを通知する
@MainActor
@Observable
final class NFCReader: NSObject {
    /// 読み取ったペイロード文字列を受け取る
    var onPayload: ((String) -> Void)?
    /// 読み取り結果に応じて NFC シートに表示する文言を返す (未設定ならデフォルト文言)
    var alertMessageProvider: ((String) -> String)?
    private(set) var lastError: String?
    private(set) var isSessionActive = false

    private var session: NFCNDEFReaderSession?

    static var isAvailable: Bool {
        NFCNDEFReaderSession.readingAvailable
    }

    /// 読み取りセッションを開始する。複数タグを続けて読めるよう、初回読み取りでは終了しない
    func beginSession() {
        guard Self.isAvailable else {
            lastError = tr("NFC is not available on this device")
            return
        }
        lastError = nil
        let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session.alertMessage = tr("Hold an NFC tag near the top of your iPhone")
        self.session = session
        isSessionActive = true
        session.begin()
    }

    func endSession() {
        session?.invalidate()
    }

    private func handle(messages: [NFCNDEFMessage]) {
        var payloads: [String] = []
        for record in messages.flatMap(\.records) {
            if let url = record.wellKnownTypeURIPayload() {
                payloads.append(url.absoluteString)
                continue
            }
            let (wellKnownText, _) = record.wellKnownTypeTextPayload()
            if let wellKnownText {
                payloads.append(wellKnownText)
            } else if let text = String(bytes: record.payload, encoding: .utf8), !text.isEmpty {
                payloads.append(text)
            }
        }
        for payload in payloads {
            onPayload?(payload)
            if let provider = alertMessageProvider {
                session?.alertMessage = provider(payload)
            }
        }
        if payloads.isEmpty {
            session?.alertMessage = tr("Unsupported tag. Try another tag.")
        }
    }

    private func handleInvalidation(_ error: Error) {
        isSessionActive = false
        session = nil
        guard let readerError = error as? NFCReaderError else {
            lastError = error.localizedDescription
            return
        }
        switch readerError.code {
        case .readerSessionInvalidationErrorUserCanceled,
             .readerSessionInvalidationErrorFirstNDEFTagRead,
             .readerSessionInvalidationErrorSessionTimeout:
            lastError = nil
        default:
            lastError = readerError.localizedDescription
        }
    }
}

extension NFCReader: NFCNDEFReaderSessionDelegate {
    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        Task { @MainActor in
            handle(messages: messages)
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            handleInvalidation(error)
        }
    }
}
