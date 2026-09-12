//
//  ForteeProfileResolverTests.swift
//  IOSTemplateAppTests
//

import Foundation
import Testing
@testable import IOSTemplateApp

/// 固定のリダイレクト表で応答するスタブ
private struct StubRedirectFetcher: RedirectFetching {
    let redirects: [String: String]
    let error: Error?

    init(redirects: [String: String] = [:], error: Error? = nil) {
        self.redirects = redirects
        self.error = error
    }

    func redirectLocation(for url: URL) async throws -> URL? {
        if let error { throw error }
        return redirects[url.absoluteString].flatMap(URL.init(string:))
    }
}

private struct StubError: LocalizedError {
    var errorDescription: String? { "offline" }
}

struct ForteeProfileResolverTests {
    private let goProfile = "https://fortee.jp/iosdc-japan-2026/attendee/0jGtKzHXWWEOR9oGdBFrRLJHx8gL6t8s/go-profile"

    @Test("/u/ 形式はネットワークを使わずに解決する")
    func resolvesDirectURLWithoutNetwork() async throws {
        let resolver = ForteeProfileResolver(fetcher: StubRedirectFetcher(error: StubError()))
        let profile = try await resolver.resolve(" https://fortee.jp/u/Shilokuma ")
        #expect(profile == ResolvedProfile(name: "Shilokuma", profileURL: "https://fortee.jp/u/Shilokuma"))
    }

    @Test("go-profile URL はリダイレクト先からユーザー名を取る")
    func resolvesRedirect() async throws {
        let fetcher = StubRedirectFetcher(redirects: [goProfile: "https://fortee.jp/u/Shilokuma"])
        let profile = try await ForteeProfileResolver(fetcher: fetcher).resolve(goProfile)
        #expect(profile == ResolvedProfile(name: "Shilokuma", profileURL: "https://fortee.jp/u/Shilokuma"))
    }

    @Test("多段リダイレクトも追う")
    func followsMultipleRedirects() async throws {
        let fetcher = StubRedirectFetcher(redirects: [
            goProfile: "https://fortee.jp/redirect/1",
            "https://fortee.jp/redirect/1": "https://fortee.jp/u/Hoge"
        ])
        let profile = try await ForteeProfileResolver(fetcher: fetcher).resolve(goProfile)
        #expect(profile.name == "Hoge")
    }

    @Test("上限を超えるリダイレクトは notFound")
    func stopsAfterMaxRedirects() async {
        let fetcher = StubRedirectFetcher(redirects: [
            goProfile: "https://fortee.jp/loop/1",
            "https://fortee.jp/loop/1": "https://fortee.jp/loop/2",
            "https://fortee.jp/loop/2": "https://fortee.jp/u/Never"
        ])
        let resolver = ForteeProfileResolver(fetcher: fetcher, maxRedirects: 2)
        await #expect(throws: ProfileResolveError.notFound) {
            try await resolver.resolve(goProfile)
        }
    }

    @Test("リダイレクトされない URL は notFound")
    func noRedirectIsNotFound() async {
        let resolver = ForteeProfileResolver(fetcher: StubRedirectFetcher())
        await #expect(throws: ProfileResolveError.notFound) {
            try await resolver.resolve("https://fortee.jp/iosdc-japan-2026/timetable")
        }
    }

    @Test("URL でない文字列は invalidURL")
    func invalidURL() async {
        let resolver = ForteeProfileResolver(fetcher: StubRedirectFetcher())
        await #expect(throws: ProfileResolveError.invalidURL) {
            try await resolver.resolve("Shilokuma")
        }
    }

    @Test("通信エラーは network として伝える")
    func networkError() async {
        let resolver = ForteeProfileResolver(fetcher: StubRedirectFetcher(error: StubError()))
        await #expect(throws: ProfileResolveError.network("offline")) {
            try await resolver.resolve(goProfile)
        }
    }

    @Test("ScanStore は解決したユーザー名と profileURL を保存する")
    @MainActor
    func storeAddsResolvedProfile() async {
        let store = ScanStore.inMemory()
        let fetcher = StubRedirectFetcher(redirects: [goProfile: "https://fortee.jp/u/Shilokuma"])
        let result = await store.add(rawValue: goProfile, source: .qrCode, resolver: ForteeProfileResolver(fetcher: fetcher))

        guard case .added(let record) = result else {
            Issue.record("追加されていない: \(result)")
            return
        }
        #expect(record.name == "Shilokuma")
        #expect(record.url == goProfile)
        #expect(record.profileURL == "https://fortee.jp/u/Shilokuma")
        #expect(record.displayURL == "https://fortee.jp/u/Shilokuma")
    }

    @Test("ScanStore は解決失敗時に unresolved を返し履歴に追加しない")
    @MainActor
    func storeReportsUnresolved() async {
        let store = ScanStore.inMemory()
        let resolver = ForteeProfileResolver(fetcher: StubRedirectFetcher(error: StubError()))
        let result = await store.add(rawValue: goProfile, source: .qrCode, resolver: resolver)
        #expect(result == .unresolved("offline"))
        #expect(store.records.isEmpty)
    }
}
