import Foundation

/// File locations shared with `brew-updates.sh`.
///
/// Everything hangs off `home` so tests can point the app at a fixture directory
/// instead of the real `~/.brew_logs`.
struct AppPaths: Sendable {
    /// The LaunchAgent the app manages. Matches `LAUNCHAGENT_LABEL` in the script
    static let launchAgentLabel = "com.jxman.brew-updates"
    /// The label `scripts/setup.sh` used before app 1.5.0. The app moves such a LaunchAgent
    /// over to `launchAgentLabel` (`LaunchAgentService.adoptExistingAgent`)
    static let legacyLaunchAgentLabel = "com.user.brew-update"
    /// Written into the plist's `AssociatedBundleIdentifiers`, so System Settings > Login Items
    /// lists the scheduled job under the app's name instead of "bash"
    static let appBundleIdentifier = "com.jxman.BrewUpdates"
    static let current = AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)

    let home: URL

    var logDirectory: URL { home.appending(path: ".brew_logs", directoryHint: .isDirectory) }
    var backupDirectory: URL { home.appending(path: ".brew_backups", directoryHint: .isDirectory) }
    var lockPIDFile: URL { logDirectory.appending(path: ".brew-updates.lock/pid") }
    var configFile: URL { home.appending(path: ".brew_update_config") }
    var supportDirectory: URL {
        home.appending(path: "Library/Application Support/Brew Updates", directoryHint: .isDirectory)
    }
    /// The script the app and the LaunchAgent run: the app installs its bundled copy here
    /// (`ScriptInstaller`), outside the app bundle, so scheduled runs keep working while the
    /// app is moved or replaced by an update
    var deployedScript: URL { supportDirectory.appending(path: "brew-updates.sh") }
    /// What the LaunchAgent runs: a signed helper that execs `/bin/bash deployedScript …`, so
    /// macOS attributes the background job to the app instead of "bash" (Launcher/main.swift)
    var deployedLauncher: URL { supportDirectory.appending(path: Self.launcherName) }
    static let launcherName = "brew-updates-launcher"
    /// The installed script's name before script 2.7.0 (`brew-updates.command`); the app
    /// deletes it after installing `deployedScript`
    var retiredDeployedScript: URL { supportDirectory.appending(path: "brew-updates.command") }
    var launchAgentPlist: URL { launchAgentPlist(label: Self.launchAgentLabel) }
    var legacyLaunchAgentPlist: URL { launchAgentPlist(label: Self.legacyLaunchAgentLabel) }
    var launchAgentLog: URL { logDirectory.appending(path: "launchagent.log") }
    var launchAgentErrorLog: URL { logDirectory.appending(path: "launchagent_error.log") }
    /// Written by the app with its own location. When this points at an existing app, the
    /// script leaves its end-of-run notification to the app (`RunNotification`)
    var appMarker: URL { logDirectory.appending(path: ".brew-updates-app") }

    private func launchAgentPlist(label: String) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label).plist")
    }
}
