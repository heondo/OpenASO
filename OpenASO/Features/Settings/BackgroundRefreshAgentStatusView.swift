import SwiftUI

struct BackgroundRefreshAgentStatusView: View {
    let controller: BackgroundRefreshAgentController
    let automaticRefreshEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
            } icon: {
                if isStale {
                    Image(systemName: systemImage)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.callout)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let errorMessage = controller.lastErrorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if automaticRefreshEnabled,
               controller.status == .requiresApproval
            {
                Button("Open Login Items Settings") {
                    controller.openSystemSettings()
                }
            } else if automaticRefreshEnabled,
                      controller.status != .enabled || isStale
            {
                Button("Retry Background Setup") {
                    Task { @MainActor in
                        await controller.reconcile(isEnabled: true, force: true)
                    }
                }
                .disabled(controller.isReconciling)
            }
        }
    }

    /// `.enabled` only means the registration exists; launchd can still refuse to spawn it.
    private var isStale: Bool {
        automaticRefreshEnabled && controller.isAgentStale()
    }

    private var title: String {
        guard automaticRefreshEnabled else {
            return "Background refresh is off"
        }
        if isStale {
            return "Background refresh isn't starting"
        }
        switch controller.status {
        case .enabled:
            return "Background refresh is ready"
        case .requiresApproval:
            return "Background refresh needs approval"
        case .notRegistered:
            return controller.isReconciling
                ? "Setting up background refresh"
                : "Background refresh is not registered"
        case .notFound:
            return "Background refresh is unavailable"
        }
    }

    private var detail: String {
        guard automaticRefreshEnabled else {
            return "OpenASO will not run scheduled refreshes."
        }
        if isStale {
            return "macOS is not launching the background service. Scheduled refreshes still run while OpenASO is open."
        }
        switch controller.status {
        case .enabled:
            return "It can run while OpenASO is closed or the screen is locked, as long as this user is logged in and the Mac is awake."
        case .requiresApproval:
            return "Allow OpenASO under General › Login Items & Extensions in System Settings."
        case .notRegistered:
            return "While OpenASO is open, the in-app scheduler remains active."
        case .notFound:
            return "The packaged background service could not be found. Reinstall or update OpenASO, then retry."
        }
    }

    private var systemImage: String {
        guard automaticRefreshEnabled else { return "pause.circle" }
        if isStale {
            return "exclamationmark.triangle.fill"
        }
        switch controller.status {
        case .enabled:
            return "checkmark.circle.fill"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .notRegistered:
            return controller.isReconciling ? "clock.arrow.circlepath" : "circle.dashed"
        case .notFound:
            return "xmark.octagon.fill"
        }
    }
}
