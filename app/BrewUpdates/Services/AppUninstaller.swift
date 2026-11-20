import Foundation

/// What to remove besides the schedule and the app's script, which always go
struct UninstallOptions: Equatable, Sendable {
    var logs = false
    var backups = false
    var config = false
}

/// Removes what the app set up outside its bundle, the app's version of
/// `scripts/uninstall.sh`: stops and removes the LaunchAgent (both labels), removes the
/// installed script folder, and optionally the logs, Brewfile backups and config file.
///
/// Files go to the Trash rather than being deleted, so an uninstall can be undone by hand.
/// The app itself stays; the user moves it to the Trash afterwards.
struct AppUninstaller: Sendable {
    /// Gets rid of one file or folder. The app moves it to the Trash; tests delete it, so they
    /// don't fill the user's Trash
    typealias Discard = @Sendable (URL) throws -> Void

    let paths: AppPaths
    private let launchctl: LaunchAgentService.Launchctl
    private let discard: Discard

    init(
        paths: AppPaths,
        launchctl: @escaping LaunchAgentService.Launchctl = LaunchAgentService.systemLaunchctl,
        discard: @escaping Discard = AppUninstaller.moveToTrash
    ) {
        self.paths = paths
        self.launchctl = launchctl
        self.discard = discard
    }

    static let moveToTrash: Discard = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The copy `scripts/setup.sh` puts in ~/bin for running by hand. The app didn't install
    /// it, so it leaves it alone (`scripts/uninstall.sh` removes it)
    var commandLineScript: URL { paths.home.appending(path: "bin/brew-updates.sh") }

    /// Everything `uninstall(_:)` would remove that exists now, in the order it removes them
    func items(for options: UninstallOptions) -> [URL] {
        let plist = paths.launchAgentPlist
        let legacy = paths.legacyLaunchAgentPlist
        var candidates = [
            plist,
            plist.appendingPathExtension("app-backup"),
            legacy,
            legacy.appendingPathExtension("migrated"),
            paths.supportDirectory
        ]
        // The marker tells the script to leave notifications to the app; it lives in the
        // log folder, so it only needs removing on its own when the logs stay
        candidates.append(options.logs ? paths.logDirectory : paths.appMarker)
        if options.backups { candidates.append(paths.backupDirectory) }
        if options.config { candidates.append(paths.configFile) }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Stops the scheduled job and removes the files. Holds the run lock so it can't stop a
    /// scheduled run halfway through (throws `RunLockError.held` if one is running).
    /// Returns what it removed.
    @discardableResult
    func uninstall(_ options: UninstallOptions) async throws -> [URL] {
        let lock = RunLock(paths: paths)
        try lock.acquire()
        // When the logs go, the lock folder goes with them and this finds nothing to release
        defer { lock.release() }

        let domain = "gui/\(getuid())"
        for label in [AppPaths.launchAgentLabel, AppPaths.legacyLaunchAgentLabel] {
            // Fails harmlessly when the job isn't loaded
            _ = try? await launchctl(["bootout", "\(domain)/\(label)"])
        }

        let removed = items(for: options)
        for url in removed {
            try discard(url)
        }
        return removed
    }
}
