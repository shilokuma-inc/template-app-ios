//
//  TicketVerifierTests.swift
//  IOSTemplateAppTests
//

import Testing
@testable import IOSTemplateApp

struct TicketVerifierTests {
    private let ticketURL = "https://fortee.jp/iosdc-japan-2026/attendee/TOKEN-A/go-profile"
    private let badgeURL = "https://fortee.jp/iosdc-japan-2026/attendee/TOKEN-A/go-profile"

    @Test("ユーザー名が一致すれば match (大文字小文字は無視)")
    func matchesByName() {
        let ticket = TicketIdentity(rawValue: "https://fortee.jp/u/Shilokuma", name: "Shilokuma")
        let badge = TicketIdentity(rawValue: badgeURL, name: "shilokuma")
        #expect(TicketVerifier.verify(ticket: ticket, badge: badge) == .match(name: "Shilokuma"))
    }

    @Test("ユーザー名が異なれば mismatch")
    func mismatchesByName() {
        let ticket = TicketIdentity(rawValue: ticketURL, name: "Shilokuma")
        let badge = TicketIdentity(rawValue: badgeURL, name: "Hoge")
        #expect(TicketVerifier.verify(ticket: ticket, badge: badge) == .mismatch(ticket: ticket, badge: badge))
    }

    @Test("ユーザー名が取れなくても参加者トークンで比較できる")
    func fallsBackToAttendeeToken() {
        let ticket = TicketIdentity(rawValue: ticketURL, name: nil)
        let badge = TicketIdentity(rawValue: badgeURL, name: nil)
        #expect(ticket.attendeeToken == "TOKEN-A")
        #expect(TicketVerifier.verify(ticket: ticket, badge: badge) == .match(name: "TOKEN-A"))

        let other = TicketIdentity(rawValue: "https://fortee.jp/iosdc-japan-2026/attendee/TOKEN-B/go-profile", name: nil)
        #expect(TicketVerifier.verify(ticket: ticket, badge: other) == .mismatch(ticket: ticket, badge: other))
    }

    @Test("同じ文字列なら match")
    func matchesIdenticalRawValue() {
        let ticket = TicketIdentity(rawValue: "TICKET-123", name: nil)
        let badge = TicketIdentity(rawValue: "TICKET-123", name: nil)
        #expect(TicketVerifier.verify(ticket: ticket, badge: badge) == .match(name: "TICKET-123"))
    }

    @Test("どちらも特定できなければ undetermined")
    func undetermined() {
        let ticket = TicketIdentity(rawValue: "TICKET-123", name: nil)
        let badge = TicketIdentity(rawValue: "https://fortee.jp/iosdc-japan-2026/timetable", name: nil)
        #expect(TicketVerifier.verify(ticket: ticket, badge: badge) == .undetermined(ticket: ticket, badge: badge))
    }
}
