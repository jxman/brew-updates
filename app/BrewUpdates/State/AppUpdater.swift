import Foundation
import Observation
import Sparkle

/// Updates the app itself (not Homebrew) with Sparkle, the standard updater for Mac apps
/// sold outside the App Store.
///
/// Sparkle reads `SUFeedURL` from Info.plist (project.yml): an appcast, a small RSS file that
/// `scripts/release.sh` writes and the GitHub release carries, listing the newest version, its
/// DMG, release notes and an EdDSA signature. Sparkle installs an update only when that
/// signature matches `SUPublicEDKey` and the new app is signed by the same team.
/// Its standard user interface does the rest: the "update available" window, progress, relaunch.
///
/// The app installs its new script at the next launch (`ScriptInstaller`), so an update
/// reaches the scheduled runs as soon as the updated app opens.
@MainActor
@Observable
final class AppUpdater {
    /// False while a check is already showing, so the menu item greys out
    private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks once a day by itself. Stored by Sparkle in the app's defaults
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    /// Whether Sparkle also downloads an update in the background and installs it when the
    /// app quits, instead of asking first
    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Whether the updater runs at all. Not in Debug builds (they'd offer to replace
    /// themselves with the release) and not before the app is in Applications
    private(set) var isEnabled = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// - Parameter isRunActive: whether a run the app started is in progress. Installing an
    ///   update relaunches the app, and quitting would stop that run
    init(isRunActive: @escaping @MainActor () -> Bool) {
        delegate = UpdaterDelegate(isRunActive: isRunActive)
    }

    /// Starts checking (daily, plus once now if a day has passed). Call once at launch
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
        )
        self.controller = controller
        isEnabled = true
        // Key-value observing: Sparkle is Objective-C and announces changes this way. The
        // closure isn't marked as running on the main thread, but it does (Sparkle works only
        // there), so `assumeIsolated` lets it read the updater and set our property
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// "Check for App Updates…": always shows a result, even "You're up to date"
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle's delegate has to be an `NSObject`. Sparkle marks the protocol main-thread-only
/// (`NS_SWIFT_UI_ACTOR`), which Swift sees as `@MainActor`, so this class is too.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let isRunActive: @MainActor () -> Bool

    init(isRunActive: @escaping @MainActor () -> Bool) {
        self.isRunActive = isRunActive
    }

    /// Holds the relaunch until a run the app started has finished; otherwise quitting would
    /// stop it halfway, like Ctrl-C. Scheduled runs belong to launchd and carry on regardless
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard isRunActive() else { return false }
        Task { @MainActor in
            while isRunActive() {
                try? await Task.sleep(for: .seconds(2))
            }
            installHandler()
        }
        return true
    }
}
