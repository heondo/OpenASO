import Foundation
import Testing
@testable import OpenASO

@MainActor
struct AppleAdsCookieJarTests {
    private let popularityURL = URL(string: "https://app-ads.apple.com/cm/api/v2/keywords/popularities")!

    // MARK: - Header construction

    @Test
    func headerCarriesEveryCookieInStableOrder() {
        let jar = AppleAdsCookieJar(cookies: [
            AppleAdsCookie(name: "searchads.soid", value: "session"),
            AppleAdsCookie(name: "XSRF-TOKEN-CM", value: "token")
        ])

        #expect(jar.cookieHeader(for: popularityURL) == "XSRF-TOKEN-CM=token; searchads.soid=session")
    }

    @Test
    func headerOmitsCookiesScopedToAnotherPath() {
        let jar = AppleAdsCookieJar(cookies: [
            AppleAdsCookie(name: "everywhere", value: "yes"),
            AppleAdsCookie(name: "reporting-only", value: "no", path: "/reporting")
        ])

        #expect(jar.cookieHeader(for: popularityURL) == "everywhere=yes")
    }

    @Test
    func headerOmitsExpiredCookies() {
        let now = Date(timeIntervalSince1970: 1_000)
        let jar = AppleAdsCookieJar(cookies: [
            AppleAdsCookie(name: "live", value: "yes", expiresAt: now.addingTimeInterval(60)),
            AppleAdsCookie(name: "stale", value: "no", expiresAt: now.addingTimeInterval(-60))
        ])

        #expect(jar.cookieHeader(for: popularityURL, asOf: now) == "live=yes")
    }

    /// Apple hands the Ads session out as session cookies. Treating "no expiry" as "expired" would
    /// empty the jar on the first request.
    @Test
    func cookiesWithoutAnExpiryNeverExpire() {
        let jar = AppleAdsCookieJar(cookies: [AppleAdsCookie(name: "searchads.soid", value: "session")])

        #expect(jar.cookieHeader(for: popularityURL, asOf: .distantFuture) == "searchads.soid=session")
    }

    // MARK: - Rotation

    @Test
    func ingestingSetCookieReplacesTheRotatedValue() throws {
        let jar = AppleAdsCookieJar(cookies: [AppleAdsCookie(name: "searchads.soid", value: "old")])
        let response = makeHTTPURLResponse(
            url: popularityURL,
            statusCode: 200,
            headerFields: ["Set-Cookie": "searchads.soid=rotated; Path=/"]
        )

        #expect(jar.ingest(response: response))
        #expect(jar.cookieHeader(for: popularityURL) == "searchads.soid=rotated")
        #expect(jar.hasUnsavedRotation)
    }

    @Test
    func ingestingAnExpiredSetCookieDropsTheCookie() {
        let jar = AppleAdsCookieJar(cookies: [
            AppleAdsCookie(name: "searchads.soid", value: "session"),
            AppleAdsCookie(name: "retired", value: "value")
        ])
        let response = makeHTTPURLResponse(
            url: popularityURL,
            statusCode: 200,
            headerFields: ["Set-Cookie": "retired=value; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"]
        )

        #expect(jar.ingest(response: response))
        #expect(jar.cookieHeader(for: popularityURL) == "searchads.soid=session")
    }

    @Test
    func ingestingAnUnchangedSetCookieLeavesTheJarClean() {
        let jar = AppleAdsCookieJar(cookies: [
            AppleAdsCookie(name: "searchads.soid", value: "session", path: "/")
        ])
        let response = makeHTTPURLResponse(
            url: popularityURL,
            statusCode: 200,
            headerFields: ["Set-Cookie": "searchads.soid=session; Path=/"]
        )

        #expect(!jar.ingest(response: response))
        #expect(!jar.hasUnsavedRotation)
    }

    @Test
    func reseedingClearsPendingRotation() {
        let jar = AppleAdsCookieJar(cookies: [AppleAdsCookie(name: "searchads.soid", value: "old")])
        jar.merge([AppleAdsCookie(name: "searchads.soid", value: "rotated")])
        #expect(jar.hasUnsavedRotation)

        jar.replaceAll(with: [AppleAdsCookie(name: "searchads.soid", value: "fresh")])

        #expect(!jar.hasUnsavedRotation)
        #expect(jar.cookieHeader(for: popularityURL) == "searchads.soid=fresh")
    }

    // MARK: - Request wiring

    /// The regression this whole jar exists for: with `httpShouldHandleCookies` left at its default
    /// of `true`, URLSession overwrites the Cookie header below with `HTTPCookieStorage.shared`,
    /// which accumulates cookies across sign-ins and never gets cleared by reconnecting.
    @Test
    func appleAdsRequestsOptOutOfSharedCookieStorage() async throws {
        let recorder = RequestRecorder()
        let client = MockHTTPClient { request in
            recorder.record(request)
            return (
                Data(#"{"status":"success","data":[{"name":"focus","popularity":50}]}"#.utf8),
                makeHTTPURLResponse(url: try #require(request.url), statusCode: 200)
            )
        }

        _ = try await AppleAdsCMPopularityClient(httpClient: client, cookieJar: jarredSession().jar)
            .keywordPopularities(
                for: ["focus"],
                storefrontCode: "us",
                adamId: 123,
                session: jarredSession().session
            )

        let request = try #require(recorder.requests.first)
        #expect(request.httpShouldHandleCookies == false)
    }

    /// Before the jar, the session snapshot was frozen at sign-in: Apple would rotate a cookie and
    /// every later request would keep replaying the retired one until it 401'd.
    @Test
    func aRotatedCookieReachesTheNextRequest() async throws {
        let recorder = RequestRecorder()
        let (session, jar) = jarredSession()
        let client = MockHTTPClient { request in
            recorder.record(request)
            let url = try #require(request.url)
            return (
                Data(#"{"status":"success","data":[{"name":"focus","popularity":50}]}"#.utf8),
                makeHTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    headerFields: ["Set-Cookie": "searchads.soid=rotated; Path=/"]
                )
            )
        }
        let popularityClient = AppleAdsCMPopularityClient(httpClient: client, cookieJar: jar)

        for _ in 0 ..< 2 {
            _ = try await popularityClient.keywordPopularities(
                for: ["focus"],
                storefrontCode: "us",
                adamId: 123,
                session: session
            )
        }

        #expect(recorder.requests.count == 2)
        #expect(
            recorder.requests.first?.value(forHTTPHeaderField: "Cookie")
                == "XSRF-TOKEN-CM=token; searchads.soid=original"
        )
        #expect(
            recorder.requests.last?.value(forHTTPHeaderField: "Cookie")
                == "XSRF-TOKEN-CM=token; searchads.soid=rotated"
        )
    }

    /// Apple rotates the XSRF cookie too, and the CM endpoints reject a request whose
    /// `X-XSRF-TOKEN-CM` header disagrees with the cookie it was issued alongside.
    @Test
    func theXSRFHeaderFollowsItsCookie() async throws {
        let recorder = RequestRecorder()
        let (session, jar) = jarredSession()
        let client = MockHTTPClient { request in
            recorder.record(request)
            let url = try #require(request.url)
            return (
                Data(#"{"status":"success","data":[{"name":"focus","popularity":50}]}"#.utf8),
                makeHTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    headerFields: ["Set-Cookie": "XSRF-TOKEN-CM=rotated-token; Path=/"]
                )
            )
        }
        let popularityClient = AppleAdsCMPopularityClient(httpClient: client, cookieJar: jar)

        for _ in 0 ..< 2 {
            _ = try await popularityClient.keywordPopularities(
                for: ["focus"],
                storefrontCode: "us",
                adamId: 123,
                session: session
            )
        }

        #expect(recorder.requests.first?.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == "token")
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == "rotated-token")
    }

    @Test
    func deletingLastAuthenticationAndXSRFCookiesDoesNotResurrectSessionHeaders() {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=original; XSRF-TOKEN-CM=original-token",
            xsrfToken: "original-token",
            updatedAt: now
        )
        let jar = AppleAdsCookieJar(cookies: session.jarCookies)
        jar.merge([
            AppleAdsCookie(
                name: "searchads.soid",
                value: "deleted",
                expiresAt: now.addingTimeInterval(-1)
            ),
            AppleAdsCookie(
                name: "XSRF-TOKEN-CM",
                value: "deleted",
                expiresAt: now.addingTimeInterval(-1)
            ),
        ], asOf: now)

        var request = URLRequest(url: popularityURL)
        request.applyAppleAdsSession(session, jar: jar)

        #expect(jar.isEmpty)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == nil)
    }

    @Test
    func expiredOrPathInapplicableXSRFCookieNeverProducesAHeader() {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=session; XSRF-TOKEN-CM=legacy-token",
            xsrfToken: "legacy-token",
            updatedAt: now
        )
        for xsrf in [
            AppleAdsCookie(
                name: "XSRF-TOKEN-CM",
                value: "expired",
                expiresAt: now.addingTimeInterval(-1)
            ),
            AppleAdsCookie(
                name: "XSRF-TOKEN-CM",
                value: "wrong-path",
                path: "/reporting"
            ),
        ] {
            let jar = AppleAdsCookieJar(cookies: [
                AppleAdsCookie(name: "searchads.soid", value: "session"),
                xsrf,
            ])
            var request = URLRequest(url: popularityURL)
            request.applyAppleAdsSession(session, jar: jar)

            #expect(request.value(forHTTPHeaderField: "Cookie") == "searchads.soid=session")
            #expect(request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == nil)
        }
    }

    // MARK: - Session round-trip

    @Test
    func sessionsStoredBeforeTheJarRehydrateFromTheirHeader() {
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=session; XSRF-TOKEN-CM=token",
            xsrfToken: "token",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(session.cookies == nil)
        #expect(
            session.jarCookies.sorted { $0.name < $1.name }.map(\.name)
                == ["XSRF-TOKEN-CM", "searchads.soid"]
        )
        #expect(
            AppleAdsCookieJar(cookies: session.jarCookies).cookieHeader(for: popularityURL)
                == "XSRF-TOKEN-CM=token; searchads.soid=session"
        )
    }

    @Test
    func refreshingKeepsHeaderTokenAndConnectionIdentityInStep() {
        let connectedAt = Date(timeIntervalSince1970: 100)
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=old; XSRF-TOKEN-CM=old-token",
            xsrfToken: "old-token",
            updatedAt: connectedAt
        )

        let refreshed = session.refreshed(with: [
            AppleAdsCookie(name: "XSRF-TOKEN-CM", value: "new-token"),
            AppleAdsCookie(name: "searchads.soid", value: "new")
        ])

        #expect(refreshed.cookieHeader == "XSRF-TOKEN-CM=new-token; searchads.soid=new")
        #expect(refreshed.xsrfToken == "new-token")
        // Rotation is the session working, not the user reconnecting.
        #expect(refreshed.updatedAt == connectedAt)
        #expect(refreshed.connectionIdentity == session.connectionIdentity)
    }

    @Test
    func refreshingWithAnEmptyJarClearsHeaderAndToken() {
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=old; XSRF-TOKEN-CM=old-token",
            xsrfToken: "old-token",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let refreshed = session.refreshed(with: [])

        #expect(refreshed.cookies == [])
        #expect(refreshed.cookieHeader.isEmpty)
        #expect(refreshed.xsrfToken.isEmpty)
        #expect(refreshed.jarCookies.isEmpty)
    }

    // MARK: - Persistence

    @Test
    func rotatedCookiesSurviveARestart() throws {
        let keychain = InMemoryKeychainService()
        let defaults = Self.makeDefaults()
        let store = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        try store.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=original",
                xsrfToken: "token",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        store.cookieJar.merge([AppleAdsCookie(name: "searchads.soid", value: "rotated")])
        store.persistRotatedCookies()

        let reopened = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        #expect(reopened.session?.cookieHeader == "searchads.soid=rotated")
        #expect(reopened.cookieJar.cookieHeader(for: popularityURL) == "searchads.soid=rotated")
    }

    @Test
    func anAuthoritativeEmptyJarSurvivesSerializationAndReload() throws {
        let keychain = InMemoryKeychainService()
        let defaults = Self.makeDefaults()
        let store = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=session; XSRF-TOKEN-CM=token",
            xsrfToken: "token",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.save(session)
        store.cookieJar.merge(session.jarCookies.map {
            AppleAdsCookie(
                name: $0.name,
                value: "deleted",
                domain: $0.domain,
                path: $0.path,
                expiresAt: Date(timeIntervalSince1970: 0)
            )
        })
        store.persistRotatedCookies()

        let reopened = AppleAdsWebSessionStore(defaults: defaults, keychain: keychain)
        var request = URLRequest(url: popularityURL)
        request.applyAppleAdsSession(session, jar: reopened.cookieJar)

        #expect(reopened.session?.cookies == [])
        #expect(reopened.session?.cookieHeader == "")
        #expect(reopened.cookieJar.isEmpty)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-XSRF-TOKEN-CM") == nil)
    }

    /// Rotation is not a reconnect: persisting it must not quietly clear a session Apple has already
    /// asked the user to sign in for again.
    @Test
    func persistingRotationLeavesAPendingReconnectAlone() throws {
        let keychain = InMemoryKeychainService()
        let store = AppleAdsWebSessionStore(defaults: Self.makeDefaults(), keychain: keychain)
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=original",
            xsrfToken: "token",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.save(session)
        store.markReconnectRequired(for: session)

        store.cookieJar.merge([AppleAdsCookie(name: "searchads.soid", value: "rotated")])
        store.persistRotatedCookies()

        #expect(store.requiresReconnect)
        // The caller still holds the pre-rotation value; it must stay recognisable as this session.
        #expect(store.requiresReconnect(for: session))
    }

    @Test
    func disconnectingEmptiesTheJar() throws {
        let store = AppleAdsWebSessionStore(
            defaults: Self.makeDefaults(),
            keychain: InMemoryKeychainService()
        )
        try store.save(
            AppleAdsWebSession(
                cookieHeader: "searchads.soid=session",
                xsrfToken: "token",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        #expect(!store.cookieJar.isEmpty)

        store.clear()

        #expect(store.cookieJar.isEmpty)
    }

    // MARK: - Helpers

    private func jarredSession() -> (session: AppleAdsWebSession, jar: AppleAdsCookieJar) {
        let session = AppleAdsWebSession(
            cookieHeader: "searchads.soid=original; XSRF-TOKEN-CM=token",
            xsrfToken: "token",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        return (session, AppleAdsCookieJar(cookies: session.jarCookies))
    }

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "AppleAdsCookieJarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private final class InMemoryKeychainService: KeychainService {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var storage: [Key: Data] = [:]

    func readData(service: String, account: String) -> KeychainReadResult {
        guard let data = storage[Key(service: service, account: account)] else {
            return .notFound
        }
        return .success(data)
    }

    func save(_ data: Data, service: String, account: String) throws {
        storage[Key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) {
        storage[Key(service: service, account: account)] = nil
    }
}
