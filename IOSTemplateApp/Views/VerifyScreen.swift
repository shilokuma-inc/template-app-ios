//
//  VerifyScreen.swift
//  IOSTemplateApp
//

import SwiftUI

/// 自分のチケットと名札の QR が同じユーザーを指すか照合する画面
struct VerifyScreen: View {
    @Environment(AppSettings.self) private var settings

    @State private var capture: CaptureTarget?
    @State private var manualEntry: CaptureTarget?
    @State private var manualText = ""
    @State private var isResolving = false
    @State private var verdict: TicketVerdict?
    @State private var lastBadge: TicketIdentity?

    /// 読み取り対象 (チケット登録か名札照合か)
    private enum CaptureTarget: Identifiable {
        case ticket
        case badge

        var id: Self { self }

        var title: String {
            switch self {
            case .ticket: tr("Scan ticket QR code")
            case .badge: tr("Scan name badge QR code")
            }
        }

        var manualTitle: String {
            switch self {
            case .ticket: tr("Enter ticket URL")
            case .badge: tr("Enter name badge URL")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 結果はスクロールせずに見えるよう最上部に出す
                if let verdict {
                    resultSection(verdict)
                }
                ticketSection
                badgeSection
            }
            .navigationTitle(tr("Verify"))
            .sheet(item: $capture) { target in
                QRCaptureSheet(title: target.title) { payload in
                    handle(payload, for: target)
                }
            }
            .alert(
                manualEntry?.manualTitle ?? "",
                isPresented: Binding(get: { manualEntry != nil }, set: { if !$0 { manualEntry = nil } })
            ) {
                TextField(String("https://fortee.jp/..."), text: $manualText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(tr("Cancel"), role: .cancel) { manualText = "" }
                Button(tr("OK")) {
                    if let manualEntry { handle(manualText, for: manualEntry) }
                    manualText = ""
                }
            }
        }
    }

    // MARK: - Sections

    private var ticketSection: some View {
        Section {
            if let ticket = settings.myTicket {
                LabeledContent(tr("Registered ticket"), value: ticket.displayName)
                Text(ticket.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(tr("Re-register"), systemImage: "qrcode.viewfinder") { capture = .ticket }
                Button(tr("Remove"), systemImage: "trash", role: .destructive) {
                    settings.myTicket = nil
                    verdict = nil
                }
            } else {
                Button(tr("Scan ticket QR code"), systemImage: "qrcode.viewfinder") { capture = .ticket }
                Button(tr("Enter ticket URL"), systemImage: "keyboard") { manualEntry = .ticket }
            }
        } header: {
            Text(tr("My ticket"))
        } footer: {
            Text(tr("Register your own ticket first, then scan your name badge to check that they match."))
        }
    }

    private var badgeSection: some View {
        Section {
            Button {
                capture = .badge
            } label: {
                Label(tr("Scan name badge QR code"), systemImage: "person.text.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            Button(tr("Enter name badge URL"), systemImage: "keyboard") { manualEntry = .badge }
            if isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(tr("Verifying…"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Name badge"))
        }
        .disabled(settings.myTicket == nil || isResolving)
    }

    private func resultSection(_ verdict: TicketVerdict) -> some View {
        Section(tr("Result")) {
            VerdictCard(verdict: verdict)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    private func handle(_ payload: String, for target: CaptureTarget) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isResolving = true
        verdict = nil
        Task {
            let identity = await TicketIdentity.resolve(trimmed, resolver: .live)
            switch target {
            case .ticket:
                settings.myTicket = identity
            case .badge:
                lastBadge = identity
                if let ticket = settings.myTicket {
                    verdict = TicketVerifier.verify(ticket: ticket, badge: identity)
                }
            }
            isResolving = false
        }
    }
}

/// 照合結果の表示
struct VerdictCard: View {
    let verdict: TicketVerdict

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 56))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.bold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .mismatch(let ticket, let badge) = verdict {
                comparison(ticket: ticket, badge: badge)
            } else if case .undetermined(let ticket, let badge) = verdict {
                comparison(ticket: ticket, badge: badge)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func comparison(ticket: TicketIdentity, badge: TicketIdentity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Ticket: \(ticket.name ?? tr("Unknown"))"))
            Text(tr("Badge: \(badge.name ?? tr("Unknown"))"))
        }
        .font(.footnote.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var symbolName: String {
        switch verdict {
        case .match: "checkmark.seal.fill"
        case .mismatch: "xmark.octagon.fill"
        case .undetermined: "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch verdict {
        case .match: .green
        case .mismatch: .red
        case .undetermined: .orange
        }
    }

    private var title: String {
        switch verdict {
        case .match: tr("Match")
        case .mismatch: tr("Mismatch")
        case .undetermined: tr("Could not determine")
        }
    }

    private var detail: String {
        switch verdict {
        case .match(let name):
            tr("Both point to \(name).")
        case .mismatch:
            tr("The ticket and the badge point to different users.")
        case .undetermined:
            tr("Could not identify the user from one of the codes. Check the network connection and try again.")
        }
    }
}

#Preview("Match") {
    Form {
        VerdictCard(verdict: .match(name: "Shilokuma"))
        VerdictCard(verdict: .mismatch(
            ticket: TicketIdentity(rawValue: "https://fortee.jp/u/Shilokuma", name: "Shilokuma"),
            badge: TicketIdentity(rawValue: "https://fortee.jp/u/Hoge", name: "Hoge")
        ))
    }
}

#Preview("Screen") {
    VerifyScreen()
        .environment(AppSettings())
}
