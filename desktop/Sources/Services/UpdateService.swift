import Foundation
import Observation
import Sparkle

/// Owns Needle's Sparkle updater. The app bundle controls whether updates are
/// enabled by supplying a feed URL in Info.plist; local development builds can
/// therefore run without contacting the distribution feed.
@MainActor
@Observable
final class UpdateService {
    private let updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?

    var isConfigured: Bool { updaterController != nil }
    private(set) var canCheckForUpdates = false

    init(bundle: Bundle = .main) {
        guard let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Self.isValidConfiguration(feedURL: feedURL, publicKey: publicKey) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
        }
    }

    static func isValidConfiguration(feedURL: String, publicKey: String) -> Bool {
        feedURL == "https://raw.githubusercontent.com/icebli/needle/main/appcast.xml"
            && Data(base64Encoded: publicKey)?.count == 32
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
