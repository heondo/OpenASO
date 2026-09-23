import Foundation
import Observation
import OSLog
import Security
import ServiceManagement

enum BackgroundRefreshAgentStatus: String, Hashable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

@MainActor
struct BackgroundRefreshAgentServiceClient {
    let status: () -> BackgroundRefreshAgentStatus
    let register: () throws -> Void
    let unregister: () async throws -> Void
    let openSystemSettings: () -> Void

    static func live(plistName: String) -> Self {
        let service = SMAppService.agent(plistName: plistName)
        return Self(
            status: {
                switch service.status {
                case .enabled:
                    .enabled
                case .requiresApproval:
                    .requiresApproval
                case .notFound:
                    .notFound
                case .notRegistered:
                    .notRegistered
                @unknown default:
                    .notFound
                }
            },
            register: {
                try service.register()
            },
            unregister: {
                try await withCheckedThrowingContinuation { continuation in
                    service.unregister { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            },
            openSystemSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }
}

/// Identifies the executable image behind the running process.
///
/// launchd pins an `SMAppService` registration to the code identity that was present when
/// `register()` ran, so a rebuild installed over the same app version leaves behind a record it can
/// no longer spawn (`xpcproxy` exits 78). Keying the saved registration on this token instead of on
/// the version alone makes the first launch of a replaced build repair the registration.
enum CodeIdentity {
    static func current(bundle: Bundle = .main) -> String {
        codeDirectoryHashHex() ?? executableModificationToken(bundle: bundle) ?? "unknown"
    }

    private static func codeDirectoryHashHex() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let entries = information as? [String: Any],
            let hash = entries[kSecCodeInfoUnique as String] as? Data,
            !hash.isEmpty
        else {
            return nil
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Unsigned and unreadable images still change on disk when they are replaced, so the
    /// executable's modification time is enough to notice a swapped build.
    private static func executableModificationToken(bundle: Bundle) -> String? {
        guard let executableURL = bundle.executableURL,
              let attributes = try? FileManager.default
                  .attributesOfItem(atPath: executableURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }

        return "mtime\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

@MainActor
@Observable
final class BackgroundRefreshAgentController {
    /// Written by the one-shot agent process at the top of every launch. The UI process reads it to
    /// tell an agent that launchd actually spawns from one that only reports `.enabled`.
    nonisolated static let agentWakeDefaultsKey = "dailyRefresh.lastAgentWakeAt"

    /// How long an `.enabled` registration may go without a launch before it is treated as broken.
    /// launchd fires the agent hourly, so three hours is several missed launches.
    static let agentHealthWindow: TimeInterval = 3 * 60 * 60
    private static let agentRepairInterval: TimeInterval = 24 * 60 * 60

    /// How much *awake* time staleness must persist before it is believed. A Mac that slept through
    /// the night looks stale for one tick — the scheduler's sleep advances across system sleep while
    /// launchd's coalesced calendar fire has not landed yet — and a repair there would re-register a
    /// perfectly healthy agent, with the "Background Items Added" notification that comes with it.
    private static let staleConfirmationInterval: TimeInterval = 90 * 60

    private enum DefaultsKey {
        static let registeredVersion = "dailyRefresh.agentRegisteredVersion"
        static let registeredAt = "dailyRefresh.agentRegisteredAt"
        static let lastAgentWakeAt = BackgroundRefreshAgentController.agentWakeDefaultsKey
        static let lastAgentRepairAt = "dailyRefresh.lastAgentRepairAt"
    }

    private let client: BackgroundRefreshAgentServiceClient
    private let defaults: UserDefaults
    private let registrationVersion: String
    private let redactedAppLocation: String
    private let uptime: () -> TimeInterval
    private let diagnosticLog: @Sendable (String) -> Void

    /// Sleep-excluding timestamp of the first tick that saw the agent stale, cleared as soon as it
    /// looks healthy again. In memory on purpose: a relaunch starts the confirmation over.
    private var staleFirstObservedUptime: TimeInterval?

    private(set) var status: BackgroundRefreshAgentStatus
    private(set) var isReconciling = false
    private(set) var lastErrorMessage: String?
    private(set) var registeredAt: Date?
    private(set) var lastAgentWakeAt: Date?

    var isEnabled: Bool {
        status == .enabled
    }

    convenience init(
        defaults: UserDefaults = .openASOShared,
        bundle: Bundle = .main
    ) {
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.thirdtech.openaso"
        let plistName = "\(bundleIdentifier).refresh-agent.plist"
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "0"
        let codeIdentity = CodeIdentity.current(bundle: bundle)
        self.init(
            client: .live(plistName: plistName),
            defaults: defaults,
            registrationVersion: "\(shortVersion)-\(buildVersion)+\(codeIdentity)",
            redactedAppLocation: bundle.bundleURL.lastPathComponent
        )
    }

    init(
        client: BackgroundRefreshAgentServiceClient,
        defaults: UserDefaults,
        registrationVersion: String,
        redactedAppLocation: String = "unknown",
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        diagnosticLog: @escaping @Sendable (String) -> Void = { message in
            OpenASOLog.refresh.info("\(message, privacy: .public)")
        }
    ) {
        self.client = client
        self.defaults = defaults
        self.registrationVersion = registrationVersion
        self.redactedAppLocation = String(redactedAppLocation.prefix(128))
        self.uptime = uptime
        self.diagnosticLog = diagnosticLog
        status = client.status()
        registeredAt = defaults.object(forKey: DefaultsKey.registeredAt) as? Date
        lastAgentWakeAt = defaults.object(forKey: DefaultsKey.lastAgentWakeAt) as? Date
    }

    func refreshStatus() {
        status = client.status()
        registeredAt = defaults.object(forKey: DefaultsKey.registeredAt) as? Date
        lastAgentWakeAt = defaults.object(forKey: DefaultsKey.lastAgentWakeAt) as? Date
    }

    /// True when the registration claims to be enabled but the agent has not actually launched for
    /// long enough that launchd would have fired it several times.
    func isAgentStale(now: Date = .now) -> Bool {
        guard status == .enabled, let registeredAt else { return false }
        guard now.timeIntervalSince(registeredAt) > Self.agentHealthWindow else { return false }
        guard let lastAgentWakeAt else { return true }
        return now.timeIntervalSince(lastAgentWakeAt) > Self.agentHealthWindow
    }

    /// Re-registers a registration that launchd is silently refusing to spawn, once staleness has
    /// held for long enough of *awake* time to rule out a sleeping Mac, and at most once a day so a
    /// genuinely broken install does not churn the login-items database.
    func repairIfStale(now: Date = .now) async {
        // A reconcile already in flight would swallow the forced one and waste the daily budget.
        guard !isReconciling else { return }
        refreshStatus()
        guard isAgentStale(now: now) else {
            staleFirstObservedUptime = nil
            return
        }

        let currentUptime = uptime()
        guard let staleFirstObservedUptime else {
            self.staleFirstObservedUptime = currentUptime
            return
        }
        guard currentUptime - staleFirstObservedUptime >= Self.staleConfirmationInterval else {
            return
        }

        if let lastRepairAt = defaults.object(forKey: DefaultsKey.lastAgentRepairAt) as? Date,
           now.timeIntervalSince(lastRepairAt) < Self.agentRepairInterval {
            return
        }

        defaults.set(now, forKey: DefaultsKey.lastAgentRepairAt)
        diagnosticLog(
            "Background agent looks stale app=\(redactedAppLocation) versionBuild=\(registrationVersion) registeredAt=\(registeredAt?.timeIntervalSince1970 ?? 0) lastWakeAt=\(lastAgentWakeAt?.timeIntervalSince1970 ?? 0) forcing re-registration"
        )
        await reconcile(isEnabled: true, force: true, now: now)
        self.staleFirstObservedUptime = nil
    }

    func reconcile(isEnabled: Bool, force: Bool = false, now: Date = .now) async {
        guard !isReconciling else { return }
        isReconciling = true
        lastErrorMessage = nil
        diagnosticLog(
            "Background agent reconcile started app=\(redactedAppLocation) versionBuild=\(registrationVersion) requestedEnabled=\(isEnabled) force=\(force) status=\(status.rawValue)"
        )
        defer {
            refreshStatus()
            isReconciling = false
            diagnosticLog(
                "Background agent reconcile finished app=\(redactedAppLocation) versionBuild=\(registrationVersion) status=\(status.rawValue) error=\(lastErrorMessage == nil ? "none" : "present")"
            )
        }

        do {
            refreshStatus()
            if !isEnabled {
                if status == .enabled || status == .requiresApproval {
                    try await client.unregister()
                }
                defaults.removeObject(forKey: DefaultsKey.registeredVersion)
                defaults.removeObject(forKey: DefaultsKey.registeredAt)
                registeredAt = nil
                return
            }

            let savedVersion = defaults.string(forKey: DefaultsKey.registeredVersion)
            if !force, status == .enabled, savedVersion == registrationVersion {
                return
            }

            if status == .enabled {
                try await client.unregister()
            }

            refreshStatus()
            if status == .notRegistered || status == .notFound {
                try client.register()
                defaults.set(registrationVersion, forKey: DefaultsKey.registeredVersion)
                defaults.set(now, forKey: DefaultsKey.registeredAt)
                registeredAt = now
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        client.openSystemSettings()
    }
}
