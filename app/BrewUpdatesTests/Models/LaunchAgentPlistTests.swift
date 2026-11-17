import Foundation
import Testing

@Suite("LaunchAgent plist adoption")
struct LaunchAgentPlistTests {
    private let paths = AppPaths(home: URL(filePath: "/Users/me"))

    private let legacyPlist = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>com.user.brew-update</string>
      <key>ProgramArguments</key>
      <array><string>/bin/bash</string><string>/Users/me/bin/brew-updates.command</string>
             <string>--yes</string><string>--verbose</string></array>
      <key>EnvironmentVariables</key>
      <dict><key>ENABLE_NOTIFICATIONS</key><string>true</string></dict>
      <key>StartCalendarInterval</key>
      <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
      <key>StandardOutPath</key><string>/Users/me/.brew_logs/launchagent.log</string>
    </dict></plist>
    """.utf8)

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func adoptingSetsLabelScriptAndBundleIdentifier() throws {
        let plist = try dictionary(try LaunchAgentPlist.adopting(legacyPlist, paths: paths))
        #expect(plist["Label"] as? String == "com.jxman.brew-updates")
        #expect(plist["ProgramArguments"] as? [String] == [
            "/bin/bash", "/Users/me/Library/Application Support/Brew Updates/brew-updates.sh", "--yes", "--verbose"
        ])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.jxman.BrewUpdates"])
    }

    @Test func adoptingKeepsScheduleEnvironmentAndLogs() throws {
        let adopted = try LaunchAgentPlist.adopting(legacyPlist, paths: paths)
        let schedule = try Schedule.parse(plistData: adopted)
        #expect(schedule.intervals == [CalendarInterval(minute: 0, hour: 8)])
        let plist = try dictionary(adopted)
        #expect((plist["EnvironmentVariables"] as? [String: String])?["ENABLE_NOTIFICATIONS"] == "true")
        #expect(plist["StandardOutPath"] as? String == "/Users/me/.brew_logs/launchagent.log")
    }

    @Test func adoptingAddsBashWhenTheScriptRanDirectly() throws {
        let direct = Data("""
        <plist version="1.0"><dict><key>ProgramArguments</key>
        <array><string>/Users/me/bin/brew-updates.command</string><string>--yes</string></array></dict></plist>
        """.utf8)
        let plist = try dictionary(try LaunchAgentPlist.adopting(direct, paths: paths))
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/bash", paths.deployedScript.path, "--yes"])
    }

    @Test func isAdoptedOnlyAfterAdopting() throws {
        #expect(!LaunchAgentPlist.isAdopted(legacyPlist, paths: paths))
        let adopted = try LaunchAgentPlist.adopting(legacyPlist, paths: paths)
        #expect(LaunchAgentPlist.isAdopted(adopted, paths: paths))
        // Adopting twice doesn't add the bundle identifier again
        let twice = try dictionary(try LaunchAgentPlist.adopting(adopted, paths: paths))
        #expect(twice["AssociatedBundleIdentifiers"] as? [String] == ["com.jxman.BrewUpdates"])
    }

    @Test func makesANewPlistFromTheDraft() throws {
        var draft = ScheduleDraft()
        draft.frequency = .weekly
        draft.weekdays = [1, 5]
        draft.hour = 9
        draft.verbose = true
        let data = try LaunchAgentPlist.make(draft, paths: paths, searchPath: "/opt/homebrew/bin:/usr/bin:/bin")

        #expect(LaunchAgentPlist.isAdopted(data, paths: paths))
        let schedule = try Schedule.parse(plistData: data)
        #expect(schedule.intervals == [CalendarInterval(minute: 0, hour: 9, weekday: 1), CalendarInterval(minute: 0, hour: 9, weekday: 5)])
        #expect(schedule.scriptArguments == ["--yes", "--verbose"])
        let plist = try dictionary(data)
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/me"])
        #expect(plist["StandardOutPath"] as? String == "/Users/me/.brew_logs/launchagent.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/me/.brew_logs/launchagent_error.log")
    }

    @Test func readsDisabledStateInBothFormats() {
        let output = """
        disabled services = {
            "com.apple.Siri.agent" => enabled
            "com.user.brew-update" => disabled
            "com.jxman.brew-updates" => false
            "com.example.old" => true
        }
        """
        #expect(LaunchAgentPlist.isDisabled(label: "com.user.brew-update", printDisabledOutput: output))
        #expect(!LaunchAgentPlist.isDisabled(label: "com.jxman.brew-updates", printDisabledOutput: output))
        #expect(LaunchAgentPlist.isDisabled(label: "com.example.old", printDisabledOutput: output))
        #expect(!LaunchAgentPlist.isDisabled(label: "com.missing", printDisabledOutput: output))
    }
}
