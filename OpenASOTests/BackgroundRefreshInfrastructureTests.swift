import Foundation
import LocalAuthentication
import Security
import SwiftData
import Synchronization
import Testing
@testable import OpenASO

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BackgroundRefreshInfrastructureTests {
    @Test
    func commandLineExecutionModesSuppressApplicationUI() {
        let graphical = OpenASOExecutionMode(arguments: ["OpenASO"])
        let mcp = OpenASOExecutionMode(arguments: [
            "OpenASO",
            OpenASOExecutionMode.mcpStdioArgument,
        ])
        let backgroundRefresh = OpenASOExecutionMode(arguments: [
            "OpenASO",
            BackgroundRefreshRuntime.argument,
        ])

        #expect(graphical == .graphical)
        #expect(!graphical.suppressesApplicationUI)
        #expect(mcp == .mcpStdio)
        #expect(mcp.suppressesApplicationUI)
        #expect(backgroundRefresh == .backgroundRefresh)
        #expect(backgroundRefresh.suppressesApplicationUI)
    }

    @Test
    func enablingRegistersTheAgentAndPersistsItsVersion() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {
                    registrationCount += 1
                    serviceStatus = .enabled
                },
                unregister: {
                    serviceStatus = .notRegistered
                },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: true)

        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.lastErrorMessage == nil)
        #expect(registrationCount == 1)

        await controller.reconcile(isEnabled: true)
        #expect(registrationCount == 1)
    }

    @Test
    func anAppUpdateReplacesTheRegisteredAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        var unregistrationCount = 0
        let client = BackgroundRefreshAgentServiceClient(
            status: { serviceStatus },
            register: {
                registrationCount += 1
                serviceStatus = .enabled
            },
            unregister: {
                unregistrationCount += 1
                serviceStatus = .notRegistered
            },
            openSystemSettings: {}
        )

        let firstController = BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "1-10"
        )
        await firstController.reconcile(isEnabled: true)

        let updatedController = BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "1-11"
        )
        await updatedController.reconcile(isEnabled: true)

        #expect(updatedController.status == .enabled)
        #expect(registrationCount == 2)
        #expect(unregistrationCount == 1)
    }

    @Test
    func aRebuildAtTheSameVersionReRegistersTheAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        var unregistrationCount = 0
        let client = BackgroundRefreshAgentServiceClient(
            status: { serviceStatus },
            register: {
                registrationCount += 1
                serviceStatus = .enabled
            },
            unregister: {
                unregistrationCount += 1
                serviceStatus = .notRegistered
            },
            openSystemSettings: {}
        )

        await BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "0.4.2-8+aaaa"
        ).reconcile(isEnabled: true)

        let rebuiltController = BackgroundRefreshAgentController(
            client: client,
            defaults: defaults,
            registrationVersion: "0.4.2-8+bbbb"
        )
        await rebuiltController.reconcile(isEnabled: true)

        #expect(rebuiltController.status == .enabled)
        #expect(registrationCount == 2)
        #expect(unregistrationCount == 1)
    }

    @Test
    func theCodeIdentityTokenIsNonEmptyAndStable() {
        let identity = CodeIdentity.current()

        #expect(!identity.isEmpty)
        #expect(identity == CodeIdentity.current())
    }

    @Test
    func aForcedReconcileReRegistersAnAlreadyEnabledAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        var unregistrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {
                    registrationCount += 1
                    serviceStatus = .enabled
                },
                unregister: {
                    unregistrationCount += 1
                    serviceStatus = .notRegistered
                },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10+identity"
        )

        await controller.reconcile(isEnabled: true)
        await controller.reconcile(isEnabled: true)
        #expect(registrationCount == 1)

        await controller.reconcile(isEnabled: true, force: true)

        #expect(controller.status == .enabled)
        #expect(registrationCount == 2)
        #expect(unregistrationCount == 1)
    }

    @Test
    func aConfirmedStaleAgentIsRepairedAtMostOncePerDay() async {
        let uptime = TestUptimeClock()
        let harness = StaleAgentHarness(uptime: uptime)
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.controller.reconcile(isEnabled: true, now: registeredAt)
        #expect(harness.registrationCount == 1)
        #expect(!harness.controller.isAgentStale(
            now: registeredAt.addingTimeInterval(2 * 60 * 60)
        ))

        // First stale tick only starts the confirmation window.
        let firstStaleAt = registeredAt.addingTimeInterval(4 * 60 * 60)
        #expect(harness.controller.isAgentStale(now: firstStaleAt))
        await harness.controller.repairIfStale(now: firstStaleAt)
        #expect(harness.registrationCount == 1)

        // An hour of awake time is still short of the confirmation window.
        uptime.seconds = 60 * 60
        await harness.controller.repairIfStale(now: firstStaleAt.addingTimeInterval(60 * 60))
        #expect(harness.registrationCount == 1)

        uptime.seconds = 120 * 60
        let repairedAt = firstStaleAt.addingTimeInterval(2 * 60 * 60)
        await harness.controller.repairIfStale(now: repairedAt)
        #expect(harness.registrationCount == 2)

        // Still stale, freshly confirmed, but inside the daily cooldown.
        uptime.seconds = 8 * 60 * 60
        await harness.controller.repairIfStale(now: repairedAt.addingTimeInterval(6 * 60 * 60))
        uptime.seconds = 10 * 60 * 60
        await harness.controller.repairIfStale(now: repairedAt.addingTimeInterval(8 * 60 * 60))
        #expect(harness.registrationCount == 2)

        uptime.seconds = 30 * 60 * 60
        await harness.controller.repairIfStale(now: repairedAt.addingTimeInterval(25 * 60 * 60))
        #expect(harness.registrationCount == 3)
    }

    @Test
    func aHeartbeatArrivingAfterTheFirstStaleTickCancelsTheRepair() async {
        let uptime = TestUptimeClock()
        let harness = StaleAgentHarness(uptime: uptime)
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.controller.reconcile(isEnabled: true, now: registeredAt)

        let firstStaleAt = registeredAt.addingTimeInterval(4 * 60 * 60)
        await harness.controller.repairIfStale(now: firstStaleAt)
        #expect(harness.registrationCount == 1)

        // launchd's catch-up fire lands between two scheduler ticks.
        harness.defaults.set(
            firstStaleAt.addingTimeInterval(60),
            forKey: BackgroundRefreshAgentController.agentWakeDefaultsKey
        )
        uptime.seconds = 60 * 60
        await harness.controller.repairIfStale(now: firstStaleAt.addingTimeInterval(60 * 60))
        #expect(harness.registrationCount == 1)

        // The observation is gone, so even long past the confirmation window nothing is repaired.
        uptime.seconds = 10 * 60 * 60
        await harness.controller.repairIfStale(now: firstStaleAt.addingTimeInterval(10 * 60 * 60))
        #expect(harness.registrationCount == 1)
    }

    @Test
    func anOvernightSleepDoesNotConfirmStaleness() async {
        let uptime = TestUptimeClock()
        let harness = StaleAgentHarness(uptime: uptime)
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        await harness.controller.reconcile(isEnabled: true, now: registeredAt)

        let firstStaleAt = registeredAt.addingTimeInterval(4 * 60 * 60)
        await harness.controller.repairIfStale(now: firstStaleAt)
        #expect(harness.registrationCount == 1)

        // Ten hours of wall clock pass while the Mac is asleep: uptime barely moves.
        uptime.seconds = 5
        await harness.controller.repairIfStale(now: firstStaleAt.addingTimeInterval(10 * 60 * 60))
        #expect(harness.registrationCount == 1)
    }

    @Test
    func aRecentAgentWakeKeepsTheRegistrationHealthy() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.notRegistered
        var registrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {
                    registrationCount += 1
                    serviceStatus = .enabled
                },
                unregister: { serviceStatus = .notRegistered },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10+identity"
        )
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        await controller.reconcile(isEnabled: true, now: registeredAt)

        let now = registeredAt.addingTimeInterval(8 * 60 * 60)
        defaults.set(
            now.addingTimeInterval(-30 * 60),
            forKey: BackgroundRefreshAgentController.agentWakeDefaultsKey
        )
        controller.refreshStatus()

        #expect(!controller.isAgentStale(now: now))
        await controller.repairIfStale(now: now)
        #expect(registrationCount == 1)
    }

    @Test
    func everyOneShotLaunchRecordsAnAgentWakeHeartbeat() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let namespace = AppNamespace(
            bundleIdentifier: "background.refresh.heartbeat.\(UUID().uuidString)"
        )
        let containerURL = try namespace.applicationSupportDirectoryURL()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        AppSettingsStore(defaults: defaults).setAutomaticRefreshEnabled(false)
        let recorder = BackgroundRuntimeOperationRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let exitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now,
            diagnosticSink: .discarding,
            operations: makeBackgroundRuntimeOperations(
                defaults: defaults,
                namespace: namespace,
                recorder: recorder
            )
        )

        #expect(exitCode == 0)
        #expect(recorder.serviceConstructionCount() == 0)
        #expect(
            defaults.object(
                forKey: BackgroundRefreshAgentController.agentWakeDefaultsKey
            ) as? Date == now
        )
    }

    @Test
    func restartingTheInAppSchedulerNeverCancelsAnInFlightRefresh() async {
        let recorder = SchedulerLoopRecorder()
        let refreshStarted = SchedulerTestGate()
        let refreshMayFinish = SchedulerTestGate()
        let secondLoopStarted = SchedulerTestGate()
        let supervisor = InAppDailyRefreshSchedulerSupervisor {
            recorder.loopRuns += 1
            guard recorder.loopRuns == 1, let supervisor = recorder.supervisor else {
                secondLoopStarted.signal()
                return
            }
            await supervisor.withRefreshInFlight {
                supervisor.markRefreshClaimed()
                refreshStarted.signal()
                await refreshMayFinish.wait()
                recorder.refreshWasCancelled = Task.isCancelled
                recorder.finishedRefreshes += 1
            }
        }
        recorder.supervisor = supervisor

        supervisor.start()
        await refreshStarted.wait()
        supervisor.restart()
        #expect(recorder.loopRuns == 1)

        refreshMayFinish.signal()
        await secondLoopStarted.wait()

        #expect(recorder.refreshWasCancelled == false)
        #expect(recorder.finishedRefreshes == 1)
        #expect(recorder.loopRuns == 2)
    }

    @Test
    func restartingDuringAClaimlessFlightReplacesTheLoopPromptly() async {
        let recorder = SchedulerLoopRecorder()
        let flightStarted = SchedulerTestGate()
        let flightMayFinish = SchedulerTestGate()
        let secondLoopStarted = SchedulerTestGate()
        let supervisor = InAppDailyRefreshSchedulerSupervisor {
            recorder.loopRuns += 1
            guard recorder.loopRuns == 1, let supervisor = recorder.supervisor else {
                secondLoopStarted.signal()
                return
            }
            // No claim: the iteration found nothing due, so nothing is lost by replacing the loop.
            await supervisor.withRefreshInFlight {
                flightStarted.signal()
                await flightMayFinish.wait()
            }
            // Stands in for the sleep the loop would otherwise take on the old schedule.
            while !Task.isCancelled {
                await Task.yield()
            }
            recorder.refreshWasCancelled = true
        }
        recorder.supervisor = supervisor

        supervisor.start()
        await flightStarted.wait()
        supervisor.restart()
        #expect(recorder.loopRuns == 1)

        flightMayFinish.signal()
        await secondLoopStarted.wait()

        #expect(recorder.loopRuns == 2)
        #expect(recorder.finishedRefreshes == 0)
    }

    @Test
    func restartingTheInAppSchedulerReplacesAnIdleLoop() async {
        let recorder = SchedulerLoopRecorder()
        let firstLoopStarted = SchedulerTestGate()
        let secondLoopStarted = SchedulerTestGate()
        let supervisor = InAppDailyRefreshSchedulerSupervisor {
            recorder.loopRuns += 1
            guard recorder.loopRuns == 1 else {
                secondLoopStarted.signal()
                return
            }
            firstLoopStarted.signal()
            while !Task.isCancelled {
                await Task.yield()
            }
            recorder.refreshWasCancelled = true
        }

        supervisor.start()
        await firstLoopStarted.wait()
        supervisor.start()
        #expect(recorder.loopRuns == 1)

        supervisor.restart()
        await secondLoopStarted.wait()

        #expect(recorder.loopRuns == 2)
    }

    @Test
    func approvalStateIsExposedWithoutRepeatedRegistrationAttempts() async {
        let defaults = makeBackgroundRefreshDefaults()
        var registrationCount = 0
        var openedSettings = false
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { .requiresApproval },
                register: { registrationCount += 1 },
                unregister: {},
                openSystemSettings: { openedSettings = true }
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: true)
        controller.openSystemSettings()

        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)
        #expect(registrationCount == 0)
        #expect(openedSettings)
    }

    @Test
    func disablingUnregistersAnEnabledAgent() async {
        let defaults = makeBackgroundRefreshDefaults()
        var serviceStatus = BackgroundRefreshAgentStatus.enabled
        var unregistrationCount = 0
        let controller = BackgroundRefreshAgentController(
            client: BackgroundRefreshAgentServiceClient(
                status: { serviceStatus },
                register: {},
                unregister: {
                    unregistrationCount += 1
                    serviceStatus = .notRegistered
                },
                openSystemSettings: {}
            ),
            defaults: defaults,
            registrationVersion: "1-10"
        )

        await controller.reconcile(isEnabled: false)

        #expect(controller.status == .notRegistered)
        #expect(unregistrationCount == 1)
    }

    @Test
    func automaticRefreshDefaultsToFiveAMAndPreservesSavedTimes() {
        let defaults = makeBackgroundRefreshDefaults()
        let newSettings = AppSettingsStore(defaults: defaults)

        #expect(newSettings.refreshHour == 5)
        #expect(newSettings.refreshMinute == 0)

        newSettings.saveRefreshTime(hour: 8, minute: 45)
        let reloadedSettings = AppSettingsStore(defaults: defaults)
        #expect(reloadedSettings.refreshHour == 8)
        #expect(reloadedSettings.refreshMinute == 45)
    }

    @Test
    func backgroundRunResultCanBeReadByANewSettingsStore() {
        let defaults = makeBackgroundRefreshDefaults()
        let scheduledFor = Date(timeIntervalSince1970: 1_800_000_000)
        let finishedAt = scheduledFor.addingTimeInterval(42)
        let record = BackgroundRefreshRunRecord(
            scheduledFor: scheduledFor,
            finishedAt: finishedAt,
            disposition: .failure,
            issueMessage: "Offline"
        )

        AppSettingsStore(defaults: defaults).recordBackgroundRefreshRun(record)
        let reloadedSettings = AppSettingsStore(defaults: defaults)

        #expect(reloadedSettings.lastBackgroundRefreshRun == record)
    }

    @Test
    func oneShotRuntimeClaimsRunsAndCoalescesTheDay() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let uniqueIdentifier = "background.refresh.runtime.tests.\(UUID().uuidString)"
        let namespace = AppNamespace(bundleIdentifier: uniqueIdentifier)
        let applicationSupportURL = try namespace.applicationSupportDirectoryURL()
        let containerURL = applicationSupportURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 8,
            hour: 6
        )))

        let operationRecorder = BackgroundRuntimeOperationRecorder()
        let operations = makeBackgroundRuntimeOperations(
            defaults: defaults,
            namespace: namespace,
            recorder: operationRecorder,
            runRefresh: { services, request in
                await services.runAutomaticHeadlessRefresh(request)
            }
        )
        let firstExitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now,
            calendar: calendar,
            diagnosticSink: .discarding,
            operations: operations
        )
        let settingsAfterFirstRun = AppSettingsStore(defaults: defaults)
        let secondExitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now.addingTimeInterval(60),
            calendar: calendar,
            diagnosticSink: .discarding,
            operations: operations
        )

        #expect(firstExitCode == 0)
        #expect(secondExitCode == 0)
        #expect(settingsAfterFirstRun.hasClaimedAutomaticRefresh(on: now, calendar: calendar))
        #expect(settingsAfterFirstRun.lastBackgroundRefreshRun?.disposition
            == HeadlessRefreshRunDisposition.noWork.rawValue)
        #expect(operationRecorder.serviceConstructionCount() == 1)
        #expect(operationRecorder.refreshCount() == 1)
    }

    @Test
    func keychainReadsTheDataProtectionKeychainBeforeLegacyStorage() {
        var queries: [[String: Any]] = []
        let keychain = SystemKeychainService(copyMatching: { query, _ in
            queries.append(query as NSDictionary as! [String: Any])
            return errSecItemNotFound
        })

        #expect(keychain.readData(service: "service", account: "account") == .notFound)
        #expect(queries.count == 2)
        #expect(queries.first?[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(queries.last?[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test
    func noninteractiveKeychainQueriesDisableAuthenticationUIForReadsWritesAndDeletes() throws {
        let recordedQueries = KeychainQueryRecorder()
        let keychain = SystemKeychainService(
            interactionPolicy: .noninteractive,
            copyMatching: { query, _ in
                recordedQueries.record(query)
                return errSecItemNotFound
            },
            update: { query, _ in
                recordedQueries.record(query)
                return errSecItemNotFound
            },
            add: { query, _ in
                recordedQueries.record(query)
                return errSecSuccess
            },
            delete: { query in
                recordedQueries.record(query)
                return errSecSuccess
            }
        )

        _ = keychain.readData(service: "service", account: "account")
        try keychain.save(Data("value".utf8), service: "service", account: "account")
        keychain.delete(service: "service", account: "account")

        #expect(recordedQueries.values().count == 6)
        #expect(recordedQueries.values().allSatisfy { query in
            guard let context = query[kSecUseAuthenticationContext as String] as? LAContext else {
                return false
            }
            return context.interactionNotAllowed
        })
    }

    @Test
    func transientNoninteractiveReadFailurePreservesTheItemAndReturnsTypedStatus() {
        let counters = KeychainMutationCounters()
        let keychain = SystemKeychainService(
            interactionPolicy: .noninteractive,
            copyMatching: { _, _ in errSecInteractionNotAllowed },
            update: { _, _ in
                counters.recordUpdate()
                return errSecSuccess
            },
            add: { _, _ in
                counters.recordAdd()
                return errSecSuccess
            },
            delete: { _ in
                counters.recordDelete()
                return errSecSuccess
            },
            reportReadFailure: { _ in }
        )

        #expect(keychain.readData(service: "service", account: "account")
            == .failure(.status(errSecInteractionNotAllowed)))
        #expect(counters.snapshot() == .init(updates: 0, adds: 0, deletes: 0))
    }

    @Test
    func disabledNotDueAndAlreadyClaimedRunsNeverConstructServices() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 9,
            hour: 6
        )))

        for expectedKind in [
            BackgroundRefreshRuntimeEvent.Kind.disabled,
            .notDue,
            .alreadyClaimed,
        ] {
            let defaults = makeBackgroundRefreshDefaults()
            let namespace = AppNamespace(
                bundleIdentifier: "background.refresh.skip.\(expectedKind.rawValue).\(UUID().uuidString)"
            )
            let containerURL = try namespace.applicationSupportDirectoryURL()
                .deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: containerURL) }
            let settings = AppSettingsStore(defaults: defaults)
            let now: Date
            switch expectedKind {
            case .disabled:
                settings.setAutomaticRefreshEnabled(false)
                now = day
            case .notDue:
                now = day.addingTimeInterval(-2 * 60 * 60)
            case .alreadyClaimed:
                _ = settings.evaluateAndClaimAutomaticRefresh(at: day, calendar: calendar)
                now = day.addingTimeInterval(60)
            default:
                Issue.record("Unexpected skip kind")
                continue
            }
            let recorder = BackgroundRuntimeOperationRecorder()
            let events = BackgroundRuntimeEventRecorder()
            let exitCode = await BackgroundRefreshRuntime.runOnce(
                defaults: defaults,
                namespace: namespace,
                now: now,
                calendar: calendar,
                diagnosticSink: events.sink,
                operations: makeBackgroundRuntimeOperations(
                    defaults: defaults,
                    namespace: namespace,
                    recorder: recorder
                )
            )

            #expect(exitCode == 0)
            #expect(recorder.serviceConstructionCount() == 0)
            #expect(recorder.refreshCount() == 0)
            #expect(await events.values().contains { $0.kind == expectedKind })
        }
    }

    @Test
    func lockBusyRunLogsAndReturnsWithoutClaimOrServiceConstruction() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let namespace = AppNamespace(
            bundleIdentifier: "background.refresh.lock-busy.\(UUID().uuidString)"
        )
        let containerURL = try namespace.applicationSupportDirectoryURL()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let gate = BackgroundRefreshLockGate()
        let heldLock = CrossProcessFileLock(
            namespace: namespace,
            fileName: BackgroundRefreshRuntime.dailyLockFileName
        )
        let holder = Task {
            try await heldLock.attempt {
                await gate.hold()
                return true
            }
        }
        await gate.waitUntilHeld()
        let recorder = BackgroundRuntimeOperationRecorder()
        let events = BackgroundRuntimeEventRecorder()

        let exitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            diagnosticSink: events.sink,
            operations: makeBackgroundRuntimeOperations(
                defaults: defaults,
                namespace: namespace,
                recorder: recorder
            )
        )
        await gate.release()
        _ = try await holder.value

        #expect(exitCode == 0)
        #expect(recorder.serviceConstructionCount() == 0)
        #expect(await events.values().contains { $0.kind == .lockUnavailable })
        #expect(!AppSettingsStore(defaults: defaults).hasClaimedAutomaticRefresh(
            on: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    @Test
    func runtimeTerminalEventUsesExactDispositionExitMapping() async throws {
        let cases: [(HeadlessRefreshRunDisposition, Int32)] = [
            (.noWork, 0),
            (.success, 0),
            (.partialFailure, 0),
            (.skippedAlreadyRunning, 0),
            (.failure, 1),
            (.cancelled, 1),
            (.rejectedRequestConflict, 1),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 10,
            hour: 6
        )))

        for (disposition, expectedExitCode) in cases {
            let defaults = makeBackgroundRefreshDefaults()
            let namespace = AppNamespace(
                bundleIdentifier: "background.refresh.exit.\(disposition.rawValue).\(UUID().uuidString)"
            )
            let containerURL = try namespace.applicationSupportDirectoryURL()
                .deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: containerURL) }
            let events = BackgroundRuntimeEventRecorder()
            let operations = makeBackgroundRuntimeOperations(
                defaults: defaults,
                namespace: namespace,
                recorder: BackgroundRuntimeOperationRecorder(),
                runRefresh: { _, request in
                    makeBackgroundSummary(request: request, disposition: disposition)
                }
            )

            let exitCode = await BackgroundRefreshRuntime.runOnce(
                defaults: defaults,
                namespace: namespace,
                now: now,
                calendar: calendar,
                diagnosticSink: events.sink,
                operations: operations,
                buildIdentity: .init(shortVersion: "test", buildVersion: "1")
            )
            let terminal = await events.values().last { $0.kind == .terminal }

            #expect(exitCode == expectedExitCode)
            #expect(terminal?.exitCode == expectedExitCode)
            #expect(terminal?.disposition == disposition)
            #expect(terminal?.origin == .oneShot)
            #expect(terminal?.buildIdentity == .init(shortVersion: "test", buildVersion: "1"))
            #expect(terminal?.redactedLogMessage.contains("exitCode=\(expectedExitCode)") == true)
        }
    }

    @Test
    func cooperativeDeadlineCancellationPersistsTimeoutAndReturnsNonzero() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let namespace = AppNamespace(
            bundleIdentifier: "background.refresh.cooperative-timeout.\(UUID().uuidString)"
        )
        let containerURL = try namespace.applicationSupportDirectoryURL()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let events = BackgroundRuntimeEventRecorder()
        let operations = makeBackgroundRuntimeOperations(
            defaults: defaults,
            namespace: namespace,
            recorder: BackgroundRuntimeOperationRecorder(),
            runRefresh: { _, request in
                do {
                    try await Task.sleep(for: .seconds(60))
                    return makeBackgroundSummary(request: request, disposition: .success)
                } catch {
                    return makeBackgroundSummary(request: request, disposition: .cancelled)
                }
            }
        )

        let (now, calendar) = backgroundDueInstant()
        let exitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: now,
            calendar: calendar,
            diagnosticSink: events.sink,
            operations: operations,
            deadlinePolicy: BackgroundRefreshDeadlinePolicy(
                budget: 0,
                cleanupGrace: 1,
                sleep: { _ in }
            )
        )
        let store = AppSettingsStore(defaults: defaults)

        #expect(exitCode == 1)
        #expect(store.lastBackgroundRefreshRun?.diagnostics.contains {
            $0.reasonCode == .timedOut
        } == true)
        #expect(store.activeBackgroundRefreshAttempt?.lastPhase
            == BackgroundRefreshRuntimePhase.timedOut.rawValue)
        #expect(await events.values().contains { $0.kind == .timedOut })
    }

    @Test
    func uncooperativeDependencyReturnsAfterCleanupGraceAndCanBeReleased() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let namespace = AppNamespace(
            bundleIdentifier: "background.refresh.uncooperative-timeout.\(UUID().uuidString)"
        )
        let containerURL = try namespace.applicationSupportDirectoryURL()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let gate = UncooperativeRefreshGate()
        let operations = makeBackgroundRuntimeOperations(
            defaults: defaults,
            namespace: namespace,
            recorder: BackgroundRuntimeOperationRecorder(),
            runRefresh: { _, request in
                await gate.wait(request: request)
            }
        )
        let deadlinePolicy = BackgroundRefreshDeadlinePolicy(
            budget: 1,
            cleanupGrace: 1,
            sleep: { _ in await gate.waitUntilStarted() }
        )

        let (now, calendar) = backgroundDueInstant()
        let task = Task { @MainActor in
            await BackgroundRefreshRuntime.runOnce(
                defaults: defaults,
                namespace: namespace,
                now: now,
                calendar: calendar,
                diagnosticSink: .discarding,
                operations: operations,
                deadlinePolicy: deadlinePolicy
            )
        }
        await gate.waitUntilStarted()
        let exitCode = await task.value
        await gate.release()

        #expect(exitCode == 1)
        #expect(AppSettingsStore(defaults: defaults).activeBackgroundRefreshAttempt?.lastPhase
            == BackgroundRefreshRuntimePhase.timedOut.rawValue)
    }

    @Test
    func independentWatchdogFiresExactlyOnceAndReportsLastSafePhase() {
        let scheduler = WatchdogSchedulerHarness()
        let output = WatchdogOutputRecorder()
        let watchdog = OneShotProcessWatchdog(scheduler: scheduler.schedule)

        watchdog.start(
            after: 10,
            lastPhase: { .serviceInitialization },
            write: output.write,
            terminate: output.terminate
        )
        scheduler.fire()
        scheduler.fire()
        watchdog.cancel()

        #expect(output.messages() == [
            "Background refresh watchdog fired phase=serviceInitialization exitCode=1",
        ])
        #expect(output.exitCodes() == [1])
        #expect(scheduler.cancellationCount() == 1)
    }

    @Test
    func leftoverAttemptIsReportedWhileItsClaimPreventsASecondProviderRun() async throws {
        let defaults = makeBackgroundRefreshDefaults()
        let namespace = AppNamespace(
            bundleIdentifier: "background.refresh.interrupted.\(UUID().uuidString)"
        )
        let containerURL = try namespace.applicationSupportDirectoryURL()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let oldRunID = UUID()
        let (claimedAt, calendar) = backgroundDueInstant()
        let store = AppSettingsStore(defaults: defaults)
        store.recordActiveBackgroundRefreshAttempt(BackgroundRefreshActiveAttemptRecord(
            runID: oldRunID,
            claimedAt: claimedAt,
            scheduledFor: claimedAt,
            lastPhase: BackgroundRefreshRuntimePhase.databaseOpen.rawValue,
            executionOrigin: .oneShot,
            buildIdentity: .init(shortVersion: "old", buildVersion: "1")
        ))
        _ = store.evaluateAndClaimAutomaticRefresh(at: claimedAt, calendar: calendar)
        let recorder = BackgroundRuntimeOperationRecorder()
        let events = BackgroundRuntimeEventRecorder()

        let exitCode = await BackgroundRefreshRuntime.runOnce(
            defaults: defaults,
            namespace: namespace,
            now: claimedAt.addingTimeInterval(60),
            calendar: calendar,
            diagnosticSink: events.sink,
            operations: makeBackgroundRuntimeOperations(
                defaults: defaults,
                namespace: namespace,
                recorder: recorder
            )
        )

        #expect(exitCode == 0)
        #expect(await events.values().contains { $0.kind == .interruptedAttemptFound })
        #expect(await events.values().contains { $0.kind == .alreadyClaimed })
        #expect(recorder.serviceConstructionCount() == 0)
        #expect(AppSettingsStore(defaults: defaults).activeBackgroundRefreshAttempt?.runID == oldRunID)
        #expect(AppSettingsStore(defaults: defaults).hasClaimedAutomaticRefresh(
            on: claimedAt,
            calendar: calendar
        ))
    }

    @Test
    func crossProcessLockRejectsAConcurrentAttempt() async throws {
        let uniqueIdentifier = "background.refresh.lock.tests.\(UUID().uuidString)"
        let namespace = AppNamespace(bundleIdentifier: uniqueIdentifier)
        let applicationSupportURL = try namespace.applicationSupportDirectoryURL()
        let containerURL = applicationSupportURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: containerURL) }

        let lock = CrossProcessFileLock(namespace: namespace, fileName: "daily.lock")
        let gate = BackgroundRefreshLockGate()
        let firstAttempt = Task {
            try await lock.attempt {
                await gate.hold()
                return "first"
            }
        }

        await gate.waitUntilHeld()
        let concurrentAttempt = try await lock.attempt { "second" }
        switch concurrentAttempt {
        case .acquired:
            Issue.record("A second attempt acquired a lock that was already held")
        case .unavailable:
            break
        }

        await gate.release()
        let firstResult = try await firstAttempt.value
        switch firstResult {
        case .acquired(let value):
            #expect(value == "first")
        case .unavailable:
            Issue.record("The first attempt did not acquire the lock")
        }

        let laterAttempt = try await lock.attempt { "later" }
        switch laterAttempt {
        case .acquired(let value):
            #expect(value == "later")
        case .unavailable:
            Issue.record("The lock was not released after the first operation")
        }
    }

    @Test
    func oneShotBudgetCoversAMeasuredSingleAppRefresh() {
        // 2026-09-22: one tracked app, ~400 keywords across storefronts, 28 minutes wall clock.
        // 2026-09-23: the 15-minute budget then killed a healthy launchd run mid-refresh.
        #expect(BackgroundRefreshDeadlinePolicy.defaultBudget >= 45 * 60)
        #expect(BackgroundRefreshDeadlinePolicy.defaultBudget <= 60 * 60)
    }

    @Test
    func oneShotLogFileAppendsTimestampedLinesAndRotatesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-log.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logFile = OneShotRefreshLogFile(
            url: directory.appendingPathComponent("refresh-agent.log", isDirectory: false),
            maximumBytes: 80
        )
        let stamp = Date(timeIntervalSince1970: 1_000_000)

        logFile.append("first", at: stamp)
        logFile.append("second", at: stamp)
        let initial = try String(contentsOf: logFile.url, encoding: .utf8)
        #expect(initial == "1970-01-12T13:46:40.000Z first\n1970-01-12T13:46:40.000Z second\n")
        #expect(!FileManager.default.fileExists(atPath: logFile.previousURL.path))

        logFile.append("third", at: stamp)
        logFile.append("fourth", at: stamp)
        let current = try String(contentsOf: logFile.url, encoding: .utf8)
        let previous = try String(contentsOf: logFile.previousURL, encoding: .utf8)
        #expect(current == "1970-01-12T13:46:40.000Z fourth\n")
        #expect(previous.hasSuffix("third\n"))
        #expect(previous.split(separator: "\n").count == 3)
    }

    @Test
    func oneShotSinkWritesTheRedactedEventToTheLogFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-log.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logFile = OneShotRefreshLogFile(
            url: directory.appendingPathComponent("refresh-agent.log", isDirectory: false)
        )
        let event = BackgroundRefreshRuntimeEvent(
            kind: .timedOut,
            runID: UUID(),
            phase: .timedOut,
            timestamp: .now,
            durationMilliseconds: nil,
            plannedAppCount: nil,
            completedAppCount: nil,
            exitCode: 1,
            disposition: .failure,
            origin: .oneShot,
            buildIdentity: .init(shortVersion: "0.4.2", buildVersion: "8")
        )

        await BackgroundRefreshDiagnosticSink.oneShot(logFile: logFile).record(event)

        let contents = try String(contentsOf: logFile.url, encoding: .utf8)
        #expect(contents.hasSuffix(" \(event.redactedLogMessage)\n"))
        #expect(contents.contains("phase=timedOut"))
    }
}

private extension BackgroundRefreshDiagnosticSink {
    static let discarding = Self { _ in }
}

/// A scriptable stand-in for `ProcessInfo.systemUptime`, which does not advance while asleep.
private final class TestUptimeClock: Sendable {
    private let state = Mutex<TimeInterval>(0)

    var seconds: TimeInterval {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@MainActor
private final class AgentServiceFake {
    var status = BackgroundRefreshAgentStatus.notRegistered
    var registrations = 0
    var unregistrations = 0

    var client: BackgroundRefreshAgentServiceClient {
        BackgroundRefreshAgentServiceClient(
            status: { self.status },
            register: {
                self.registrations += 1
                self.status = .enabled
            },
            unregister: {
                self.unregistrations += 1
                self.status = .notRegistered
            },
            openSystemSettings: {}
        )
    }
}

@MainActor
private final class StaleAgentHarness {
    let defaults: UserDefaults
    let service: AgentServiceFake
    let controller: BackgroundRefreshAgentController

    var registrationCount: Int { service.registrations }

    init(uptime: TestUptimeClock) {
        let defaults = makeBackgroundRefreshDefaults()
        let service = AgentServiceFake()
        self.defaults = defaults
        self.service = service
        controller = BackgroundRefreshAgentController(
            client: service.client,
            defaults: defaults,
            registrationVersion: "1-10+identity",
            uptime: { uptime.seconds }
        )
    }
}

@MainActor
private final class SchedulerLoopRecorder {
    var loopRuns = 0
    var finishedRefreshes = 0
    var refreshWasCancelled = false
    /// The loop body needs the supervisor that owns it, which only exists after the loop closure.
    var supervisor: InAppDailyRefreshSchedulerSupervisor?
}

/// A one-shot latch for driving the scheduler supervisor deterministically from the main actor.
@MainActor
private final class SchedulerTestGate {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let resumable = waiters
        waiters.removeAll()
        resumable.forEach { $0.resume() }
    }

    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class BackgroundRuntimeOperationRecorder: Sendable {
    private struct State {
        var modelOpenCount = 0
        var serviceConstructionCount = 0
        var refreshCount = 0
    }

    private let state = Mutex(State())

    func recordModelOpen() {
        state.withLock { $0.modelOpenCount += 1 }
    }

    func recordServiceConstruction() {
        state.withLock { $0.serviceConstructionCount += 1 }
    }

    func recordRefresh() {
        state.withLock { $0.refreshCount += 1 }
    }

    func serviceConstructionCount() -> Int {
        state.withLock(\.serviceConstructionCount)
    }

    func refreshCount() -> Int {
        state.withLock(\.refreshCount)
    }
}

@MainActor
private func makeBackgroundRuntimeOperations(
    defaults: UserDefaults,
    namespace: AppNamespace,
    recorder: BackgroundRuntimeOperationRecorder,
    runRefresh: (@MainActor @Sendable (AppServices, HeadlessRefreshRunRequest) async -> HeadlessRefreshRunSummary)? = nil
) -> BackgroundRefreshRuntimeOperations {
    BackgroundRefreshRuntimeOperations(
        openModelContainer: { _ in
            recorder.recordModelOpen()
            return try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: true)
        },
        makeServices: { suppliedDefaults, suppliedNamespace, container in
            recorder.recordServiceConstruction()
            #expect(suppliedDefaults === defaults)
            #expect(suppliedNamespace.bundleIdentifier == namespace.bundleIdentifier)
            return AppServices.backgroundRefresh(
                defaults: suppliedDefaults,
                namespace: suppliedNamespace,
                keychain: InMemoryKeychainService(),
                httpClient: MockHTTPClient { request in
                    Issue.record("Unexpected provider request to \(request.url?.absoluteString ?? "unknown URL")")
                    throw URLError(.unsupportedURL)
                },
                modelContainer: container
            )
        },
        prepareModelStore: { _ in },
        runRefresh: { services, request in
            recorder.recordRefresh()
            if let runRefresh {
                return await runRefresh(services, request)
            }
            return makeBackgroundSummary(request: request, disposition: .noWork)
        }
    )
}

private actor BackgroundRuntimeEventRecorder {
    private var events: [BackgroundRefreshRuntimeEvent] = []

    nonisolated var sink: BackgroundRefreshDiagnosticSink {
        BackgroundRefreshDiagnosticSink { event in
            await self.record(event)
        }
    }

    func record(_ event: BackgroundRefreshRuntimeEvent) {
        events.append(event)
    }

    func values() -> [BackgroundRefreshRuntimeEvent] {
        events
    }
}

private func makeBackgroundSummary(
    request: HeadlessRefreshRunRequest,
    disposition: HeadlessRefreshRunDisposition
) -> HeadlessRefreshRunSummary {
    let completed = disposition == .noWork ? 0 : 1
    let successful = disposition == .success ? 1 : 0
    let partial = disposition == .partialFailure ? 1 : 0
    let failed = disposition == .failure ? 1 : 0
    return HeadlessRefreshRunSummary(
        runID: request.id,
        activeRunID: nil,
        scheduledFor: request.scheduledFor,
        startedAt: request.scheduledFor,
        finishedAt: request.scheduledFor.addingTimeInterval(1),
        disposition: disposition,
        plannedAppCount: completed,
        completedAppCount: completed,
        successfulAppCount: successful,
        partialFailureAppCount: partial,
        failedAppCount: failed,
        issue: [.failure, .partialFailure].contains(disposition)
            ? HeadlessRefreshIssue(kind: .appRefreshFailed)
            : nil
    )
}

private final class KeychainQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [[String: Any]] = []

    func record(_ query: CFDictionary) {
        lock.withLock {
            queries.append(query as NSDictionary as! [String: Any])
        }
    }

    func values() -> [[String: Any]] {
        lock.withLock { queries }
    }
}

private final class KeychainMutationCounters: Sendable {
    struct Snapshot: Equatable {
        let updates: Int
        let adds: Int
        let deletes: Int
    }

    private let state = Mutex(Snapshot(updates: 0, adds: 0, deletes: 0))

    func recordUpdate() {
        state.withLock { $0 = Snapshot(updates: $0.updates + 1, adds: $0.adds, deletes: $0.deletes) }
    }

    func recordAdd() {
        state.withLock { $0 = Snapshot(updates: $0.updates, adds: $0.adds + 1, deletes: $0.deletes) }
    }

    func recordDelete() {
        state.withLock { $0 = Snapshot(updates: $0.updates, adds: $0.adds, deletes: $0.deletes + 1) }
    }

    func snapshot() -> Snapshot {
        state.withLock { $0 }
    }
}

private actor UncooperativeRefreshGate {
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshContinuation: CheckedContinuation<HeadlessRefreshRunSummary, Never>?
    private var request: HeadlessRefreshRunRequest?

    func wait(request: HeadlessRefreshRunRequest) async -> HeadlessRefreshRunSummary {
        self.request = request
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard let request, let refreshContinuation else { return }
        self.refreshContinuation = nil
        refreshContinuation.resume(returning: makeBackgroundSummary(
            request: request,
            disposition: .cancelled
        ))
    }
}

private final class WatchdogSchedulerHarness: Sendable {
    private struct State {
        var action: (@Sendable () -> Void)?
        var cancellationCount = 0
    }

    private let state = Mutex(State())

    func schedule(
        _ delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> OneShotProcessWatchdog.Cancellation {
        #expect(delay == 10)
        state.withLock { $0.action = action }
        return { [weak self] in
            self?.state.withLock { $0.cancellationCount += 1 }
        }
    }

    func fire() {
        state.withLock { $0.action }?()
    }

    func cancellationCount() -> Int {
        state.withLock(\.cancellationCount)
    }
}

private final class WatchdogOutputRecorder: Sendable {
    private struct State {
        var messages: [String] = []
        var exitCodes: [Int32] = []
    }

    private let state = Mutex(State())

    func write(_ message: String) {
        state.withLock { $0.messages.append(message) }
    }

    func terminate(_ exitCode: Int32) {
        state.withLock { $0.exitCodes.append(exitCode) }
    }

    func messages() -> [String] {
        state.withLock(\.messages)
    }

    func exitCodes() -> [Int32] {
        state.withLock(\.exitCodes)
    }
}

private actor BackgroundRefreshLockGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        let waiters = heldWaiters
        heldWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func makeBackgroundRefreshDefaults() -> UserDefaults {
    let suiteName = "background.refresh.infrastructure.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func backgroundDueInstant() -> (Date, Calendar) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 8,
        day: 11,
        hour: 6
    ))!
    return (date, calendar)
}
