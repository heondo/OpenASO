import Foundation
import Testing
@testable import OpenASO

@MainActor
struct AnalyticsServiceTests {
    @Test
    func oldBackgroundRefreshRecordDecodesWithoutDiagnosticsOrProvenance() throws {
        let data = Data("""
        {
          "scheduledFor": 10,
          "finishedAt": 20,
          "disposition": "partialFailure",
          "plannedAppCount": 1,
          "completedAppCount": 1,
          "successfulAppCount": 0,
          "partialFailureAppCount": 1,
          "failedAppCount": 0,
          "issueMessage": "One app could not complete its automatic refresh."
        }
        """.utf8)

        let record = try JSONDecoder().decode(BackgroundRefreshRunRecord.self, from: data)

        #expect(record.runID == nil)
        #expect(record.executionOrigin == nil)
        #expect(record.buildIdentity == nil)
        #expect(record.diagnostics.isEmpty)
        #expect(record.partialFailureAppCount == 1)
    }

    @Test
    func backgroundRefreshRecordRoundTripsDiagnosticsAndProvenance() throws {
        let runID = UUID()
        let diagnostic = HeadlessRefreshDiagnostic(
            appStoreID: 6_761_003_558,
            stage: .metadata,
            provider: .appStoreWeb,
            storefront: "US",
            severity: .failure,
            reasonCode: .validationFailed
        )
        let summary = HeadlessRefreshRunSummary(
            runID: runID,
            activeRunID: nil,
            scheduledFor: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 101),
            finishedAt: Date(timeIntervalSince1970: 102),
            disposition: .partialFailure,
            plannedAppCount: 1,
            completedAppCount: 1,
            successfulAppCount: 0,
            partialFailureAppCount: 1,
            failedAppCount: 0,
            issue: HeadlessRefreshIssue(kind: .appRefreshFailed),
            diagnostics: [diagnostic]
        )
        let record = BackgroundRefreshRunRecord(
            summary: summary,
            executionOrigin: .oneShot,
            buildIdentity: .init(shortVersion: "2.0", buildVersion: "99")
        )

        let decoded = try JSONDecoder().decode(
            BackgroundRefreshRunRecord.self,
            from: JSONEncoder().encode(record)
        )

        #expect(decoded == record)
        #expect(decoded.runID == runID)
        #expect(decoded.executionOrigin == .oneShot)
        #expect(decoded.buildIdentity == .init(shortVersion: "2.0", buildVersion: "99"))
        #expect(decoded.diagnostics == [diagnostic])
    }

    @Test
    func activeAttemptPersistenceRemainsSeparateFromCompletedRun() {
        let defaults = UserDefaults(suiteName: "background-attempt-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        let completed = BackgroundRefreshRunRecord(
            scheduledFor: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 110),
            disposition: .success,
            issueMessage: "completed"
        )
        let attempt = BackgroundRefreshActiveAttemptRecord(
            runID: UUID(),
            claimedAt: Date(timeIntervalSince1970: 200),
            scheduledFor: Date(timeIntervalSince1970: 190),
            lastPhase: BackgroundRefreshRuntimePhase.databaseOpen.rawValue,
            executionOrigin: .oneShot,
            buildIdentity: .init(shortVersion: "2.0", buildVersion: "100")
        )

        store.recordBackgroundRefreshRun(completed)
        store.recordActiveBackgroundRefreshAttempt(attempt)
        let reopened = AppSettingsStore(defaults: defaults)

        #expect(reopened.lastBackgroundRefreshRun == completed)
        #expect(reopened.activeBackgroundRefreshAttempt == attempt)
        reopened.clearActiveBackgroundRefreshAttempt(runID: attempt.runID)
        #expect(reopened.activeBackgroundRefreshAttempt == nil)
        #expect(reopened.lastBackgroundRefreshRun == completed)
    }

    @Test
    func settingsStoreUsesConfiguredAnalyticsDefaultAndPersistsChanges() {
        let defaults = UserDefaults(suiteName: "analytics-settings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)

        #expect(store.isAnalyticsEnabled == AppSettingsStore.defaultIsAnalyticsEnabled)

        store.setAnalyticsEnabled(true)
        #expect(AppSettingsStore(defaults: defaults).isAnalyticsEnabled)

        store.setAnalyticsEnabled(false)
        #expect(!store.isAnalyticsEnabled)
        #expect(!AppSettingsStore(defaults: defaults).isAnalyticsEnabled)
    }

    @Test
    func settingsStoreShowsMenuBarIconByDefaultAndPersistsChanges() {
        let defaults = UserDefaults(suiteName: "menu-bar-settings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)

        #expect(store.showsMenuBarIcon == AppSettingsStore.defaultShowsMenuBarIcon)
        #expect(store.showsMenuBarIcon)

        store.setShowsMenuBarIcon(false)
        #expect(!store.showsMenuBarIcon)
        // Hiding it must survive a relaunch, or the icon comes back every launch.
        #expect(!AppSettingsStore(defaults: defaults).showsMenuBarIcon)

        store.setShowsMenuBarIcon(true)
        #expect(AppSettingsStore(defaults: defaults).showsMenuBarIcon)
    }

    @Test
    func settingsStorePersistsAndNormalizesMCPServerPort() {
        let defaults = UserDefaults(suiteName: "mcp-port-settings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)

        #expect(store.mcpServerPort == MCPServerPort.defaultValue)

        store.saveMCPServerPort(52_345)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == 52_345)

        store.saveMCPServerPort(1)
        #expect(store.mcpServerPort == MCPServerPort.minimum)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == MCPServerPort.minimum)

        store.saveMCPServerPort(70_000)
        #expect(store.mcpServerPort == MCPServerPort.maximum)
        #expect(AppSettingsStore(defaults: defaults).mcpServerPort == MCPServerPort.maximum)
    }

    @Test
    func disabledAnalyticsNoOpsAndUpdatesOptOut() {
        let defaults = UserDefaults(suiteName: "analytics-disabled-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.setAnalyticsEnabled(false)
        service.capture(.keywordDeleted(deleteCount: 3))

        #expect(client.optOutStates == [!AppSettingsStore.defaultIsAnalyticsEnabled, true])
        #expect(client.events.map(\.name) == [])
    }

    @Test
    func enabledAnalyticsCapturesEventsDirectly() {
        let defaults = UserDefaults(suiteName: "analytics-enabled-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        store.setAnalyticsEnabled(true)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.capture(.keywordDeleted(deleteCount: 3))
        service.capture(AnalyticsEvent(name: "keyword_deleted", properties: ["keyword": "private"]))

        #expect(client.events.count == 2)
        #expect(client.events.first?.name == "keyword_deleted")
        #expect(client.events.first?.properties["delete_count_bucket"] as? String == "2-5")
        #expect(client.events.last?.properties["keyword"] as? String == "private")
    }

    @Test
    func enablingAnalyticsCapturesPreferenceChange() {
        let defaults = UserDefaults(suiteName: "analytics-preference-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        let client = RecordingAnalyticsClient()
        let service = AnalyticsService(settingsStore: store, client: client)

        service.setAnalyticsEnabled(true)

        #expect(client.optOutStates == [!AppSettingsStore.defaultIsAnalyticsEnabled, false])
        #expect(client.events.first?.name == "analytics_preference_changed")
        #expect(client.events.first?.properties["enabled"] as? Bool == true)
    }
}

@MainActor
private final class RecordingAnalyticsClient: AnalyticsClient {
    private(set) var events: [(name: String, properties: [String: Any])] = []
    private(set) var optOutStates: [Bool] = []

    func capture(name: String, properties: [String: Any]) {
        events.append((name, properties))
    }

    func setOptOut(_ isOptedOut: Bool) {
        optOutStates.append(isOptedOut)
    }
}
