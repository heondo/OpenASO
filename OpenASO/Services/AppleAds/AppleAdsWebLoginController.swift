import AppKit
import Foundation
import OSLog
import WebKit

/// Names of the cookies Apple Ads hands out once a browser session is signed in and usable.
enum AppleAdsSessionCookies {
    static let host = "app-ads.apple.com"
    static let xsrfToken = "XSRF-TOKEN-CM"
    static let session = "searchads.soid"
    /// Apple's newer authenticated-session cookie. Recent sign-ins issue this alongside
    /// `searchads.soid` and no longer hand out `XSRF-TOKEN-CM` up front, so a session is usable
    /// with either the legacy token or this cookie.
    static let authenticatedSession = "app-ads.sid"
}

struct AppleAdsWebLoginCapture: Equatable, Sendable {
    var cookieHeader: String
    var xsrfToken: String
    var accountName: String?
    /// The cookies behind `cookieHeader`, attributes intact, so the jar starts out knowing each
    /// cookie's domain, path, and expiry rather than inferring them.
    var cookies: [AppleAdsCookie] = []
}

@MainActor
protocol AppleAdsWebLoginCapturing: AnyObject {
    func captureSession(
        credentials: AppleAdsWebLoginCredentials?,
        timeout: Duration
    ) async throws -> AppleAdsWebLoginCapture
}

enum AppleAdsWebLoginError: LocalizedError, Equatable {
    case closedBeforeCapture
    case explicitAccountRequired
    case wrongAccount(signedIn: String, expected: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .closedBeforeCapture:
            return "The Apple Ads sign-in window closed before OpenASO captured the session."
        case .explicitAccountRequired:
            return "OpenASO will not use the Mac's default Apple Account. Try again, choose Use a Different Apple Account if Apple asks, then enter the Apple ID you want OpenASO to use."
        case let .wrongAccount(signedIn, expected):
            return "Apple signed in as \(signedIn), but OpenASO's saved Apple ID is \(expected). Sign out of \(signedIn) in the window, or update the saved Apple ID in Settings."
        case .timedOut:
            return "Timed out waiting for Apple Ads sign-in. Sign in and finish 2FA in the window, then try again."
        }
    }
}

/// Masks an Apple ID for display in errors and logs: enough to recognise the account, not enough to
/// leak it wholesale into a log file the user may share.
enum AppleAdsAccountMask {
    static func mask(_ account: String) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@") else {
            return redactLocalPart(String(trimmed))
        }
        let local = String(trimmed[trimmed.startIndex ..< atIndex])
        let domain = String(trimmed[atIndex...])
        return redactLocalPart(local) + domain
    }

    private static func redactLocalPart(_ local: String) -> String {
        guard local.count > 2 else { return local.isEmpty ? "an unknown account" : "\(local.prefix(1))\u{2022}\u{2022}\u{2022}" }
        return "\(local.prefix(1))\u{2022}\u{2022}\u{2022}\(local.suffix(1))"
    }
}

/// Signs in to Apple Ads in an in-app WebKit window and captures the resulting web session.
///
/// WebKit is the same engine Safari uses, so Apple ID sign-in, 2FA, and passkeys behave the way
/// they do in a normal browser. The session cookies land in the web view's cookie store, which is
/// the only browser cookie jar a macOS app can legitimately read.
@MainActor
final class AppleAdsWebLoginController: NSObject, AppleAdsWebLoginCapturing {
    static let signInURL = URL(string: "https://app-ads.apple.com/")!

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "apple-ads-login")
    private static let pollInterval = Duration.milliseconds(500)
    private static let accountNameTimeout = Duration.seconds(5)
    private static let explicitAccountMessageHandler = "openASOExplicitAccount"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var didCloseWindow = false
    /// Whether an account was picked deliberately — typed, autofilled into the field, or filled from
    /// the saved credentials — as opposed to Apple silently reusing the Mac's Apple Account.
    private var didUseExplicitAccount = false
    /// The Apple ID Apple actually signed in, when the page revealed it. Held in memory for the
    /// duration of one capture and never persisted.
    private var observedAccount: String?

    /// Presents the sign-in window and resolves once Apple Ads has handed out a usable session.
    ///
    /// Every step is bounded: the sign-in wait ends at `timeout`, the window closing ends the wait
    /// immediately, and the optional account-name lookup has its own deadline. The caller never
    /// waits on an unbounded operation.
    func captureSession(
        credentials: AppleAdsWebLoginCredentials? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> AppleAdsWebLoginCapture {
        let webView = presentWindow(credentials: credentials)
        defer { dismissWindow() }

        // Drop the previous Apple Ads session before loading, so a stale `searchads.soid` cannot
        // satisfy capture the instant the window opens. Apple's own sign-in cookies stay put — they
        // are what keeps this Mac a trusted browser and this session long-lived.
        await Self.clearAppleAdsSessionCookies(in: webView.configuration.websiteDataStore)

        webView.load(URLRequest(url: Self.signInURL))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            try Task.checkCancellation()

            if didCloseWindow {
                throw AppleAdsWebLoginError.closedBeforeCapture
            }

            if let capture = await capturedSession(from: webView) {
                try verifyCapturedAccount(expecting: credentials?.trimmed)
                Self.logger.info("Captured Apple Ads web session from the in-app sign-in window.")
                return capture
            }

            try await Task.sleep(for: Self.pollInterval)
        }

        throw AppleAdsWebLoginError.timedOut
    }

    private func capturedSession(from webView: WKWebView) async -> AppleAdsWebLoginCapture? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let appleAdsCookies = cookies.filter(Self.appliesToAppleAds)

        guard Self.isCaptureReady(url: webView.url, cookies: appleAdsCookies) else {
            logCookiesIfChanged(appleAdsCookies, url: webView.url)
            return nil
        }

        return AppleAdsWebLoginCapture(
            cookieHeader: Self.cookieHeader(from: appleAdsCookies),
            xsrfToken: appleAdsCookies.first { $0.name == AppleAdsSessionCookies.xsrfToken }?.value ?? "",
            accountName: await accountName(from: webView),
            cookies: appleAdsCookies
                .map(AppleAdsCookie.init)
                .sorted { $0.name == $1.name ? $0.path < $1.path : $0.name < $1.name }
        )
    }

    /// A session is usable once Apple has issued `searchads.soid` together with either the legacy
    /// `XSRF-TOKEN-CM` or the newer `app-ads.sid`. The page URL is not part of the decision: those
    /// cookies only exist after a completed sign-in, whatever path Apple happens to land on.
    nonisolated static func isCaptureReady(url: URL?, cookies: [HTTPCookie]) -> Bool {
        guard url != nil,
              cookies.contains(where: { $0.name == AppleAdsSessionCookies.session })
        else {
            return false
        }

        return cookies.contains { cookie in
            [AppleAdsSessionCookies.xsrfToken, AppleAdsSessionCookies.authenticatedSession]
                .contains(cookie.name)
        }
    }

    private var lastLoggedCookieState = ""

    /// Records which Apple Ads cookies the window holds while capture is still waiting, so a sign-in
    /// that never completes can be diagnosed from the log instead of a spinner. Cookie names only.
    private func logCookiesIfChanged(_ cookies: [HTTPCookie], url: URL?) {
        let names = cookies.map(\.name).sorted().joined(separator: ",")
        let state = "\(url?.host ?? "-")\(url?.path ?? "") [\(names)]"
        guard state != lastLoggedCookieState else { return }
        lastLoggedCookieState = state
        Self.logger.notice("Apple Ads sign-in waiting; page and cookies: \(state, privacy: .public)")
    }

    /// Decides whether the captured session belongs to the account the user asked for.
    ///
    /// This deliberately replaces an earlier keystroke test. Requiring a keystroke rejected every
    /// legitimate sign-in that does not involve typing — a passkey, Touch ID, Keychain autofill, or
    /// an Apple session this Mac is already trusted for — so a successful sign-in was captured and
    /// then thrown away. What actually matters is *which* account came back, not how it got here.
    private func verifyCapturedAccount(expecting credentials: AppleAdsWebLoginCredentials?) throws {
        let expected = credentials?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let comparableObserved = observedAccount.flatMap(Self.comparableAccount)

        if !expected.isEmpty,
           let comparableObserved,
           let comparableExpected = Self.comparableAccount(expected),
           comparableObserved != comparableExpected {
            throw AppleAdsWebLoginError.wrongAccount(
                signedIn: AppleAdsAccountMask.mask(observedAccount ?? ""),
                expected: AppleAdsAccountMask.mask(expected)
            )
        }

        // Either the account matched, or the user picked one we could not read back. Both are the
        // user's own choice; only a silent reuse of the Mac's Apple Account is not.
        if observedAccount != nil || didUseExplicitAccount { return }

        // A saved Apple ID is itself an explicit choice. When Apple reuses the trusted-browser
        // session this Mac earned on an earlier connect, the page never shows an account field, so
        // neither signal above fires. The person still chose which account to use, and the
        // platform-account handoff is already suppressed at the source by the policy script.
        if !expected.isEmpty { return }

        throw AppleAdsWebLoginError.explicitAccountRequired
    }

    /// Normalises an Apple ID for comparison, or returns `nil` when Apple only showed a masked form
    /// such as `h\u{2022}\u{2022}\u{2022}@icloud.com`, which cannot be compared against anything.
    nonisolated static func comparableAccount(_ account: String) -> String? {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let maskCharacters = CharacterSet(charactersIn: "\u{2022}*\u{2026}")
        guard trimmed.rangeOfCharacter(from: maskCharacters) == nil else { return nil }
        return trimmed
    }

    /// The app's own persistent WebKit store.
    ///
    /// Apple hands a short-lived session to a browser it does not recognise. An ephemeral store made
    /// every connect look like a brand-new browser, which is why sessions died in about a day. A
    /// store keyed to OpenASO keeps Apple's trusted-browser cookie across launches while staying
    /// isolated from Safari and from `HTTPCookieStorage.shared`.
    private static let dataStoreIdentifier = UUID(uuidString: "4B1D9F62-0C3A-4E88-9E2E-0A7F5D6C21B4")!

    static func makeDataStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
    }

    /// Removes only the Apple Ads session cookies, leaving Apple's sign-in cookies in place.
    static func clearAppleAdsSessionCookies(in store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore
        for cookie in await cookieStore.allCookies() where appliesToAppleAds(cookie) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    /// Wipes the whole store, trusted-browser cookie included. For an explicit disconnect, where the
    /// point is that the next sign-in starts from nothing.
    static func clearPersistedLoginData() async {
        await makeDataStore().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    nonisolated static func appliesToAppleAds(_ cookie: HTTPCookie) -> Bool {
        let host = AppleAdsSessionCookies.host
        let domain = cookie.domain.lowercased()
        let matchesDomain: Bool
        if domain.hasPrefix(".") {
            matchesDomain = host == String(domain.dropFirst()) || host.hasSuffix(domain)
        } else {
            matchesDomain = domain == host
        }

        guard matchesDomain else { return false }

        let path = cookie.path.isEmpty ? "/" : cookie.path
        return path == "/" || "/".hasPrefix(path)
    }

    nonisolated static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .sorted {
                if $0.name == $1.name {
                    return $0.path < $1.path
                }
                return $0.name < $1.name
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    nonisolated static func isAuthenticatedAppleAdsPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == AppleAdsSessionCookies.host else {
            return false
        }

        let location = [url.path, url.query]
            .compactMap(\.self)
            .joined(separator: "?")
            .lowercased()
        return !["/auth/", "/authenticate", "/login", "/sign-in", "/signin"].contains {
            location.contains($0)
        }
    }

    /// Reads the account label from the signed-in page. Best effort: a missing name only costs the
    /// last-resort seller lookup, so a slow or wedged renderer must not stall the connect flow.
    private func accountName(from webView: WKWebView) async -> String? {
        let script = """
        (function () {
          var text = (document.body && document.body.innerText) || "";
          var ignored = ["Recommendations", "Terms of Service", "Privacy Policy"];
          var lines = text.split(/\\n+/);
          for (var index = 0; index < lines.length; index += 1) {
            var line = lines[index].trim();
            if (!line) continue;
            if (ignored.indexOf(line) !== -1) continue;
            if (/^copyright\\b/i.test(line)) continue;
            return line;
          }
          return "";
        })();
        """

        let name = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resolver = SingleResume(continuation: continuation)
            webView.evaluateJavaScript(script) { value, _ in
                resolver.resume(with: value as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.accountNameTimeout)
                resolver.resume(with: nil)
            }
        }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func presentWindow(credentials: AppleAdsWebLoginCredentials?) -> WKWebView {
        if let webView, window != nil {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        // Persistent and app-private: Apple's trusted-browser cookie has to outlive the process for
        // the Ads session to be long-lived. `captureSession` clears the previous Apple Ads cookies
        // before loading, so a stale session still cannot satisfy capture early.
        configuration.websiteDataStore = Self.makeDataStore()
        configuration.userContentController.add(
            self,
            name: Self.explicitAccountMessageHandler
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: AppleAdsWebLoginAutomation.explicitAccountPolicyScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        if let script = AppleAdsWebLoginAutomation.script(for: credentials) {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false
                )
            )
        }

        let contentSize = AppleAdsWebLoginWindowLayout.contentSize(
            for: NSScreen.main?.visibleFrame
        )
        let frame = NSRect(origin: .zero, size: contentSize)
        let webView = WKWebView(frame: frame, configuration: configuration)
        // Apple's alternate-account sign-in occasionally leaves its account widget blank when
        // it identifies the client as an embedded WebKit view. Use Safari's public browser
        // identity while retaining the isolated WKWebsiteDataStore and cookie capture.
        webView.customUserAgent = AppleAdsWebLoginBrowser.safariUserAgent()
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Apple Ads Sign In"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.webView = webView
        self.window = window
        didCloseWindow = false
        didUseExplicitAccount = false
        observedAccount = nil
        return webView
    }

    private func dismissWindow() {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.explicitAccountMessageHandler
        )
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }
}

enum AppleAdsWebLoginBrowser {
    static func safariUserAgent(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        // Safari 18 ships with macOS 15. Apple aligned Safari's major version with macOS when
        // macOS moved to version 26, so preserve the correct identity across our deployment range.
        let safariMajorVersion = operatingSystemVersion.majorVersion >= 26
            ? operatingSystemVersion.majorVersion
            : operatingSystemVersion.majorVersion + 3
        let version = "\(safariMajorVersion).\(operatingSystemVersion.minorVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Safari/605.1.15"
    }
}

enum AppleAdsWebLoginWindowLayout {
    private static let idealSize = NSSize(width: 1_060, height: 820)
    private static let screenMargin: CGFloat = 48

    static func contentSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return idealSize }
        return NSSize(
            width: min(idealSize.width, max(1, visibleFrame.width - screenMargin)),
            height: min(idealSize.height, max(1, visibleFrame.height - screenMargin))
        )
    }
}

/// Generates a document-local helper that fills the optional saved login on Apple-owned sign-in
/// pages. The script is installed only in the ephemeral WebKit view used for this capture attempt.
enum AppleAdsWebLoginAutomation {
    /// Prevents Apple-owned sign-in pages from silently requesting the Mac's platform credential.
    /// The Apple ID field also marks that a specific account was explicitly selected without
    /// exposing its value to native code.
    static let explicitAccountPolicyScript = """
    (() => {
      const host = window.location.hostname.toLowerCase();
      const isAppleOwned = host === "apple.com" || host.endsWith(".apple.com");
      if (!isAppleOwned || host === "app-ads.apple.com" || window.__openasoExplicitAccountPolicy) return;
      window.__openasoExplicitAccountPolicy = true;

      const report = (payload) => {
        try {
          window.webkit?.messageHandlers?.openASOExplicitAccount?.postMessage(payload);
        } catch (_) {}
      };

      // 1. Keep Apple's native "use the Apple Account on this Mac" widget switched off.
      //
      // Patching the #embed_login_boot_args element alone is a race Apple can win: the element is
      // read by an inline script in the same task it is appended, while a MutationObserver callback
      // only runs at the following microtask checkpoint. Intercepting JSON.parse is synchronous and
      // catches the read whenever it happens.
      const scrub = (configuration) => {
        if (!configuration || typeof configuration !== "object") return configuration;
        const direct = configuration.direct;
        if (direct && typeof direct === "object" && "enableTiburonInd" in direct) {
          direct.enableTiburonInd = false;
        }
        return configuration;
      };
      const nativeParse = JSON.parse;
      JSON.parse = function (...parseArguments) {
        return scrub(nativeParse.apply(this, parseArguments));
      };

      const patchBootArguments = () => {
        const bootArguments = document.querySelector("#embed_login_boot_args");
        if (!bootArguments || bootArguments.dataset.openasoPatched === "true") return;
        try {
          const configuration = nativeParse(bootArguments.textContent || "{}");
          if (!configuration.direct) return;
          configuration.direct.enableTiburonInd = false;
          bootArguments.textContent = JSON.stringify(configuration);
          bootArguments.dataset.openasoPatched = "true";
        } catch (_) {}
      };

      // 2. Refuse the silent credential handoff.
      //
      // Conditional and silent mediation is how the page signs in as the Mac's Apple Account with no
      // prompt at all. An explicit, user-initiated passkey still works.
      const credentialStore = navigator.credentials;
      if (credentialStore && typeof credentialStore.get === "function") {
        const nativeGet = credentialStore.get.bind(credentialStore);
        credentialStore.get = (options) => {
          const mediation = options && options.mediation;
          if (mediation === "conditional" || mediation === "silent") {
            return Promise.reject(new DOMException("Suppressed by OpenASO", "NotAllowedError"));
          }
          return nativeGet(options);
        };
      }

      // 3. Ask Apple for a session that outlives the day.
      //
      // Apple only issues a long-lived session when "Keep me signed in" is on. Tick it once, the
      // moment it renders; if the person signing in unticks it, it stays unticked. Submission is
      // always theirs.
      const enableRememberMe = () => {
        const box = document.querySelector(
          "input#remember-me, input[name='rememberMe'], input[type='checkbox'][id*='remember' i]"
        );
        if (!box || box.dataset.openasoChecked === "true") return;
        box.dataset.openasoChecked = "true";
        if (!box.checked) box.click();
      };

      // 4. Record which account is being used.
      //
      // Native code compares this against the saved Apple ID. Polling the field value rather than
      // listening for keystrokes is what makes autofill, Keychain fill, and paste all count.
      const accountPattern = /account|email|apple.?id|username|phone/;
      const isAccountField = (element) => {
        if (!(element instanceof HTMLInputElement)) return false;
        if (element.type === "password") return false;
        const identity = [
          element.id,
          element.name,
          element.type,
          element.autocomplete,
          element.placeholder
        ].join(" ").toLowerCase();
        return accountPattern.test(identity);
      };

      const markExplicitAccount = () => {
        if (window.__openasoExplicitAccountSelected) return;
        window.__openasoExplicitAccountSelected = true;
        report({ kind: "selected" });
      };
      window.__openasoMarkExplicitAccount = markExplicitAccount;

      const reportAccount = () => {
        for (const field of document.querySelectorAll("input")) {
          if (!isAccountField(field)) continue;
          const value = (field.value || "").trim();
          if (!value || value === window.__openasoReportedAccount) continue;
          window.__openasoReportedAccount = value;
          markExplicitAccount();
          report({ kind: "account", account: value });
        }
      };

      document.addEventListener("input", (event) => {
        if (isAccountField(event.target)) markExplicitAccount();
      }, true);

      const tick = () => {
        patchBootArguments();
        enableRememberMe();
        reportAccount();
      };
      tick();
      new MutationObserver(tick)
        .observe(document.documentElement || document, { childList: true, subtree: true });
      document.addEventListener("DOMContentLoaded", tick, { once: true });
      window.setInterval(tick, 500);
    })();
    """

    static func script(for credentials: AppleAdsWebLoginCredentials?) -> String? {
        guard let credentials = credentials?.trimmed, credentials.isComplete,
              let data = try? JSONEncoder().encode(credentials),
              let encodedCredentials = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return """
        (() => {
          const host = window.location.hostname.toLowerCase();
          const isAppleOwned = host === "apple.com" || host.endsWith(".apple.com");
          if (!isAppleOwned || host === "app-ads.apple.com" || window.__openasoLoginActive) return;
          window.__openasoLoginActive = true;

          const credentials = \(encodedCredentials);
          const visible = (element) => {
            if (!element || element.disabled) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none"
              && rect.width > 0 && rect.height > 0;
          };
          const firstVisible = (selectors) => {
            for (const selector of selectors) {
              const element = document.querySelector(selector);
              if (visible(element)) return element;
            }
            return null;
          };
          const fill = (element, value) => {
            if (!element) return false;
            const setter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype,
              "value"
            )?.set;
            if (setter) setter.call(element, value); else element.value = value;
            element.dispatchEvent(new Event("input", { bubbles: true }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
            return true;
          };
          const clickButton = (labels, selectors = []) => {
            const selected = firstVisible(selectors);
            if (selected) { selected.click(); return true; }
            const buttons = Array.from(document.querySelectorAll("button, [role='button']"));
            const button = buttons.find((candidate) =>
              visible(candidate) && labels.includes((candidate.innerText || candidate.textContent || "").trim())
            );
            if (!button) return false;
            button.click();
            return true;
          };

          let usernameSubmitted = false;
          let passwordFilled = false;
          const tick = () => {
            if (passwordFilled) return;

            const username = firstVisible([
              "input#account_name_text_field",
              "input[name='accountName']",
              "input[type='email']",
              "input[autocomplete*='username']",
              "input[placeholder*='Apple']"
            ]);
            if (!usernameSubmitted && username && fill(username, credentials.username)) {
              window.__openasoMarkExplicitAccount?.();
              usernameSubmitted = clickButton(
                ["Continue", "Next"],
                ["button#sign-in", "button[type='submit']"]
              );
              return;
            }

            const password = firstVisible([
              "input#password_text_field",
              "input[name='password']",
              "input[type='password']",
              "input[autocomplete='current-password']"
            ]);
            if (password && fill(password, credentials.password)) {
              // Deliberately leave the final submission to the person signing in. Apple's
              // "Remember me" control can appear or update only after the password field is
              // populated; clicking submit here made it impossible to opt out before login.
              passwordFilled = true;
            }
          };

          tick();
          const timer = window.setInterval(tick, 250);
          window.setTimeout(() => window.clearInterval(timer), 120000);
        })();
        """
    }
}

extension AppleAdsWebLoginController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        didCloseWindow = true
    }
}

extension AppleAdsWebLoginController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.explicitAccountMessageHandler else { return }

        guard let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String
        else {
            // Older payload shape: a bare "selected" string.
            if message.body as? String == "selected" { didUseExplicitAccount = true }
            return
        }

        switch kind {
        case "selected":
            didUseExplicitAccount = true
        case "account":
            didUseExplicitAccount = true
            let account = (payload["account"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !account.isEmpty { observedAccount = account }
        default:
            break
        }
    }
}

/// Resumes a continuation exactly once, whichever of the racing callbacks arrives first.
@MainActor
private final class SingleResume {
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
