//
//  ForteeUserParserTests.swift
//  IOSTemplateAppTests
//

import Testing
@testable import IOSTemplateApp

struct ForteeUserParserTests {
    @Test("fortee のユーザー URL からユーザー名を抽出できる", arguments: [
        "https://fortee.jp/u/Shilokuma",
        "https://fortee.jp/u/Shilokuma/",
        "http://fortee.jp/u/Shilokuma?utm_source=qr",
        "HTTPS://FORTEE.JP/u/Shilokuma#top",
        "  https://fortee.jp/u/Shilokuma\n"
    ])
    func extractsUserName(url: String) {
        #expect(ForteeUserParser.userName(from: url) == "Shilokuma")
    }

    @Test("`/u/` を含まない URL はユーザー名として扱わない (go-profile を誤検出しない)")
    func doesNotGuessFromOtherPaths() {
        #expect(ForteeUserParser.userName(from: "https://example.com/users/Hoge") == nil)
        let goProfile = "https://fortee.jp/iosdc-japan-2026/attendee/0jGtKzHXWWEOR9oGdBFrRLJHx8gL6t8s/go-profile"
        #expect(ForteeUserParser.userName(from: goProfile) == nil)
    }

    @Test("パーセントエンコードされた名前をデコードする")
    func decodesPercentEncoding() {
        #expect(ForteeUserParser.userName(from: "https://fortee.jp/u/%E3%81%97%E3%82%8D") == "しろ")
    }

    @Test("URL でない文字列や名前が無い URL は nil", arguments: [
        "", "   ", "Shilokuma", "https://fortee.jp", "https://fortee.jp/u/", "https://fortee.jp/u"
    ])
    func returnsNilForInvalidInput(value: String) {
        #expect(ForteeUserParser.userName(from: value) == nil)
    }

    @Test("参加者トークンを抽出できる")
    func extractsAttendeeToken() {
        let goProfile = "https://fortee.jp/iosdc-japan-2026/attendee/0jGtKzHXWWEOR9oGdBFrRLJHx8gL6t8s/go-profile"
        #expect(ForteeUserParser.attendeeToken(from: goProfile) == "0jGtKzHXWWEOR9oGdBFrRLJHx8gL6t8s")
        #expect(ForteeUserParser.attendeeToken(from: "https://fortee.jp/u/Shilokuma") == nil)
        #expect(ForteeUserParser.attendeeToken(from: "https://fortee.jp/event/attendee/") == nil)
    }
}
