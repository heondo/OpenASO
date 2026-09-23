import AppKit
import SwiftUI

enum OpenASOWindowID {
    static let main = "main"
}

/// The menu behind the status-bar icon.
///
/// Deliberately a small surface: what the app is doing right now, plus the ways back into it.
/// Refresh controls stay in the main window, where their progress and cancellation already live.
struct MenuBarStatusView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(refreshStatusTitle)

        if let detail = refreshStatusDetail {
            Text(detail)
        }

        if isBackgroundAgentStale {
            Text("Background service isn't starting — refreshes run only while OpenASO is open")
        }

        Text("Apple Ads: \(appleAdsConnectionState.title)")

        Divider()

        Button("Open OpenASO") {
            openMainWindow()
        }
        .keyboardShortcut("o")

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit OpenASO") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var refreshStatus: DailyRefreshRunStatusPresentation? {
        DailyRefreshRunStatusPresentation(
            activeRun: services.headlessRefreshSnapshot.activeRun,
            latestRun: services.headlessRefreshSnapshot.recentRuns.first,
            persistedRun: services.settingsStore.lastBackgroundRefreshRun
        )
    }

    private var refreshStatusTitle: String {
        refreshStatus?.title ?? "No automatic refresh yet"
    }

    /// The active runs already say everything in their title, so only finished runs add a line.
    private var refreshStatusDetail: String? {
        guard let refreshStatus else { return nil }
        if refreshStatus.isActive {
            return refreshStatus.detail
        }
        guard let finishedAt = refreshStatus.finishedAt else { return nil }
        return "Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The registration can report `.enabled` while launchd never spawns it, which otherwise leaves
    /// the menu claiming a schedule that only the in-app scheduler is keeping.
    private var isBackgroundAgentStale: Bool {
        services.settingsStore.isAutomaticRefreshEnabled
            && services.backgroundRefreshAgentController.isAgentStale()
    }

    private var appleAdsConnectionState: AppleAdsConnectionState {
        AppleAdsConnectionState.inferred(
            hasSession: services.appleAdsWebSessionStore.hasSession,
            requiresReconnect: services.appleAdsWebSessionStore.requiresReconnect,
            updatedAt: services.appleAdsWebSessionStore.session?.updatedAt
        )
    }

    /// Raises the window the app already has before asking for a new one, so clicking the menu item
    /// twice does not leave two copies of the app behind.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let existingWindow = NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix(OpenASOWindowID.main) == true
        }

        if let existingWindow {
            existingWindow.deminiaturize(nil)
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: OpenASOWindowID.main)
        }
    }
}
