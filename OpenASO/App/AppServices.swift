import Foundation
import Observation
import SwiftData

actor RankingMetadataEnrichmentWorkQueue {
    typealias Handler = @Sendable (RankingMetadataEnrichmentRequest) async -> Void

    private let handler: Handler
    private var pendingRequests: [RankingMetadataEnrichmentRequest] = []
    private var nextPendingIndex = 0
    private var seenRequests = Set<RankingMetadataEnrichmentRequest>()
    private var isDraining = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func enqueue(_ requests: [RankingMetadataEnrichmentRequest]) async {
        for request in requests where seenRequests.insert(request).inserted {
            pendingRequests.append(request)
        }

        guard !isDraining else { return }
        isDraining = true
        defer {
            pendingRequests.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
            isDraining = false
        }

        while nextPendingIndex < pendingRequests.count {
            let request = pendingRequests[nextPendingIndex]
            nextPendingIndex += 1
            await handler(request)
            seenRequests.remove(request)
        }
    }
}

/// Owns the in-app daily refresh loop and the one rule that keeps it safe to reconfigure: a refresh
/// that is already running is never cancelled.
///
/// The daily claim is persisted before any work begins, so a cancelled run does not retry — it
/// burns the day. A schedule change therefore waits for the running refresh instead of restarting
/// the loop underneath it; the loop re-reads the saved schedule on its next iteration anyway, so
/// the restart only matters for a loop that is sleeping or has exited.
@MainActor
final class InAppDailyRefreshSchedulerSupervisor {
    private let runLoop: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var isRefreshInFlight = false
    private var didClaimDuringFlight = false
    private var hasPendingRestart = false

    init(runLoop: @escaping @MainActor () async -> Void) {
        self.runLoop = runLoop
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [runLoop] in
            await runLoop()
        }
    }

    func restart() {
        guard !isRefreshInFlight else {
            hasPendingRestart = true
            return
        }

        task?.cancel()
        task = nil
        start()
    }

    /// Marks the flight as having committed the day, which is what makes it unsafe to cancel.
    func markRefreshClaimed() {
        didClaimDuringFlight = true
    }

    func withRefreshInFlight<Value>(
        _ operation: @MainActor () async -> Value
    ) async -> Value {
        isRefreshInFlight = true
        didClaimDuringFlight = false
        defer {
            let didClaim = didClaimDuringFlight
            isRefreshInFlight = false
            didClaimDuringFlight = false
            honourPendingRestart(didClaim: didClaim)
        }
        return await operation()
    }

    private func honourPendingRestart(didClaim: Bool) {
        guard hasPendingRestart else { return }
        hasPendingRestart = false

        // Nothing was claimed and nothing ran, so there is nothing to lose by replacing the loop —
        // and it must be replaced, because it is about to sleep on a stale schedule.
        guard didClaim else {
            restart()
            return
        }

        guard let runningTask = task else {
            start()
            return
        }

        // Cancelling here would cancel the very iteration that just finished the refresh, so the
        // loop is left to continue and only a loop that exits on its own is revived.
        Task { @MainActor [weak self] in
            await runningTask.value
            guard let self, self.task == runningTask else { return }
            self.task = nil
            self.start()
        }
    }
}

@Observable
@MainActor
final class AppServices {
    let appleAdsCredentialStore: AppleAdsCredentialStore
    let appleAdsWebSessionStore: AppleAdsWebSessionStore
    let appleAdsWebSessionManager: AppleAdsWebSessionManager
    let settingsStore: AppSettingsStore
    let backgroundRefreshAgentController: BackgroundRefreshAgentController
    let analyticsService: AnalyticsService
    let refreshMetricsRecorder: RefreshMetricsRecorder
    let appStoreConnectCredentialStore: AppStoreConnectCredentialStore
    let appStoreConnectReviewService: AppStoreConnectReviewService
    private(set) var dailyRefreshScheduler: DailyRefreshScheduler?
    let headlessRefreshService: HeadlessRefreshService?
    let headlessRefreshObservationRecorder: HeadlessRefreshObservationRecorder
    private(set) var headlessRefreshSnapshot = HeadlessRefreshSnapshot.empty
    let storefrontCatalog: StorefrontCatalog
    let appResolver: any AppResolver
    let appStoreWebMetadataProvider: AppStoreWebMetadataProvider
    let appCatalogService: AppCatalogService
    let appIconStore: AppIconStore
    let appMetadataRefreshService: AppMetadataRefreshService?
    let appMetadataRefreshProgressStore: AppMetadataRefreshProgressStore
    let screenshotDownloadService: ScreenshotDownloadService
    let screenshotDownloadProgressStore: ScreenshotDownloadProgressStore
    let appStorefrontRatingService: AppStorefrontRatingService
    let appStorefrontReviewService: AppStorefrontReviewService
    let aiService: any AIService
    let reviewTranslationService: ReviewTranslationService
    let reviewLanguageDetectionService: ReviewLanguageDetectionService
    let keywordMetricsService: KeywordMetricsService
    let keywordInsightsService: KeywordInsightsService
    let keywordSuggestionService: KeywordSuggestionService
    let rankedAppPricingService: RankedAppPricingService
    let visibleProductPricingService: VisibleProductPricingService
    let rankingProvider: any SearchRankingProvider
    let refreshCoordinator: RankingRefreshCoordinator
    let appDetailRefreshService: AppDetailRefreshService?
    let refreshProgressStore: AppRefreshProgressStore
    let mcpServerProvider: OpenASOMCPServerProvider
    let mcpServerController: OpenASOMCPServerController
    let keywordResearchProjectStore: KeywordResearchProjectStore?
    let keywordResearchProjectCopyService: KeywordResearchProjectCopyService?
    let keywordResearchRankingWorkflow: KeywordResearchRankingWorkflow?
    let keywordResearchMetricsWorkflow: KeywordResearchMetricsWorkflow?
    private(set) var backgroundModelStore: BackgroundModelStore?
    private(set) var backgroundModelStoreRevision = 0
    private var inAppDailyRefreshSchedulerSupervisor: InAppDailyRefreshSchedulerSupervisor?
    private var dailyRefreshScheduleChangeToken: Int32?

    init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        defaults: UserDefaults = .openASOShared,
        keychain: any KeychainService = SystemKeychainService(),
        namespace: AppNamespace = .current,
        aiService: (any AIService)? = nil,
        loadsEnvironmentCredentials: Bool = true,
        allowsIconNetworkFetches: Bool = true,
        backgroundModelStore: BackgroundModelStore? = nil,
        keywordResearchProjectStore: KeywordResearchProjectStore? = nil,
        keywordResearchProjectCopyService: KeywordResearchProjectCopyService? = nil,
        keywordResearchRankingWorkflow: KeywordResearchRankingWorkflow? = nil,
        keywordResearchMetricsWorkflow: KeywordResearchMetricsWorkflow? = nil,
        refreshObservationClock: RefreshObservationClock = .live,
        refreshMetricsRecorder: RefreshMetricsRecorder? = nil,
        providerRequestGateMode: ProviderRequestGateMode? = nil,
        providerRequestClock: ProviderRequestClock = .live,
        providerRequestRandomness: ProviderRequestRandomness = .live
    ) {
        let refreshMetricsRecorder = refreshMetricsRecorder ?? RefreshMetricsRecorder(
            clock: refreshObservationClock
        )
        let headlessRefreshObservationRecorder = HeadlessRefreshObservationRecorder()
        let httpClient = ProviderHTTPClientPipeline.make(
            transport: httpClient,
            mode: providerRequestGateMode ?? .production(defaults: defaults),
            refreshMetricsRecorder: refreshMetricsRecorder,
            refreshObservationClock: refreshObservationClock,
            providerRequestClock: providerRequestClock,
            providerRequestRandomness: providerRequestRandomness
        )
        let appleAdsCredentialStore = AppleAdsCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: loadsEnvironmentCredentials
        )
        let settingsStore = AppSettingsStore(defaults: defaults)
        let backgroundRefreshAgentController = BackgroundRefreshAgentController(
            defaults: defaults
        )
        let analyticsService = AnalyticsService(settingsStore: settingsStore)
        let appleAdsWebSessionStore = AppleAdsWebSessionStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let appStoreConnectCredentialStore = AppStoreConnectCredentialStore(
            defaults: defaults,
            keychain: keychain,
            namespace: namespace
        )
        let appleAdsWebSessionManager = AppleAdsWebSessionManager(
            sessionStore: appleAdsWebSessionStore,
            settingsStore: settingsStore,
            credentialStore: appleAdsCredentialStore,
            httpClient: httpClient,
            namespace: namespace
        )
        let resolver = DefaultAppResolver(httpClient: httpClient)
        let appStoreWebMetadataProvider = AppStoreWebMetadataProvider(httpClient: httpClient)
        let catalogService = AppCatalogService(appResolver: resolver)
        let appIconStore = AppIconStore(
            namespace: namespace,
            allowsNetworkFetches: allowsIconNetworkFetches
        )
        let appMetadataRefreshService = backgroundModelStore.map { backgroundModelStore in
            AppMetadataRefreshService(
                appResolver: resolver,
                webMetadataProvider: appStoreWebMetadataProvider,
                store: SwiftDataAppMetadataRefreshStore(
                    backgroundModelStore: backgroundModelStore,
                    appCatalogService: catalogService
                ),
                iconInvalidator: appIconStore
            )
        }
        let appMetadataRefreshProgressStore = AppMetadataRefreshProgressStore(
            refreshOperation: { request, progress in
                guard let appMetadataRefreshService else {
                    throw OpenASOError.providerUnavailable(
                        "Metadata refresh needs an initialized workspace store."
                    )
                }
                return try await appMetadataRefreshService.refresh(
                    request,
                    progress: progress
                )
            }
        )
        let screenshotDownloadService = ScreenshotDownloadService()
        let screenshotDownloadProgressStore = ScreenshotDownloadProgressStore()
        let appStorefrontRatingService = AppStorefrontRatingService(httpClient: httpClient)
        let appStorefrontReviewService = AppStorefrontReviewService(
            httpClient: httpClient
        )
        let aiService = aiService ?? AIServiceRouter(providers: [
            FoundationModelsAIService()
        ])
        let reviewTranslationService = ReviewTranslationService(aiService: aiService)
        let reviewLanguageDetectionService = ReviewLanguageDetectionService()
        let appStoreConnectReviewService = AppStoreConnectReviewService(
            httpClient: httpClient,
            credentialStore: appStoreConnectCredentialStore
        )
        let keywordMetricsService = KeywordMetricsService(
            httpClient: httpClient,
            credentialStore: appleAdsCredentialStore,
            settingsStore: settingsStore,
            webSessionStore: appleAdsWebSessionStore
        )
        let keywordInsightsService = KeywordInsightsService()
        let rankedAppPricingService = RankedAppPricingService(httpClient: httpClient)
        let visibleProductPricingService = VisibleProductPricingService(
            httpClient: httpClient
        )
        let rankingProvider = SearchRankingProviderFactory.makeProduction(httpClient: httpClient)
        let mcpRankingRefreshScheduler = OpenASOMCPRankingRefreshScheduler()
        let refreshProgressStore = AppRefreshProgressStore()
        let storefrontCatalog = StorefrontCatalog()
        let keywordResearchProjectStore = keywordResearchProjectStore
            ?? backgroundModelStore.map {
                KeywordResearchProjectStore(backgroundModelStore: $0)
            }
        let keywordResearchProjectCopyService = keywordResearchProjectCopyService
            ?? backgroundModelStore.map {
                KeywordResearchProjectCopyService(backgroundModelStore: $0)
            }
        let metadataEnrichmentScheduler: (@Sendable ([RankingMetadataEnrichmentRequest]) -> Void)?
        if let backgroundModelStore {
            let metadataEnrichmentQueue = RankingMetadataEnrichmentWorkQueue { request in
                let shouldEnrich = (try? await backgroundModelStore.read { modelContext in
                    try catalogService.shouldEnrichStorefrontMetadata(
                        appStoreID: request.appStoreID,
                        storefrontCode: request.storefront,
                        platform: request.platform,
                        freshnessInterval: RankingRefreshCoordinator.metadataEnrichmentFreshnessInterval,
                        in: modelContext
                    )
                }) ?? false
                guard shouldEnrich else { return }

                async let resolvedAppTask = try? resolver.resolve(
                    appStoreID: request.appStoreID,
                    storefrontCode: request.storefront
                )
                async let webMetadataTask = try? appStoreWebMetadataProvider.fetch(
                    appStoreID: request.appStoreID,
                    storefrontCode: request.storefront
                )
                let (resolvedApp, webMetadata) = await (resolvedAppTask, webMetadataTask)
                guard resolvedApp != nil || webMetadata != nil else {
                    return
                }

                try? await backgroundModelStore.write { modelContext in
                    if let resolvedApp {
                        _ = try catalogService.upsertStoreApp(
                            from: resolvedApp,
                            storefrontCode: request.storefront,
                            in: modelContext
                        )
                    }
                    if let webMetadata {
                        let storeApp = try catalogService.upsertStoreApp(
                            from: webMetadata,
                            storefrontCode: request.storefront,
                            in: modelContext
                        )
                        if webMetadata.ratingCount != nil || webMetadata.averageRating != nil || webMetadata.ratingCounts != nil {
                            let result = AppStorefrontRatingResult(
                                appStoreID: webMetadata.appStoreID,
                                storefront: request.storefront,
                                ratingCount: webMetadata.ratingCount,
                                averageRating: webMetadata.averageRating,
                                ratingCounts: webMetadata.ratingCounts,
                                observedAt: .now,
                                source: .appStorePage
                            )
                            appStorefrontRatingService.persist(
                                AppStorefrontRatingRefreshOutcome(
                                    storefront: request.storefront,
                                    result: result,
                                    error: nil
                                ),
                                for: storeApp,
                                in: modelContext
                            )
                        }
                    }
                    try modelContext.save()
                }
            }
            metadataEnrichmentScheduler = { requests in
                Task {
                    await metadataEnrichmentQueue.enqueue(requests)
                }
            }
        } else {
            metadataEnrichmentScheduler = nil
        }
        let refreshCoordinator = RankingRefreshCoordinator(
            rankingProvider: rankingProvider,
            appCatalogService: catalogService,
            analyticsService: analyticsService,
            refreshTriggerRecorder: { date in
                await settingsStore.markRefreshTriggered(on: date)
            },
            metadataEnrichmentScheduler: metadataEnrichmentScheduler
        )
        let keywordResearchRankingWorkflow = keywordResearchRankingWorkflow
            ?? backgroundModelStore.map {
                KeywordResearchRankingWorkflow(
                    backgroundModelStore: $0,
                    rankingCoordinator: refreshCoordinator
                )
            }
        let keywordResearchMetricsWorkflow = keywordResearchMetricsWorkflow
            ?? backgroundModelStore.map {
                KeywordResearchMetricsWorkflow(
                    backgroundModelStore: $0,
                    metricsService: keywordMetricsService,
                    rankingCoordinator: refreshCoordinator,
                    configurationProvider: {
                        let session = appleAdsWebSessionStore.session
                        return KeywordResearchMetricsConfiguration(
                            contextAppStoreID: settingsStore.popularityContextAppStoreID,
                            webSession: session,
                            requiresReconnect: session.map {
                                appleAdsWebSessionStore.requiresReconnect(for: $0)
                            } ?? false
                        )
                    },
                    reconnectMarker: { attemptedSession in
                        appleAdsWebSessionStore.markReconnectRequired(for: attemptedSession)
                    }
                )
            }
        let appDetailRefreshService = backgroundModelStore.map {
            AppDetailRefreshService(
                backgroundModelStore: $0,
                refreshCoordinator: refreshCoordinator,
                keywordMetricsService: keywordMetricsService,
                appStorefrontRatingService: appStorefrontRatingService,
                appStorefrontReviewService: appStorefrontReviewService,
                appStoreConnectReviewService: appStoreConnectReviewService,
                progressStore: refreshProgressStore,
                refreshMetricsRecorder: refreshMetricsRecorder,
                ratingsReviewsRefreshRecorder: { date in
                    await settingsStore.markRatingsReviewsRefreshed(on: date)
                }
            )
        }
        let headlessRefreshService: HeadlessRefreshService?
        if let backgroundModelStore,
           let appMetadataRefreshService,
           let appDetailRefreshService {
            let planLoader = DailyRefreshPlanLoader(
                backgroundModelStore: backgroundModelStore
            )
            let appAdapter = HeadlessRefreshAppAdapter(
                refreshMetadata: { request in
                    try await appMetadataRefreshService.refresh(request)
                },
                refreshDetail: { request in
                    try await appDetailRefreshService.refreshCancellable(request)
                }
            )
            headlessRefreshService = HeadlessRefreshService(
                dependencies: HeadlessRefreshDependencies(
                    loadPlan: { request in
                        try Task.checkCancellation()
                        let configuration = try await MainActor.run {
                            DailyRefreshPlanConfiguration(
                                fallbackStorefrontCodes: try storefrontCatalog
                                    .bundledStorefronts()
                                    .map { storefront in
                                        storefront.code
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                            .lowercased()
                                    }
                                    .filter { !$0.isEmpty },
                                refreshRatingsAndReviews: request.refreshRatingsAndReviews,
                                popularityContextAppStoreID: settingsStore
                                    .popularityContextAppStoreID,
                                appleAdsWebSession: appleAdsWebSessionStore.recoverSessionIfNeeded(),
                                appStoreConnectCredentials: appStoreConnectCredentialStore
                                    .credentials
                            )
                        }
                        try Task.checkCancellation()
                        return try await planLoader.load(configuration: configuration)
                    },
                    refreshApp: { plan in
                        try await appAdapter.refresh(plan)
                    },
                    recordObservation: { observation in
                        await headlessRefreshObservationRecorder.record(observation)
                    }
                )
            )
        } else {
            headlessRefreshService = nil
        }
        self.appleAdsCredentialStore = appleAdsCredentialStore
        self.appleAdsWebSessionStore = appleAdsWebSessionStore
        self.appleAdsWebSessionManager = appleAdsWebSessionManager
        self.settingsStore = settingsStore
        self.backgroundRefreshAgentController = backgroundRefreshAgentController
        self.analyticsService = analyticsService
        self.refreshMetricsRecorder = refreshMetricsRecorder
        self.appStoreConnectCredentialStore = appStoreConnectCredentialStore
        self.appStoreConnectReviewService = appStoreConnectReviewService
        self.dailyRefreshScheduler = nil
        self.headlessRefreshService = headlessRefreshService
        self.headlessRefreshObservationRecorder = headlessRefreshObservationRecorder
        self.storefrontCatalog = storefrontCatalog
        self.appResolver = resolver
        self.appStoreWebMetadataProvider = appStoreWebMetadataProvider
        self.appCatalogService = catalogService
        self.appIconStore = appIconStore
        self.appMetadataRefreshService = appMetadataRefreshService
        self.appMetadataRefreshProgressStore = appMetadataRefreshProgressStore
        self.screenshotDownloadService = screenshotDownloadService
        self.screenshotDownloadProgressStore = screenshotDownloadProgressStore
        self.appStorefrontRatingService = appStorefrontRatingService
        self.appStorefrontReviewService = appStorefrontReviewService
        self.aiService = aiService
        self.reviewTranslationService = reviewTranslationService
        self.reviewLanguageDetectionService = reviewLanguageDetectionService
        self.keywordMetricsService = keywordMetricsService
        self.keywordInsightsService = keywordInsightsService
        self.keywordSuggestionService = KeywordSuggestionService()
        self.rankedAppPricingService = rankedAppPricingService
        self.visibleProductPricingService = visibleProductPricingService
        self.rankingProvider = rankingProvider
        self.refreshCoordinator = refreshCoordinator
        self.appDetailRefreshService = appDetailRefreshService
        self.refreshProgressStore = refreshProgressStore
        self.keywordResearchProjectStore = keywordResearchProjectStore
        self.keywordResearchProjectCopyService = keywordResearchProjectCopyService
        self.keywordResearchRankingWorkflow = keywordResearchRankingWorkflow
        self.keywordResearchMetricsWorkflow = keywordResearchMetricsWorkflow
        let mcpServerProvider = OpenASOMCPServerProvider {
            guard let backgroundModelStore, let keywordResearchProjectStore else {
                throw OpenASOError.providerUnavailable("OpenASO MCP needs an initialized workspace store.")
            }

            let mcpService = OpenASOMCPService(
                backgroundModelStore: backgroundModelStore,
                keywordResearchProjectStore: keywordResearchProjectStore,
                appResolver: resolver,
                appCatalogService: catalogService,
                httpClient: httpClient,
                screenshotDownloadService: screenshotDownloadService,
                rankingProvider: rankingProvider,
                rankingRefreshCoordinator: refreshCoordinator,
                rankingRefreshScheduler: mcpRankingRefreshScheduler,
                reviewService: appStorefrontReviewService,
                keywordMetricsService: keywordMetricsService,
                rankedAppPricingService: rankedAppPricingService,
                visibleProductPricingService: visibleProductPricingService,
                popularityContextAppStoreIDProvider: {
                    settingsStore.popularityContextAppStoreID
                },
                appleAdsWebSessionProvider: {
                    appleAdsWebSessionStore.recoverSessionIfNeeded()
                }
            )

            return await OpenASOMCPServerFactory(
                service: mcpService,
                configuration: OpenASOMCPServerConfiguration(version: "1.5.0")
            ).makeServer()
        }
        self.mcpServerProvider = mcpServerProvider
        self.mcpServerController = OpenASOMCPServerController(portProvider: {
            settingsStore.mcpServerPort
        }) {
            try await mcpServerProvider.makeServer()
        }
        self.backgroundModelStore = backgroundModelStore
        self.backgroundModelStoreRevision = backgroundModelStore == nil ? 0 : 1
        if headlessRefreshService != nil {
            let dailyRefreshLock = CrossProcessFileLock(
                namespace: namespace,
                fileName: BackgroundRefreshRuntime.dailyLockFileName
            )
            self.dailyRefreshScheduler = DailyRefreshScheduler(
                runIteration: { [weak self] date, calendar in
                    // Outside the flight and the daily lock: repairing the launchd registration is
                    // not refresh work and must not be serialized against the one-shot process.
                    await self?.backgroundRefreshAgentController.repairIfStale(now: date)
                    guard let self else {
                        return DailyRefreshSchedulerIteration(nextCheckAt: nil)
                    }
                    return await self.runDailyRefreshIteration(
                        at: date,
                        calendar: calendar,
                        lock: dailyRefreshLock
                    )
                }
            )
        }
        self.appMetadataRefreshProgressStore.setRevisionHandler { [weak self] _, _ in
            self?.markBackgroundModelStoreChanged()
        }
    }

    func prepareBackgroundModelStore() async {
        await backgroundModelStore?.prepare()
    }

    /// Runs the in-app scheduler for as long as the process lives, independently of any window.
    /// Calling it again while the loop is running is a no-op.
    ///
    /// It stays on whatever the launchd agent reports: the agent can be `.enabled` and still never
    /// launch, and the two paths already exclude each other through the shared daily lock.
    func startInAppDailyRefreshScheduler() {
        guard let dailyRefreshScheduler else { return }

        let supervisor = inAppDailyRefreshSchedulerSupervisor
            ?? InAppDailyRefreshSchedulerSupervisor {
                await dailyRefreshScheduler.run()
            }
        inAppDailyRefreshSchedulerSupervisor = supervisor
        supervisor.start()

        // An MCP/API schedule change lands in another process; pick it up now instead of at the
        // loop's next wake, which can be tomorrow's slot.
        if dailyRefreshScheduleChangeToken == nil {
            dailyRefreshScheduleChangeToken = DailyRefreshScheduleChangeSignal.observe { [weak self] in
                guard let self else { return }
                self.settingsStore.reloadAutomaticRefreshSchedule()
                self.restartInAppDailyRefreshScheduler()
            }
        }
    }

    /// `DailyRefreshScheduler.run()` returns for good once the schedule is disabled, and it can be
    /// asleep for up to an hour, so every change to the schedule needs a fresh loop.
    func restartInAppDailyRefreshScheduler() {
        guard let inAppDailyRefreshSchedulerSupervisor else {
            startInAppDailyRefreshScheduler()
            return
        }

        inAppDailyRefreshSchedulerSupervisor.restart()
    }

    /// One scheduler tick.
    ///
    /// The claim and the refresh are one indivisible flight: `evaluateAndClaimAutomaticRefresh`
    /// persists the day before any work begins, so a restart landing between the claim and the
    /// refresh burns the day exactly as cancelling the refresh itself would. The flight is marked
    /// outside the daily lock, so a restart that does replace the loop cannot race the new loop for
    /// a lock this one still holds.
    private func runDailyRefreshIteration(
        at date: Date,
        calendar: Calendar,
        lock: CrossProcessFileLock
    ) async -> DailyRefreshSchedulerIteration {
        await withDailyRefreshFlight {
            do {
                let attempt = try await lock.attempt {
                    let evaluation = self.settingsStore.evaluateAndClaimAutomaticRefresh(
                        at: date,
                        calendar: calendar
                    )
                    if let claim = evaluation.claim, !Task.isCancelled {
                        self.inAppDailyRefreshSchedulerSupervisor?.markRefreshClaimed()
                        _ = await self.runAutomaticHeadlessRefresh(
                            HeadlessRefreshRunRequest(
                                scheduledFor: claim.scheduledFor,
                                refreshRatingsAndReviews: claim.refreshRatingsAndReviews
                            )
                        )
                    }
                    return DailyRefreshSchedulerIteration(
                        nextCheckAt: evaluation.nextCheckAt
                    )
                }
                switch attempt {
                case .acquired(let iteration):
                    return iteration
                case .unavailable:
                    return DailyRefreshSchedulerIteration(
                        nextCheckAt: date.addingTimeInterval(60)
                    )
                }
            } catch {
                return DailyRefreshSchedulerIteration(
                    nextCheckAt: date.addingTimeInterval(15 * 60)
                )
            }
        }
    }

    private func withDailyRefreshFlight<Value>(
        _ operation: @MainActor () async -> Value
    ) async -> Value {
        guard let inAppDailyRefreshSchedulerSupervisor else {
            return await operation()
        }

        return await inAppDailyRefreshSchedulerSupervisor.withRefreshInFlight(operation)
    }

    func markBackgroundModelStoreChanged() {
        backgroundModelStoreRevision += 1
    }

    func recordHeadlessRefreshCompletion(_ summary: HeadlessRefreshRunSummary) {
        settingsStore.recordBackgroundRefreshRun(BackgroundRefreshRunRecord(summary: summary))
        if summary.plannedAppCount > 0 {
            markBackgroundModelStoreChanged()
        }
        if summary.ratingsReviewsFullySucceeded {
            settingsStore.markRatingsReviewsRefreshed(on: summary.scheduledFor)
        }
    }

    func runAutomaticHeadlessRefresh(
        _ request: HeadlessRefreshRunRequest
    ) async -> HeadlessRefreshRunSummary {
        guard let headlessRefreshService else {
            let now = Date.now
            return HeadlessRefreshRunSummary(
                runID: request.id,
                activeRunID: nil,
                scheduledFor: request.scheduledFor,
                startedAt: now,
                finishedAt: now,
                disposition: .failure,
                plannedAppCount: 0,
                completedAppCount: 0,
                successfulAppCount: 0,
                partialFailureAppCount: 0,
                failedAppCount: 0,
                ratingsReviewsAttempted: false,
                ratingsReviewsFullySucceeded: false,
                issue: HeadlessRefreshIssue(kind: .planUnavailable)
            )
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .idleSystemSleepDisabled],
            reason: "Completing OpenASO's scheduled background refresh"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let summary = await headlessRefreshService.run(request)
        recordHeadlessRefreshCompletion(summary)
        return summary
    }

    func observeHeadlessRefreshes() async {
        let updates = await headlessRefreshObservationRecorder.updates()
        for await snapshot in updates {
            guard !Task.isCancelled else { return }
            headlessRefreshSnapshot = snapshot
        }
    }

    func refreshStaleKeywordPopularityAfterAppleAdsConnection() {
        guard let backgroundModelStore,
              let popularityContextAppStoreID = settingsStore.popularityContextAppStoreID,
              let webSession = appleAdsWebSessionStore.recoverSessionIfNeeded(),
              webSession.isComplete
        else {
            return
        }

        let keywordMetricsService = keywordMetricsService
        let refreshProgressStore = refreshProgressStore
        Task {
            let preparation: StalePopularityRefreshPreparation
            do {
                preparation = try await keywordMetricsService.prepareStalePopularityRefresh(
                    using: backgroundModelStore
                )
            } catch {
                let refreshID = refreshProgressStore.beginAppleAdsPopularityRefresh(total: 0)
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: OpenASOError.map(error)
                )
                return
            }
            if preparation.clearedStatusCount > 0 {
                self.markBackgroundModelStoreChanged()
            }
            let trackIdentityKeys = preparation.trackIdentityKeys
            guard !trackIdentityKeys.isEmpty else { return }

            let refreshID = refreshProgressStore.beginAppleAdsPopularityRefresh(
                total: preparation.refreshQueryCount
            )
            do {
                let result = try await keywordMetricsService.refreshMetricsBatch(
                    for: trackIdentityKeys,
                    popularityContextAppStoreID: popularityContextAppStoreID,
                    webSession: webSession,
                    using: backgroundModelStore,
                    progress: { completed, total, failureCount in
                        await refreshProgressStore.updateStep(
                            .metrics,
                            status: completed >= total ? (failureCount > 0 ? .failed : .completed) : .running,
                            completed: completed,
                            total: total,
                            failureCount: failureCount,
                            refreshID: refreshID
                        )
                    },
                    didPersist: { update in
                        await refreshProgressStore.recordKeywordDataUpdated(
                            identityKeys: update.trackIdentityKeys
                        )
                    }
                )

                if !result.outcomes.isEmpty {
                    await MainActor.run {
                        self.markBackgroundModelStoreChanged()
                    }
                }
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: result.firstErrorMessage.map(OpenASOError.providerUnavailable)
                )
            } catch {
                refreshProgressStore.finish(
                    refreshID: refreshID,
                    error: OpenASOError.map(error)
                )
            }
        }
    }

    static func preview(httpClient: HTTPClient, modelContainer: ModelContainer? = nil) -> AppServices {
        mocked(httpClient: httpClient, modelContainer: modelContainer)
    }

    static func appLaunch(modelContainer: ModelContainer? = nil) -> AppServices {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return mocked(httpClient: PreviewHTTPClient(), modelContainer: modelContainer)
        }

        let backgroundModelStore = modelContainer.map {
            BackgroundModelStore(modelContainer: $0)
        }

        return AppServices(backgroundModelStore: backgroundModelStore)
    }

    /// Constructs the one-shot service graph from exactly the dependencies selected by the
    /// runtime. Unlike `appLaunch`, this never swaps in preview defaults under XCTest and never
    /// permits an authentication UI from the login Keychain.
    static func backgroundRefresh(
        defaults: UserDefaults = .openASOShared,
        namespace: AppNamespace = .current,
        keychain: any KeychainService = SystemKeychainService(
            interactionPolicy: .noninteractive
        ),
        httpClient: HTTPClient = URLSessionHTTPClient(),
        modelContainer: ModelContainer
    ) -> AppServices {
        AppServices(
            httpClient: httpClient,
            defaults: defaults,
            keychain: keychain,
            namespace: namespace,
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: false,
            backgroundModelStore: BackgroundModelStore(modelContainer: modelContainer)
        )
    }
}

extension AppServices {
    static func mocked(
        httpClient: HTTPClient,
        modelContainer: ModelContainer? = nil,
        allowsIconNetworkFetches: Bool = false
    ) -> AppServices {
        let backgroundModelStore = modelContainer.map {
            BackgroundModelStore(modelContainer: $0)
        }

        return AppServices(
            httpClient: httpClient,
            defaults: UserDefaults.previewSuite(),
            keychain: InMemoryKeychainService(),
            aiService: MockAIService { request, _ in
                """
                {"title":"Translated \(request.prompt.contains("Title:") ? "Review" : "Text")","content":"Preview translation"}
                """
            },
            loadsEnvironmentCredentials: false,
            allowsIconNetworkFetches: allowsIconNetworkFetches,
            backgroundModelStore: backgroundModelStore,
            providerRequestGateMode: .disabled
        )
    }
}

private extension UserDefaults {
    static func previewSuite() -> UserDefaults {
        let suiteName = "com.thirdtech.openaso.preview.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
