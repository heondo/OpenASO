import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController {
    private let updaterController: SPUStandardUpdaterController

    init(startingUpdater: Bool = false) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
