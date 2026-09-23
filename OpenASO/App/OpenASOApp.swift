import Foundation
import SwiftData
import SwiftUI

@main
struct OpenASOApp: App {
    private let updaterController: SparkleUpdaterController?
    @State private var launchAlert: AppLaunchAlertContext?

    private let startupState: OpenASOStartupState

    init() {
        let executionMode = OpenASOExecutionMode(
            arguments: ProcessInfo.processInfo.arguments
        )
        updaterController = executionMode == .graphical
            ? SparkleUpdaterController(startingUpdater: true)
            : nil
        if executionMode.suppressesApplicationUI {
            _ = NSApplication.shared.setActivationPolicy(.prohibited)
        }

        if executionMode == .backgroundRefresh {
            Self.runBackgroundRefreshAndExit()
        }

        let startupState = Self.makeStartupState()
        if executionMode == .mcpStdio {
            switch startupState {
            case .ready(_, let services):
                Self.runMCPStdioAndExit(serverProvider: services.mcpServerProvider)
            case .storeUnavailable(let error):
                Self.exitMCPStdio(with: error.diagnosticReport)
            }
        }

        self.startupState = startupState
        _launchAlert = State(initialValue: nil)

        // Scheduled refreshes must not depend on a window existing: with the menu bar item the app
        // can be resident with no main window at all.
        if executionMode == .graphical,
           case .ready(_, let services) = startupState,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { @MainActor in
                await services.backgroundRefreshAgentController.reconcile(
                    isEnabled: services.settingsStore.isAutomaticRefreshEnabled
                )
                services.startInAppDailyRefreshScheduler()
            }
        }
    }

    private static func makeStartupState() -> OpenASOStartupState {
        do {
            let modelContainer = try ModelContainerFactory.makeModelContainer(isStoredInMemoryOnly: false)
            let services = AppServices.appLaunch(modelContainer: modelContainer)
            return .ready(modelContainer: modelContainer, services: services)
        } catch let error as PersistentStoreError {
            return .storeUnavailable(error)
        } catch {
            return .storeUnavailable(.unexpected(
                diagnosticDescription: String(reflecting: error)
            ))
        }
    }

    private static func runBackgroundRefreshAndExit() -> Never {
        let phaseStore = OneShotWatchdogPhaseStore()
        let watchdog = OneShotProcessWatchdog()
        let logFile = OneShotRefreshLogFile.live()
        watchdog.start(
            after: BackgroundRefreshDeadlinePolicy.defaultBudget
                + BackgroundRefreshDeadlinePolicy.defaultCleanupGrace,
            lastPhase: { phaseStore.current() },
            write: { message in
                OneShotRefreshLog.emit(message, logFile: logFile)
            },
            terminate: { exitCode in
                Foundation.exit(exitCode)
            }
        )
        let sink = BackgroundRefreshDiagnosticSink { event in
            phaseStore.update(from: event)
            OneShotRefreshLog.emit(event.redactedLogMessage, logFile: logFile)
        }
        Task { @MainActor in
            let exitCode = await BackgroundRefreshRuntime.runOnce(diagnosticSink: sink)
            watchdog.cancel()
            Foundation.exit(exitCode)
        }
        RunLoop.main.run()
        fatalError("The background refresh run loop stopped unexpectedly.")
    }

    private static func runMCPStdioAndExit(
        serverProvider: OpenASOMCPServerProvider
    ) -> Never {
        Task.detached {
            let exitCode: Int32
            do {
                try await OpenASOMCPRuntime.runStdio(serverProvider: serverProvider)
                exitCode = 0
            } catch {
                let description = (error as? PersistentStoreError)?.diagnosticReport
                    ?? String(reflecting: error)
                FileHandle.standardError.write(Data("OpenASO MCP server failed: \(description)\n".utf8))
                exitCode = 1
            }
            Foundation.exit(exitCode)
        }
        dispatchMain()
    }

    private static func exitMCPStdio(with diagnostic: String) -> Never {
        FileHandle.standardError.write(Data("OpenASO MCP server failed: \(diagnostic)\n".utf8))
        Foundation.exit(1)
    }

    var body: some Scene {
        WindowGroup("OpenASO", id: OpenASOWindowID.main) {
            switch startupState {
            case .ready(let modelContainer, let services):
                RootView()
                    .environment(services)
                    .modelContainer(modelContainer)
                    .frame(idealWidth: 1000, idealHeight: 760)
                    .task {
                        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                            if services.settingsStore.mcpServerAutostart {
                                services.mcpServerController.start()
                            }
                        }
                        services.analyticsService.capture(.appLaunched())
                        await services.prepareBackgroundModelStore()
                        launchAlert = await Self.seedStorefrontCatalogIfNeeded(using: services)
                    }
                    .alert(item: $launchAlert) { alert in
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            dismissButton: .default(Text("OK"))
                        )
                    }
            case .storeUnavailable(let error):
                PersistentStoreRecoveryView(error: error)
                    .frame(idealWidth: 680, idealHeight: 480)
            }
        }
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleRect = context.defaultDisplay.visibleRect
            let fittedSize = CGSize(
                width: min(idealSize.width, visibleRect.width),
                height: min(idealSize.height, visibleRect.height)
            )
            return WindowPlacement(size: fittedSize)
        }

        Settings {
            switch startupState {
            case .ready(let modelContainer, let services):
                SettingsView()
                    .environment(services)
                    .modelContainer(modelContainer)
            case .storeUnavailable(let error):
                PersistentStoreRecoveryView(error: error)
                    .frame(idealWidth: 680, idealHeight: 480)
            }
        }
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleRect = context.defaultDisplay.visibleRect
            let fittedSize = CGSize(
                width: min(idealSize.width, visibleRect.width),
                height: min(idealSize.height, visibleRect.height)
            )
            return WindowPlacement(size: fittedSize)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController?.checkForUpdates()
                }
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }

        menuBarScene
    }

    private var menuBarScene: some Scene {
        MenuBarExtra(
            "OpenASO",
            systemImage: "chart.line.uptrend.xyaxis",
            isInserted: menuBarIconVisibility
        ) {
            menuBarContent
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        if case .ready(let modelContainer, let services) = startupState {
            MenuBarStatusView()
                .environment(services)
                .modelContainer(modelContainer)
        }
    }

    /// Stays hidden when the store failed to open, since every line the menu would show comes from
    /// services that do not exist in that state.
    ///
    /// The setting is read eagerly rather than inside the binding's getter so that evaluating the
    /// scene registers the observation — a getter that only runs later would never retrigger it.
    private var menuBarIconVisibility: Binding<Bool> {
        guard case .ready(_, let services) = startupState else {
            return .constant(false)
        }

        let showsMenuBarIcon = services.settingsStore.showsMenuBarIcon
        return Binding(
            get: { showsMenuBarIcon },
            set: { services.settingsStore.setShowsMenuBarIcon($0) }
        )
    }

    private static func seedStorefrontCatalogIfNeeded(using services: AppServices) async -> AppLaunchAlertContext? {
        do {
            guard let backgroundModelStore = services.backgroundModelStore else {
                throw OpenASOError.providerUnavailable("The background model store is unavailable.")
            }

            try await services.storefrontCatalog.seedIfNeeded(using: backgroundModelStore)
            return nil
        } catch {
            return AppLaunchAlertContext(
                title: "Country List Failed",
                message: OpenASOError.map(error).localizedDescription
            )
        }
    }
}

private enum OpenASOStartupState {
    case ready(modelContainer: ModelContainer, services: AppServices)
    case storeUnavailable(PersistentStoreError)
}

private struct AppLaunchAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
