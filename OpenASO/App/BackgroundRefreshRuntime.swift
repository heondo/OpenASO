import Dispatch
import Foundation
import OSLog
import SwiftData
import Synchronization

enum BackgroundRefreshRuntimePhase: String, Codable, Hashable, Sendable {
    case starting
    case claiming
    case databaseOpen
    case serviceInitialization
    case modelStorePreparation
    case planningAndApps
    case cleanup
    case finished
    case timedOut
}

struct BackgroundRefreshRuntimeEvent: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case started
        case phaseStarted
        case phaseFinished
        case disabled
        case notDue
        case alreadyClaimed
        case lockUnavailable
        case interruptedAttemptFound
        case timedOut
        case terminal
    }

    let kind: Kind
    let runID: UUID
    let phase: BackgroundRefreshRuntimePhase?
    let timestamp: Date
    let durationMilliseconds: Int?
    let plannedAppCount: Int?
    let completedAppCount: Int?
    let exitCode: Int32?
    let disposition: HeadlessRefreshRunDisposition?
    let origin: BackgroundRefreshRunRecord.ExecutionOrigin
    let buildIdentity: BackgroundRefreshRunRecord.BuildIdentity

    var redactedLogMessage: String {
        var fields = [
            "Background refresh \(kind.rawValue)",
            "runID=\(runID.uuidString)",
            "origin=\(origin.rawValue)",
            "version=\(buildIdentity.shortVersion)",
            "build=\(buildIdentity.buildVersion)",
        ]
        if let phase { fields.append("phase=\(phase.rawValue)") }
        if let durationMilliseconds { fields.append("durationMs=\(durationMilliseconds)") }
        if let plannedAppCount { fields.append("planned=\(plannedAppCount)") }
        if let completedAppCount { fields.append("completed=\(completedAppCount)") }
        if let disposition { fields.append("disposition=\(disposition.rawValue)") }
        if let exitCode { fields.append("exitCode=\(exitCode)") }
        return fields.joined(separator: " ")
    }
}

struct BackgroundRefreshDiagnosticSink: Sendable {
    let record: @Sendable (BackgroundRefreshRuntimeEvent) async -> Void

    static let liveOneShot = oneShot(logFile: .live())

    static func oneShot(logFile: OneShotRefreshLogFile?) -> Self {
        Self { event in
            OneShotRefreshLog.emit(event.redactedLogMessage, logFile: logFile)
        }
    }
}

/// Every diagnostic line the one-shot produces goes to three places, because each one alone has
/// lost a run's evidence before: launchd discards stderr unless the agent plist names an absolute
/// log path (unknowable at build time), and the unified log only keeps `.notice` and above on disk
/// once the process has exited.
enum OneShotRefreshLog {
    static func emit(_ message: String, logFile: OneShotRefreshLogFile?) {
        OpenASOLog.refresh.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        logFile?.append(message)
    }
}

/// Append-only log next to the daily lock in the namespace's Application Support directory.
/// It rotates once to `refresh-agent.log.previous` when it outgrows `maximumBytes`, so the two
/// files together bound disk use while always keeping the most recent run readable.
struct OneShotRefreshLogFile: Sendable {
    static let fileName = "refresh-agent.log"
    static let defaultMaximumBytes = 1_048_576

    let url: URL
    let maximumBytes: Int

    init(url: URL, maximumBytes: Int = Self.defaultMaximumBytes) {
        self.url = url
        self.maximumBytes = max(1, maximumBytes)
    }

    static func live(namespace: AppNamespace = .current) -> OneShotRefreshLogFile? {
        guard let directory = try? namespace.applicationSupportDirectoryURL() else { return nil }
        return OneShotRefreshLogFile(
            url: directory.appendingPathComponent(fileName, isDirectory: false)
        )
    }

    var previousURL: URL {
        url.appendingPathExtension("previous")
    }

    func append(_ line: String, at date: Date = .now) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Data("\(formatter.string(from: date)) \(line)\n".utf8)
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: entry)
        } else {
            try? entry.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int,
              size >= maximumBytes
        else { return }
        try? fileManager.removeItem(at: previousURL)
        try? fileManager.moveItem(at: url, to: previousURL)
    }
}

struct BackgroundRefreshDeadlinePolicy: Sendable {
    /// One launchd interval. A single tracked app with ~400 keywords across storefronts takes
    /// about 28 minutes end to end (measured 2026-09-22), so the earlier 15-minute budget killed
    /// healthy runs. The daily lock already keeps the next hourly wake from overlapping this one.
    static let defaultBudget: TimeInterval = 60 * 60
    static let defaultCleanupGrace: TimeInterval = 10

    let budget: TimeInterval
    let cleanupGrace: TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        budget: TimeInterval = Self.defaultBudget,
        cleanupGrace: TimeInterval = Self.defaultCleanupGrace,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.budget = max(0, budget)
        self.cleanupGrace = max(0, cleanupGrace)
        self.sleep = sleep
    }
}

@MainActor
struct BackgroundRefreshRuntimeOperations: Sendable {
    let openModelContainer: @MainActor @Sendable (AppNamespace) throws -> ModelContainer
    let makeServices: @MainActor @Sendable (
        UserDefaults,
        AppNamespace,
        ModelContainer
    ) -> AppServices
    let prepareModelStore: @MainActor @Sendable (AppServices) async -> Void
    let runRefresh: @MainActor @Sendable (
        AppServices,
        HeadlessRefreshRunRequest
    ) async -> HeadlessRefreshRunSummary

    static let live = Self(
        openModelContainer: { namespace in
            try ModelContainerFactory.makeModelContainer(
                isStoredInMemoryOnly: false,
                namespace: namespace
            )
        },
        makeServices: { defaults, namespace, modelContainer in
            AppServices.backgroundRefresh(
                defaults: defaults,
                namespace: namespace,
                modelContainer: modelContainer
            )
        },
        prepareModelStore: { services in
            await services.prepareBackgroundModelStore()
        },
        runRefresh: { services, request in
            await services.runAutomaticHeadlessRefresh(request)
        }
    )
}

enum BackgroundRefreshRuntime {
    static let argument = "--daily-refresh-once"
    static let dailyLockFileName = "daily-refresh.lock"

    private enum DeadlineOutcome: Sendable {
        case completed(HeadlessRefreshRunSummary)
        case failed(String)
        case deadline
        case cleanupGraceElapsed
    }

    @MainActor
    static func runOnce(
        defaults: UserDefaults = .openASOShared,
        namespace: AppNamespace = .current,
        now: Date = .now,
        calendar: Calendar = .current,
        diagnosticSink: BackgroundRefreshDiagnosticSink = .liveOneShot,
        operations: BackgroundRefreshRuntimeOperations = .live,
        deadlinePolicy: BackgroundRefreshDeadlinePolicy = .init(),
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity = .current()
    ) async -> Int32 {
        // The heartbeat is the proof that launchd actually spawned this process, so it is written
        // before any work, claim, or lock can turn the launch into an early return.
        defaults.set(now, forKey: BackgroundRefreshAgentController.agentWakeDefaultsKey)

        let runID = UUID()
        let origin = BackgroundRefreshRunRecord.ExecutionOrigin.oneShot
        await diagnosticSink.record(event(
            .started,
            runID: runID,
            phase: .starting,
            at: now,
            origin: origin,
            buildIdentity: buildIdentity
        ))

        let lock = CrossProcessFileLock(
            namespace: namespace,
            fileName: dailyLockFileName
        )

        do {
            let attempt = try await lock.attempt {
                await runWhileHoldingLock(
                    runID: runID,
                    defaults: defaults,
                    namespace: namespace,
                    now: now,
                    calendar: calendar,
                    diagnosticSink: diagnosticSink,
                    operations: operations,
                    deadlinePolicy: deadlinePolicy,
                    buildIdentity: buildIdentity
                )
            }
            switch attempt {
            case .acquired(let exitCode):
                return exitCode
            case .unavailable:
                await diagnosticSink.record(event(
                    .lockUnavailable,
                    runID: runID,
                    phase: .claiming,
                    at: now,
                    exitCode: 0,
                    origin: origin,
                    buildIdentity: buildIdentity
                ))
                return 0
            }
        } catch {
            await diagnosticSink.record(event(
                .terminal,
                runID: runID,
                phase: .finished,
                at: now,
                exitCode: 1,
                disposition: .failure,
                origin: origin,
                buildIdentity: buildIdentity
            ))
            return 1
        }
    }

    @MainActor
    private static func runWhileHoldingLock(
        runID: UUID,
        defaults: UserDefaults,
        namespace: AppNamespace,
        now: Date,
        calendar: Calendar,
        diagnosticSink: BackgroundRefreshDiagnosticSink,
        operations: BackgroundRefreshRuntimeOperations,
        deadlinePolicy: BackgroundRefreshDeadlinePolicy,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) async -> Int32 {
        let settingsStore = AppSettingsStore(defaults: defaults)
        if settingsStore.activeBackgroundRefreshAttempt != nil {
            await diagnosticSink.record(event(
                .interruptedAttemptFound,
                runID: runID,
                phase: .claiming,
                at: now,
                origin: .oneShot,
                buildIdentity: buildIdentity
            ))
        }

        await diagnosticSink.record(event(
            .phaseStarted,
            runID: runID,
            phase: .claiming,
            at: now,
            origin: .oneShot,
            buildIdentity: buildIdentity
        ))
        let evaluation = settingsStore.evaluateAndClaimAutomaticRefresh(
            at: now,
            calendar: calendar
        )
        guard let claim = evaluation.claim else {
            let kind: BackgroundRefreshRuntimeEvent.Kind
            if !settingsStore.isAutomaticRefreshEnabled {
                kind = .disabled
            } else if settingsStore.hasClaimedAutomaticRefresh(on: now, calendar: calendar) {
                kind = .alreadyClaimed
            } else {
                kind = .notDue
            }
            await diagnosticSink.record(event(
                kind,
                runID: runID,
                phase: .claiming,
                at: now,
                exitCode: 0,
                origin: .oneShot,
                buildIdentity: buildIdentity
            ))
            return 0
        }

        let attempt = BackgroundRefreshActiveAttemptRecord(
            runID: runID,
            claimedAt: now,
            scheduledFor: claim.scheduledFor,
            lastPhase: BackgroundRefreshRuntimePhase.claiming.rawValue,
            executionOrigin: .oneShot,
            buildIdentity: buildIdentity
        )
        settingsStore.recordActiveBackgroundRefreshAttempt(attempt)

        let (stream, continuation) = AsyncStream<DeadlineOutcome>.makeStream(
            bufferingPolicy: .unbounded
        )
        let operationTask = Task { @MainActor in
            do {
                let summary = try await performClaimedRefresh(
                    runID: runID,
                    claim: claim,
                    defaults: defaults,
                    namespace: namespace,
                    settingsStore: settingsStore,
                    diagnosticSink: diagnosticSink,
                    operations: operations,
                    buildIdentity: buildIdentity
                )
                continuation.yield(.completed(summary))
            } catch {
                let message = (error as? PersistentStoreError)?.diagnosticReport
                    ?? OpenASOError.map(error).localizedDescription
                continuation.yield(.failed(message))
            }
        }
        let deadlineTask = Task.detached {
            do {
                try await deadlinePolicy.sleep(deadlinePolicy.budget)
                continuation.yield(.deadline)
            } catch {}
        }

        var iterator = stream.makeAsyncIterator()
        guard let first = await iterator.next() else {
            operationTask.cancel()
            deadlineTask.cancel()
            return 1
        }
        switch first {
        case .completed(let summary):
            deadlineTask.cancel()
            return await finishNormally(
                summary: summary,
                runID: runID,
                settingsStore: settingsStore,
                diagnosticSink: diagnosticSink,
                buildIdentity: buildIdentity
            )
        case .failed(let message):
            deadlineTask.cancel()
            return await finishFailure(
                message: message,
                claim: claim,
                runID: runID,
                settingsStore: settingsStore,
                diagnosticSink: diagnosticSink,
                buildIdentity: buildIdentity
            )
        case .deadline:
            operationTask.cancel()
            updateActiveAttempt(attempt, phase: .timedOut, in: settingsStore)
            await diagnosticSink.record(event(
                .timedOut,
                runID: runID,
                phase: .timedOut,
                at: .now,
                exitCode: 1,
                disposition: .failure,
                origin: .oneShot,
                buildIdentity: buildIdentity
            ))
            let graceTask = Task.detached {
                do {
                    try await deadlinePolicy.sleep(deadlinePolicy.cleanupGrace)
                    continuation.yield(.cleanupGraceElapsed)
                } catch {}
            }
            let cleanupOutcome = await iterator.next()
            graceTask.cancel()
            let timeoutDiagnostic = HeadlessRefreshDiagnostic(
                appStoreID: 0,
                stage: .timeout,
                provider: .internalService,
                severity: .failure,
                reasonCode: .timedOut
            )
            if case .completed(let summary) = cleanupOutcome {
                settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(
                    summary: summary,
                    executionOrigin: .oneShot,
                    buildIdentity: buildIdentity,
                    additionalDiagnostics: [timeoutDiagnostic]
                ))
            } else {
                settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(
                    scheduledFor: claim.scheduledFor,
                    finishedAt: .now,
                    disposition: .failure,
                    issueMessage: timeoutDiagnostic.safeMessage,
                    runID: runID,
                    executionOrigin: .oneShot,
                    buildIdentity: buildIdentity,
                    diagnostics: [timeoutDiagnostic]
                ))
            }
            await diagnosticSink.record(event(
                .terminal,
                runID: runID,
                phase: .finished,
                at: .now,
                exitCode: 1,
                disposition: .failure,
                origin: .oneShot,
                buildIdentity: buildIdentity
            ))
            updateActiveAttempt(attempt, phase: .timedOut, in: settingsStore)
            return 1
        case .cleanupGraceElapsed:
            return 1
        }
    }

    @MainActor
    private static func performClaimedRefresh(
        runID: UUID,
        claim: DailyRefreshScheduleClaim,
        defaults: UserDefaults,
        namespace: AppNamespace,
        settingsStore: AppSettingsStore,
        diagnosticSink: BackgroundRefreshDiagnosticSink,
        operations: BackgroundRefreshRuntimeOperations,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) async throws -> HeadlessRefreshRunSummary {
        let attempt = settingsStore.activeBackgroundRefreshAttempt

        let databaseStarted = Date.now
        await recordPhaseStart(
            .databaseOpen,
            runID: runID,
            attempt: attempt,
            settingsStore: settingsStore,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )
        let modelContainer = try operations.openModelContainer(namespace)
        await recordPhaseFinish(
            .databaseOpen,
            startedAt: databaseStarted,
            runID: runID,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )

        let servicesStarted = Date.now
        await recordPhaseStart(
            .serviceInitialization,
            runID: runID,
            attempt: attempt,
            settingsStore: settingsStore,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )
        let services = operations.makeServices(defaults, namespace, modelContainer)
        await recordPhaseFinish(
            .serviceInitialization,
            startedAt: servicesStarted,
            runID: runID,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )

        let preparationStarted = Date.now
        await recordPhaseStart(
            .modelStorePreparation,
            runID: runID,
            attempt: attempt,
            settingsStore: settingsStore,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )
        await operations.prepareModelStore(services)
        try Task.checkCancellation()
        await recordPhaseFinish(
            .modelStorePreparation,
            startedAt: preparationStarted,
            runID: runID,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )

        guard services.headlessRefreshService != nil else {
            throw OpenASOError.providerUnavailable(
                "The automatic refresh service is unavailable."
            )
        }

        let refreshStarted = Date.now
        await recordPhaseStart(
            .planningAndApps,
            runID: runID,
            attempt: attempt,
            settingsStore: settingsStore,
            sink: diagnosticSink,
            buildIdentity: buildIdentity
        )
        let summary = await operations.runRefresh(
            services,
            HeadlessRefreshRunRequest(
                id: runID,
                scheduledFor: claim.scheduledFor,
                refreshRatingsAndReviews: claim.refreshRatingsAndReviews
            )
        )
        await recordPhaseFinish(
            .planningAndApps,
            startedAt: refreshStarted,
            runID: runID,
            sink: diagnosticSink,
            buildIdentity: buildIdentity,
            plannedAppCount: summary.plannedAppCount,
            completedAppCount: summary.completedAppCount
        )
        return summary
    }

    @MainActor
    private static func finishNormally(
        summary: HeadlessRefreshRunSummary,
        runID: UUID,
        settingsStore: AppSettingsStore,
        diagnosticSink: BackgroundRefreshDiagnosticSink,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) async -> Int32 {
        settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(
            summary: summary,
            executionOrigin: .oneShot,
            buildIdentity: buildIdentity
        ))
        settingsStore.clearActiveBackgroundRefreshAttempt(runID: runID)
        let exitCode: Int32 = switch summary.disposition {
        case .failure, .cancelled, .rejectedRequestConflict: 1
        case .noWork, .success, .partialFailure, .skippedAlreadyRunning: 0
        }
        await diagnosticSink.record(event(
            .terminal,
            runID: runID,
            phase: .finished,
            at: .now,
            plannedAppCount: summary.plannedAppCount,
            completedAppCount: summary.completedAppCount,
            exitCode: exitCode,
            disposition: summary.disposition,
            origin: .oneShot,
            buildIdentity: buildIdentity
        ))
        return exitCode
    }

    @MainActor
    private static func finishFailure(
        message: String,
        claim: DailyRefreshScheduleClaim,
        runID: UUID,
        settingsStore: AppSettingsStore,
        diagnosticSink: BackgroundRefreshDiagnosticSink,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) async -> Int32 {
        let diagnostic = HeadlessRefreshDiagnostic(
            appStoreID: 0,
            stage: .setup,
            provider: .internalService,
            severity: .failure,
            reasonCode: .stageFailed
        )
        settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(
            scheduledFor: claim.scheduledFor,
            finishedAt: .now,
            disposition: .failure,
            issueMessage: message,
            runID: runID,
            executionOrigin: .oneShot,
            buildIdentity: buildIdentity,
            diagnostics: [diagnostic]
        ))
        settingsStore.clearActiveBackgroundRefreshAttempt(runID: runID)
        await diagnosticSink.record(event(
            .terminal,
            runID: runID,
            phase: .finished,
            at: .now,
            exitCode: 1,
            disposition: .failure,
            origin: .oneShot,
            buildIdentity: buildIdentity
        ))
        return 1
    }

    @MainActor
    private static func recordPhaseStart(
        _ phase: BackgroundRefreshRuntimePhase,
        runID: UUID,
        attempt: BackgroundRefreshActiveAttemptRecord?,
        settingsStore: AppSettingsStore,
        sink: BackgroundRefreshDiagnosticSink,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) async {
        if let attempt {
            updateActiveAttempt(attempt, phase: phase, in: settingsStore)
        }
        await sink.record(event(
            .phaseStarted,
            runID: runID,
            phase: phase,
            at: .now,
            origin: .oneShot,
            buildIdentity: buildIdentity
        ))
    }

    private static func recordPhaseFinish(
        _ phase: BackgroundRefreshRuntimePhase,
        startedAt: Date,
        runID: UUID,
        sink: BackgroundRefreshDiagnosticSink,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity,
        plannedAppCount: Int? = nil,
        completedAppCount: Int? = nil
    ) async {
        let milliseconds = max(0, Int(Date.now.timeIntervalSince(startedAt) * 1_000))
        await sink.record(event(
            .phaseFinished,
            runID: runID,
            phase: phase,
            at: .now,
            durationMilliseconds: milliseconds,
            plannedAppCount: plannedAppCount,
            completedAppCount: completedAppCount,
            origin: .oneShot,
            buildIdentity: buildIdentity
        ))
    }

    @MainActor
    private static func updateActiveAttempt(
        _ attempt: BackgroundRefreshActiveAttemptRecord,
        phase: BackgroundRefreshRuntimePhase,
        in settingsStore: AppSettingsStore
    ) {
        settingsStore.recordActiveBackgroundRefreshAttempt(
            BackgroundRefreshActiveAttemptRecord(
                runID: attempt.runID,
                claimedAt: attempt.claimedAt,
                scheduledFor: attempt.scheduledFor,
                lastPhase: phase.rawValue,
                executionOrigin: attempt.executionOrigin,
                buildIdentity: attempt.buildIdentity
            )
        )
    }

    private static func event(
        _ kind: BackgroundRefreshRuntimeEvent.Kind,
        runID: UUID,
        phase: BackgroundRefreshRuntimePhase?,
        at timestamp: Date,
        durationMilliseconds: Int? = nil,
        plannedAppCount: Int? = nil,
        completedAppCount: Int? = nil,
        exitCode: Int32? = nil,
        disposition: HeadlessRefreshRunDisposition? = nil,
        origin: BackgroundRefreshRunRecord.ExecutionOrigin,
        buildIdentity: BackgroundRefreshRunRecord.BuildIdentity
    ) -> BackgroundRefreshRuntimeEvent {
        BackgroundRefreshRuntimeEvent(
            kind: kind,
            runID: runID,
            phase: phase,
            timestamp: timestamp,
            durationMilliseconds: durationMilliseconds,
            plannedAppCount: plannedAppCount,
            completedAppCount: completedAppCount,
            exitCode: exitCode,
            disposition: disposition,
            origin: origin,
            buildIdentity: buildIdentity
        )
    }
}

final class OneShotWatchdogPhaseStore: Sendable {
    private let phase = Mutex(BackgroundRefreshRuntimePhase.starting)

    func update(from event: BackgroundRefreshRuntimeEvent) {
        guard let eventPhase = event.phase else { return }
        phase.withLock { $0 = eventPhase }
    }

    func current() -> BackgroundRefreshRuntimePhase {
        phase.withLock { $0 }
    }
}

final class OneShotProcessWatchdog: @unchecked Sendable {
    private final class DispatchWorkItemBox: @unchecked Sendable {
        let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() {
            item.cancel()
        }
    }

    typealias Cancellation = @Sendable () -> Void
    typealias Scheduler = (
        _ delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> Cancellation

    private struct State {
        var didFire = false
        var cancellation: Cancellation?
    }

    private let state = Mutex(State())
    private let scheduler: Scheduler

    init(scheduler: @escaping Scheduler = { delay, action in
        let item = DispatchWorkItem(block: action)
        let box = DispatchWorkItemBox(item)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
        return { box.cancel() }
    }) {
        self.scheduler = scheduler
    }

    func start(
        after delay: TimeInterval,
        lastPhase: @escaping @Sendable () -> BackgroundRefreshRuntimePhase,
        write: @escaping @Sendable (String) -> Void,
        terminate: @escaping @Sendable (Int32) -> Void
    ) {
        let cancellation = scheduler(delay) { [weak self] in
            guard let self else { return }
            let shouldFire = state.withLock { state in
                guard !state.didFire else { return false }
                state.didFire = true
                return true
            }
            guard shouldFire else { return }
            write("Background refresh watchdog fired phase=\(lastPhase().rawValue) exitCode=1")
            terminate(1)
        }
        state.withLock { $0.cancellation = cancellation }
    }

    func cancel() {
        let cancellation = state.withLock { state -> Cancellation? in
            let cancellation = state.cancellation
            state.cancellation = nil
            return cancellation
        }
        cancellation?()
    }
}
