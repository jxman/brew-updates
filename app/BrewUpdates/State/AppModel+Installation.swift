import Foundation
import os

// Setting up what the app needs outside its bundle: the update script and the LaunchAgent.
// This replaces what scripts/setup.sh did for app users.
extension AppModel {
    private static let log = Logger(subsystem: AppPaths.appBundleIdentifier, category: "installation")

    /// Installs the script bundled in the app (when the installed copy is missing or
    /// different, e.g. after an app update), then moves an existing LaunchAgent over to it.
    /// Runs at every launch; does nothing when everything is already in place.
    func prepareInstallation() async {
        // `Bundle.main` is the app itself; project.yml copies brew-updates.sh from the
        // repo root into its Resources folder
        guard let bundled = Bundle.main.url(forResource: "brew-updates", withExtension: "sh") else {
            installationError = ScriptInstallError.notBundled.localizedDescription
            return
        }
        do {
            if try ScriptInstaller(paths: paths).install(from: bundled) {
                Self.log.info("Installed the bundled script at \(self.paths.deployedScript.path, privacy: .public)")
            }
        } catch {
            installationError = "Couldn't install the update script: \(error.localizedDescription)"
            return
        }

        // Moving the LaunchAgent reloads it, which would stop a scheduled run in progress.
        // Holding the run lock rules that out; if a run has it, try again at the next launch.
        let lock = RunLock(paths: paths)
        do {
            try lock.acquire()
        } catch {
            Self.log.info("Run in progress, LaunchAgent check postponed to the next launch")
            return
        }
        defer { lock.release() }
        do {
            let result = try await LaunchAgentService(paths: paths).adoptExistingAgent()
            Self.log.info("LaunchAgent: \(String(describing: result), privacy: .public)")
            // The LaunchAgent (if any) now runs deployedScript, so the old copy is unused
            ScriptInstaller(paths: paths).removeRetiredCopy()
            installationError = nil
        } catch {
            installationError = "Couldn't move the schedule over to the app's script: \(error.localizedDescription)"
        }
    }

    // MARK: First-run setup

    enum SetupMode: Equatable {
        /// Creates the real LaunchAgent and saves the notification choice
        case install
        /// For trying the sheet on a Mac that is already set up (launch with
        /// `-ShowSetup YES`): writes the plist to a scratch folder and never calls launchctl
        case preview
    }

    /// UserDefaults keys. "Not Now" stops the sheet opening by itself at every launch; it can
    /// still be opened from the Dashboard or Settings
    private static let setupPostponedKey = "setupPostponed"
    private static let showSetupKey = "ShowSetup"

    /// Where `.preview` writes its plist instead of ~/Library/LaunchAgents
    var setupPreviewPaths: AppPaths { AppPaths(home: paths.supportDirectory.appending(path: "SetupPreview")) }

    /// True when there is no LaunchAgent to run updates on a schedule
    var needsSetup: Bool { !FileManager.default.fileExists(atPath: paths.launchAgentPlist.path) }

    /// Opens the setup sheet at launch when the Mac has no schedule yet, unless postponed.
    func presentSetupIfNeeded() {
        // `UserDefaults` also reads launch arguments, so `-ShowSetup YES` in the Xcode scheme
        // (Product > Scheme > Edit Scheme > Arguments) turns this on for one run
        if UserDefaults.standard.bool(forKey: Self.showSetupKey) {
            setupMode = .preview
        } else if needsSetup, !UserDefaults.standard.bool(forKey: Self.setupPostponedKey) {
            setupMode = .install
        }
    }

    /// "Not Now": closes the sheet and doesn't open it by itself again.
    func postponeSetup() {
        if setupMode == .install {
            UserDefaults.standard.set(true, forKey: Self.setupPostponedKey)
        }
        setupMode = nil
    }

    /// "Set Up": creates the LaunchAgent with the chosen schedule and saves the notification
    /// choice (asking for permission when on). Throws so the sheet can show the error.
    func completeSetup(schedule draft: ScheduleDraft, notifications: Bool, brewExecutable: URL?) async throws {
        let searchPath = BrewService.searchPath(brewExecutable: brewExecutable)
        switch setupMode ?? .install {
        case .install:
            try await LaunchAgentService(paths: paths).install(draft, searchPath: searchPath)
            // Also asks for notification permission when they're turned on
            try await saveConfig([(key: "ENABLE_NOTIFICATIONS", value: notifications ? "true" : "false")])
            UserDefaults.standard.removeObject(forKey: Self.setupPostponedKey)
        case .preview:
            let preview = setupPreviewPaths
            try? FileManager.default.removeItem(at: preview.home)
            let noLaunchctl: LaunchAgentService.Launchctl = { _ in
                ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            try await LaunchAgentService(paths: preview, launchctl: noLaunchctl).install(draft, searchPath: searchPath)
            Self.log.info("Setup preview wrote \(preview.launchAgentPlist.path, privacy: .public)")
        }
        setupMode = nil
        await reloadSettings()
    }
}
