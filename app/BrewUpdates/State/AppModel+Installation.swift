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
        // The launcher is embedded in Contents/MacOS, where `forAuxiliaryExecutable` looks
        guard let bundled = Bundle.main.url(forResource: "brew-updates", withExtension: "sh"),
              let launcher = Bundle.main.url(forAuxiliaryExecutable: AppPaths.launcherName) else {
            installationError = ScriptInstallError.notBundled.localizedDescription
            return
        }
        do {
            let installer = ScriptInstaller(paths: paths)
            if try installer.install(from: bundled) {
                Self.log.info("Installed the bundled script at \(self.paths.deployedScript.path, privacy: .public)")
            }
            // Before the LaunchAgent is pointed at it below
            if try installer.installLauncher(from: launcher) {
                Self.log.info("Installed the launcher at \(self.paths.deployedLauncher.path, privacy: .public)")
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
        // The sheet asks people to install Homebrew while the app is open, so look for it
        // again and load everything, not only the settings
        await refresh()
    }

    // MARK: Homebrew

    /// No `brew` in /opt/homebrew or /usr/local. Runs can't start (`canStartRun`) and a
    /// banner says why
    var isHomebrewMissing: Bool { brew.executable == nil }

    /// Looks for `brew` again. `BrewService` finds it once, when it's created, so without this
    /// a Homebrew installed while the app is open (as the setup sheet suggests) would go
    /// unnoticed until the next launch. Only checks two paths, so it's cheap enough for every refresh.
    func locateHomebrew() {
        let found = BrewService.locate()
        // Also cheap, and grype may have been installed in Terminal
        security.checkGrype(brewExecutable: found)
        guard found != brew.executable else { return }
        Self.log.info("Homebrew now at \(found?.path ?? "none (removed)", privacy: .public)")
        brew = BrewService(executable: found)
        doctor.use(brew)
        security.use(SecurityScanner(brewExecutable: found))
    }

    // MARK: Uninstall

    /// Removes the schedule, the installed script and, if chosen, the logs, backups and
    /// config (to the Trash). Refuses while a run is in progress. The app reinstalls its
    /// script and offers setup again if it is opened later.
    func uninstall(_ options: UninstallOptions) async throws {
        guard !isRunInProgress else { throw RunLockError.held(pid: runningPID) }
        let removed = try await AppUninstaller(paths: paths).uninstall(options)
        Self.log.info("Uninstalled, moved \(removed.count) items to the Trash")
        // So the setup sheet opens by itself if the app is opened again
        UserDefaults.standard.removeObject(forKey: Self.setupPostponedKey)
        isUninstalled = true
        await refresh()
    }
}
