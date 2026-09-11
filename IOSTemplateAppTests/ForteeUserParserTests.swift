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

    @Test("`/u/` を含まない URL は末尾のパス要素を返す")
    func fallsBackToLastPathComponent() {
        #expect(ForteeUserParser.userName(from: "https://example.com/users/Hoge") == "Hoge")
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
}
