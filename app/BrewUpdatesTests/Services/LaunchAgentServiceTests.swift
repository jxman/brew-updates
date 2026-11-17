import Foundation
import Testing

@Suite("LaunchAgent service")
struct LaunchAgentServiceTests {
    private let domain = "gui/\(getuid())"
    private var newTarget: String { "\(domain)/com.jxman.brew-updates" }
    private var legacyTarget: String { "\(domain)/com.user.brew-update" }

    private let legacyPlist = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>com.user.brew-update</string>
      <key>ProgramArguments</key>
      <array><string>/bin/bash</string><string>/Users/me/bin/brew-updates.sh</string>
             <string>--yes</string><string>--verbose</string></array>
      <key>StartCalendarInterval</key>
      <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
    </dict></plist>
    """.utf8)

    private func makeLaunchAgentsFolder(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: Schedule editing

    @Test func savesPlistAndKeepsBackupWithoutTouchingLaunchd() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        let original = try ScheduleDraft().updatedPlist(Data("""
        <plist version="1.0"><dict><key>ProgramArguments</key><array><string>/bin/bash</string><string>s</string></array></dict></plist>
        """.utf8))
        try original.write(to: paths.launchAgentPlist)

        var draft = ScheduleDraft()
        draft.hour = 22
        let launchctl = FakeLaunchctl()
        try await LaunchAgentService(paths: paths, launchctl: launchctl.run).save(draft, isLoaded: false)

        let saved = try Schedule.parse(plistData: try Data(contentsOf: paths.launchAgentPlist))
        #expect(saved.intervals == [CalendarInterval(minute: 0, hour: 22)])
        #expect(try Data(contentsOf: paths.launchAgentPlist.appendingPathExtension("app-backup")) == original)
        #expect(launchctl.calls.isEmpty)
    }

    @Test func refusesWhenNotInstalled() async throws {
        let home = try TemporaryHome()
        await #expect(throws: LaunchAgentError.self) {
            try await LaunchAgentService(paths: AppPaths(home: home.url), launchctl: FakeLaunchctl().run)
                .save(ScheduleDraft(), isLoaded: false)
        }
    }

    // MARK: First-run install

    @Test func installsAndLoadsANewAgent() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        let launchctl = FakeLaunchctl()

        try await LaunchAgentService(paths: paths, launchctl: launchctl.run).install(ScheduleDraft(), searchPath: "/usr/bin:/bin")

        let plist = try Data(contentsOf: paths.launchAgentPlist)
        #expect(LaunchAgentPlist.isAdopted(plist, paths: paths))
        #expect(try Schedule.parse(plistData: plist).intervals == [CalendarInterval(minute: 0, hour: 3)])
        // launchd needs the log folder to exist before it can start the job
        #expect(FileManager.default.fileExists(atPath: paths.logDirectory.path))
        #expect(launchctl.changes == [
            ["enable", newTarget],
            ["bootout", newTarget],
            ["bootstrap", domain, paths.launchAgentPlist.path]
        ])
    }

    @Test(arguments: [false, true])
    func refusesToInstallOverAnExistingAgent(legacy: Bool) async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        let existing = legacy ? paths.legacyLaunchAgentPlist : paths.launchAgentPlist
        try legacyPlist.write(to: existing)
        let launchctl = FakeLaunchctl()

        await #expect(throws: LaunchAgentError.self) {
            try await LaunchAgentService(paths: paths, launchctl: launchctl.run).install(ScheduleDraft(), searchPath: "/bin")
        }
        #expect(try Data(contentsOf: existing) == legacyPlist)
        #expect(launchctl.calls.isEmpty)
    }

    // MARK: Adopting an existing LaunchAgent

    @Test func migratesAnEnabledLegacyAgent() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        try legacyPlist.write(to: paths.legacyLaunchAgentPlist)
        let launchctl = FakeLaunchctl(loaded: [legacyTarget])

        let result = try await LaunchAgentService(paths: paths, launchctl: launchctl.run).adoptExistingAgent()

        #expect(result == .migratedFromLegacy)
        let adopted = try Data(contentsOf: paths.launchAgentPlist)
        #expect(LaunchAgentPlist.isAdopted(adopted, paths: paths))
        #expect(try Schedule.parse(plistData: adopted).intervals == [CalendarInterval(minute: 0, hour: 8)])
        #expect(!FileManager.default.fileExists(atPath: paths.legacyLaunchAgentPlist.path))
        #expect(try Data(contentsOf: paths.legacyLaunchAgentPlist.appendingPathExtension("migrated")) == legacyPlist)
        #expect(launchctl.changes == [
            ["bootout", legacyTarget],
            ["enable", newTarget],
            ["bootout", newTarget],
            ["bootstrap", domain, paths.launchAgentPlist.path]
        ])
    }

    @Test func keepsADisabledLegacyAgentOff() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        try legacyPlist.write(to: paths.legacyLaunchAgentPlist)
        let launchctl = FakeLaunchctl(disabledOutput: "\"com.user.brew-update\" => disabled\n")

        let result = try await LaunchAgentService(paths: paths, launchctl: launchctl.run).adoptExistingAgent()

        #expect(result == .migratedFromLegacy)
        #expect(launchctl.changes == [
            ["bootout", legacyTarget],
            ["disable", newTarget],
            ["bootout", newTarget]
        ])
    }

    @Test func repointsALoadedAgentAtTheInstalledScript() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        // Same label, but runs ~/bin (as scripts/setup.sh makes it)
        var plist = try #require(try PropertyListSerialization.propertyList(from: legacyPlist, format: nil) as? [String: Any])
        plist["Label"] = "com.jxman.brew-updates"
        let original = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try original.write(to: paths.launchAgentPlist)
        let launchctl = FakeLaunchctl(loaded: [newTarget])

        let result = try await LaunchAgentService(paths: paths, launchctl: launchctl.run).adoptExistingAgent()

        #expect(result == .repointed)
        #expect(LaunchAgentPlist.isAdopted(try Data(contentsOf: paths.launchAgentPlist), paths: paths))
        #expect(try Data(contentsOf: paths.launchAgentPlist.appendingPathExtension("app-backup")) == original)
        #expect(launchctl.changes == [["bootout", newTarget], ["bootstrap", domain, paths.launchAgentPlist.path]])
    }

    @Test func leavesAnAdoptedAgentAlone() async throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try makeLaunchAgentsFolder(paths)
        try LaunchAgentPlist.adopting(legacyPlist, paths: paths).write(to: paths.launchAgentPlist)
        let launchctl = FakeLaunchctl(loaded: [newTarget])

        #expect(try await LaunchAgentService(paths: paths, launchctl: launchctl.run).adoptExistingAgent() == .unchanged)
        #expect(launchctl.changes.isEmpty)
    }

    @Test func doesNothingWithoutAnAgent() async throws {
        let home = try TemporaryHome()
        let launchctl = FakeLaunchctl()
        let service = LaunchAgentService(paths: AppPaths(home: home.url), launchctl: launchctl.run)
        #expect(try await service.adoptExistingAgent() == .none)
        #expect(launchctl.calls.isEmpty)
    }
}
