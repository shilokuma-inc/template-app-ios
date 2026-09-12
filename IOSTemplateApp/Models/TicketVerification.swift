//
//  TicketVerification.swift
//  IOSTemplateApp
//

import Foundation

/// チケットや名札の QR から得た「誰のものか」を表す情報
struct TicketIdentity: Equatable, Codable, Sendable {
    /// 読み取った元の文字列
    let rawValue: String
    /// 解決できたユーザー名 (通信できなかった場合などは `nil`)
    let name: String?
    /// `.../attendee/<token>/...` のトークン。ユーザー名が取れないときの比較キー
    let attendeeToken: String?

    init(rawValue: String, name: String?, attendeeToken: String? = nil) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name
        self.attendeeToken = attendeeToken ?? ForteeUserParser.attendeeToken(from: rawValue)
    }

    /// 表示用の名前。解決できていなければトークンか元の文字列
    var displayName: String {
        name ?? attendeeToken ?? rawValue
    }

    /// QR の内容を解決して identity を作る。解決に失敗してもトークンで比較できるよう identity 自体は返す
    static func resolve(_ rawValue: String, resolver: ForteeProfileResolver) async -> TicketIdentity {
        let name = try? await resolver.resolve(rawValue).name
        return TicketIdentity(rawValue: rawValue, name: name)
    }
}

/// 照合結果
enum TicketVerdict: Equatable, Sendable {
    case match(name: String)
    case mismatch(ticket: TicketIdentity, badge: TicketIdentity)
    /// どちらかのユーザーを特定できず判定できない
    case undetermined(ticket: TicketIdentity, badge: TicketIdentity)
}

enum TicketVerifier {
    /// チケットと名札が同じユーザーを指すか判定する。
    /// ユーザー名が両方分かればユーザー名 (大文字小文字無視)、そうでなければ参加者トークン、最後に文字列そのもので比較する
    static func verify(ticket: TicketIdentity, badge: TicketIdentity) -> TicketVerdict {
        if let ticketName = ticket.name, let badgeName = badge.name {
            return ticketName.lowercased() == badgeName.lowercased()
                ? .match(name: ticketName)
                : .mismatch(ticket: ticket, badge: badge)
        }
        if let ticketToken = ticket.attendeeToken, let badgeToken = badge.attendeeToken {
            return ticketToken == badgeToken
                ? .match(name: ticket.name ?? badge.name ?? ticketToken)
                : .mismatch(ticket: ticket, badge: badge)
        }
        if !ticket.rawValue.isEmpty, ticket.rawValue == badge.rawValue {
            return .match(name: ticket.displayName)
        }
        return .undetermined(ticket: ticket, badge: badge)
    }
}
