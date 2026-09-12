//
//  ForteeProfileResolver.swift
//  IOSTemplateApp
//

import Foundation

/// 解決済みのプロフィール
struct ResolvedProfile: Equatable, Sendable {
    /// ユーザー名 (例: `Shilokuma`)
    let name: String
    /// 最終的なプロフィール URL (例: `https://fortee.jp/u/Shilokuma`)
    let profileURL: String
}

enum ProfileResolveError: Error, LocalizedError, Equatable {
    case invalidURL
    /// リダイレクトを追ってもプロフィール URL にたどり着かなかった
    case notFound
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: tr("Not a valid URL")
        case .notFound: tr("The URL did not lead to a fortee profile")
        case .network(let description): description
        }
    }
}

/// リダイレクト先の取得。テストで差し替えられるようにプロトコル化
protocol RedirectFetching: Sendable {
    /// `url` にアクセスし、リダイレクトされるならその先の URL を返す。リダイレクトされなければ `nil`
    func redirectLocation(for url: URL) async throws -> URL?
}

/// QR / NFC から得た URL をユーザー名に解決する。
/// `.../attendee/<token>/go-profile` のような URL は `https://fortee.jp/u/<name>` へ 302 されるため、
/// リダイレクトを 1 段ずつ追って `/u/<name>` が現れた時点で確定する
struct ForteeProfileResolver: Sendable {
    let fetcher: any RedirectFetching
    let maxRedirects: Int

    static let live = ForteeProfileResolver(fetcher: URLSessionRedirectFetcher())

    init(fetcher: any RedirectFetching, maxRedirects: Int = 5) {
        self.fetcher = fetcher
        self.maxRedirects = maxRedirects
    }

    func resolve(_ rawValue: String) async throws -> ResolvedProfile {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = ForteeUserParser.userName(from: trimmed) {
            return ResolvedProfile(name: name, profileURL: trimmed)
        }
        guard var current = ForteeUserParser.url(from: trimmed) else {
            throw ProfileResolveError.invalidURL
        }
        for _ in 0..<maxRedirects {
            let next: URL?
            do {
                next = try await fetcher.redirectLocation(for: current)
            } catch {
                throw ProfileResolveError.network(error.localizedDescription)
            }
            guard let next else { throw ProfileResolveError.notFound }
            if let name = ForteeUserParser.userName(from: next.absoluteString) {
                return ResolvedProfile(name: name, profileURL: next.absoluteString)
            }
            current = next
        }
        throw ProfileResolveError.notFound
    }
}

/// URLSession でリダイレクトを追わずに `Location` ヘッダーだけを読む
final class URLSessionRedirectFetcher: RedirectFetching {
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: RedirectBlockingDelegate(), delegateQueue: nil)
    }

    func redirectLocation(for url: URL) async throws -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else {
            return nil
        }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    /// リダイレクトを自動で追わせず、30x レスポンスをそのまま返させる
    private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
