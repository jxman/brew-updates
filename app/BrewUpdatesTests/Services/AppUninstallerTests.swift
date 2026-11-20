import Foundation
import Testing

@Suite("App uninstaller")
struct AppUninstallerTests {
    private let domain = "gui/\(getuid())"

    /// A home folder with everything the app and setup.sh create
    private func makeInstalledHome() throws -> (TemporaryHome, AppPaths) {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        let fileManager = FileManager.default
        for folder in [paths.launchAgentPlist.deletingLastPathComponent(), paths.supportDirectory,
                       paths.logDirectory, paths.backupDirectory, paths.home.appending(path: "bin")] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [paths.launchAgentPlist, paths.launchAgentPlist.appendingPathExtension("app-backup"),
                     paths.legacyLaunchAgentPlist.appendingPathExtension("migrated"), paths.deployedScript,
                     paths.appMarker, paths.logDirectory.appending(path: "brew_update_1.log"),
                     paths.backupDirectory.appending(path: "Brewfile_1"), paths.configFile,
                     paths.home.appending(path: "bin/brew-updates.sh")] {
            try Data("x".utf8).write(to: file)
        }
        return (home, paths)
    }

    private func uninstaller(_ paths: AppPaths, _ launchctl: FakeLaunchctl) -> AppUninstaller {
        AppUninstaller(paths: paths, launchctl: launchctl.run) { try FileManager.default.removeItem(at: $0) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func removesScheduleAndScriptButKeepsDataByDefault() async throws {
        let (home, paths) = try makeInstalledHome()
        let launchctl = FakeLaunchctl()

        try await uninstaller(paths, launchctl).uninstall(UninstallOptions())

        #expect(!exists(paths.launchAgentPlist))
        #expect(!exists(paths.launchAgentPlist.appendingPathExtension("app-backup")))
        #expect(!exists(paths.legacyLaunchAgentPlist.appendingPathExtension("migrated")))
        #expect(!exists(paths.supportDirectory))
        #expect(!exists(paths.appMarker))
        // Kept: data, and the ~/bin copy the app didn't install
        #expect(exists(paths.logDirectory.appending(path: "brew_update_1.log")))
        #expect(exists(paths.backupDirectory))
        #expect(exists(paths.configFile))
        #expect(exists(paths.home.appending(path: "bin/brew-updates.sh")))
        // The run lock is released again
        #expect(!exists(paths.lockPIDFile.deletingLastPathComponent()))
        #expect(launchctl.changes == [
            ["bootout", "\(domain)/com.jxman.brew-updates"],
            ["bootout", "\(domain)/com.user.brew-update"]
        ])
        _ = home
    }

    @Test func removesDataWhenAsked() async throws {
        let (home, paths) = try makeInstalledHome()

        let removed = try await uninstaller(paths, FakeLaunchctl())
            .uninstall(UninstallOptions(logs: true, backups: true, config: true))

        #expect(!exists(paths.logDirectory))
        #expect(!exists(paths.backupDirectory))
        #expect(!exists(paths.configFile))
        // The marker went with the log folder, not on its own
        #expect(!removed.contains(paths.appMarker))
        #expect(removed.contains(paths.logDirectory))
        _ = home
    }

    @Test func listsOnlyWhatExists() throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        #expect(AppUninstaller(paths: paths).items(for: UninstallOptions(logs: true, backups: true, config: true)).isEmpty)
    }

    @Test func refusesWhileARunHoldsTheLock() async throws {
        let (home, paths) = try makeInstalledHome()
        // A live process (this one's parent) holds the lock, as the script would
        try FileManager.default.createDirectory(at: paths.lockPIDFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(getppid())\n".utf8).write(to: paths.lockPIDFile)
        let launchctl = FakeLaunchctl()

        await #expect(throws: RunLockError.self) {
            try await uninstaller(paths, launchctl).uninstall(UninstallOptions())
        }
        #expect(exists(paths.launchAgentPlist))
        #expect(launchctl.calls.isEmpty)
        _ = home
    }
}
