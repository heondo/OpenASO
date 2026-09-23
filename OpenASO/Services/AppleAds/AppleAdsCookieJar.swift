import Foundation
import Synchronization

/// One Apple Ads cookie, in a form that round-trips through the Keychain-stored web session.
struct AppleAdsCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?

    init(
        name: String,
        value: String,
        domain: String = AppleAdsSessionCookies.host,
        path: String = "/",
        expiresAt: Date? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain.lowercased()
        self.path = path.isEmpty ? "/" : path
        self.expiresAt = expiresAt
    }

    init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate
        )
    }

    /// Apple hands most of the Ads session out as session cookies, which carry no expiry. Outliving
    /// the process is the entire point of persisting the jar, so a missing expiry is never "expired".
    func hasExpired(asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    func applies(to url: URL) -> Bool {
        guard let host = url.host?.lowercased(), Self.domain(domain, matches: host) else {
            return false
        }
        return Self.path(path, matches: url.path.isEmpty ? "/" : url.path)
    }

    /// RFC 6265 domain matching, minus the public-suffix rules Apple's single host never exercises.
    static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalized = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == normalized || host.hasSuffix(".\(normalized)")
    }

    /// RFC 6265 path matching: an exact hit, or a prefix that stops on a path boundary.
    static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        if cookiePath == requestPath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }
}

/// The Apple Ads cookie jar: the single source of truth for what goes in a `Cookie:` header.
///
/// Apple Ads rotates its session cookies as the account is used. OpenASO used to freeze one
/// `Cookie:` string at sign-in and replay it forever, and — worse — `URLSession.shared` quietly
/// overwrote that header with whatever `HTTPCookieStorage.shared` happened to hold for the host,
/// including cookies left behind by an earlier sign-in that reconnecting never cleared. That is why
/// a session could look expired minutes after a successful connect, and why signing in again did
/// not help.
///
/// Requests now opt out of Foundation's shared storage entirely (`httpShouldHandleCookies = false`)
/// and read from this jar, while every response's `Set-Cookie` is merged back in so rotation is
/// followed rather than fought.
final class AppleAdsCookieJar: Sendable {
    private struct Identity: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: AppleAdsCookie) {
            name = cookie.name
            domain = cookie.domain
            path = cookie.path
        }
    }

    private struct State {
        var cookies: [Identity: AppleAdsCookie] = [:]
        /// Whether the jar holds rotation the persisted session has not caught up with yet.
        var hasUnsavedRotation = false
    }

    private let state: Mutex<State>

    init(cookies: [AppleAdsCookie] = []) {
        state = Mutex(State(cookies: Self.indexed(cookies)))
    }

    var isEmpty: Bool {
        state.withLock { $0.cookies.isEmpty }
    }

    var hasUnsavedRotation: Bool {
        state.withLock { $0.hasUnsavedRotation }
    }

    /// Reseeds the jar from a persisted session. Seeding is not rotation, so it leaves the jar clean.
    func replaceAll(with cookies: [AppleAdsCookie]) {
        state.withLock {
            $0.cookies = Self.indexed(cookies)
            $0.hasUnsavedRotation = false
        }
    }

    func removeAll() {
        state.withLock {
            $0.cookies = [:]
            $0.hasUnsavedRotation = false
        }
    }

    func snapshot() -> [AppleAdsCookie] {
        state.withLock { Self.sorted($0.cookies.values) }
    }

    /// Records that the current contents have been written back to the session store.
    func markPersisted() {
        state.withLock { $0.hasUnsavedRotation = false }
    }

    func value(forCookieNamed name: String, applicableTo url: URL, asOf now: Date = .now) -> String? {
        state.withLock { state in
            Self.sorted(state.cookies.values).first {
                $0.name == name && !$0.hasExpired(asOf: now) && $0.applies(to: url)
            }?.value
        }
    }

    func cookieHeader(for url: URL, asOf now: Date = .now) -> String {
        state.withLock { state in
            Self.sorted(state.cookies.values)
                .filter { !$0.hasExpired(asOf: now) && $0.applies(to: url) }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        }
    }

    /// Merges a response's `Set-Cookie` headers.
    ///
    /// Worth doing even on a 401: the failure response is also how Apple tells us which cookies it
    /// just retired.
    @discardableResult
    func ingest(response: HTTPURLResponse, asOf now: Date = .now) -> Bool {
        guard let url = response.url else { return false }

        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String, let value = entry.value as? String else { return }
            result[name] = value
        }

        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        return merge(parsed.map(AppleAdsCookie.init), asOf: now)
    }

    /// A `Set-Cookie` whose expiry has already passed is a deletion, not a value.
    @discardableResult
    func merge(_ incoming: [AppleAdsCookie], asOf now: Date = .now) -> Bool {
        guard !incoming.isEmpty else { return false }

        return state.withLock { state in
            var didChange = false
            for cookie in incoming {
                let identity = Identity(cookie)
                if cookie.hasExpired(asOf: now) {
                    didChange = state.cookies.removeValue(forKey: identity) != nil || didChange
                } else if state.cookies[identity] != cookie {
                    state.cookies[identity] = cookie
                    didChange = true
                }
            }
            state.hasUnsavedRotation = state.hasUnsavedRotation || didChange
            return didChange
        }
    }

    private static func indexed(_ cookies: [AppleAdsCookie]) -> [Identity: AppleAdsCookie] {
        Dictionary(cookies.map { (Identity($0), $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func sorted(_ cookies: some Collection<AppleAdsCookie>) -> [AppleAdsCookie] {
        cookies.sorted {
            if $0.name == $1.name {
                return $0.path < $1.path
            }
            return $0.name < $1.name
        }
    }
}

extension URLRequest {
    /// Attaches Apple Ads session state from the jar.
    ///
    /// `httpShouldHandleCookies = false` is the load-bearing line. Left at its default of `true`,
    /// URLSession replaces the `Cookie` header set here with whatever `HTTPCookieStorage.shared`
    /// holds for the host — storage that accumulates across sign-ins and that reconnecting never
    /// clears.
    mutating func applyAppleAdsSession(_ session: AppleAdsWebSession, jar: AppleAdsCookieJar) {
        httpShouldHandleCookies = false

        let header = url.map { jar.cookieHeader(for: $0) } ?? ""
        setValue(header.isEmpty ? nil : header, forHTTPHeaderField: "Cookie")
        // Modern sessions (`app-ads.sid`) carry no XSRF token; an empty header would be a lie.
        let xsrfToken = url.flatMap {
            jar.value(forCookieNamed: AppleAdsSessionCookies.xsrfToken, applicableTo: $0)
        }
        setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN-CM")
    }
}
