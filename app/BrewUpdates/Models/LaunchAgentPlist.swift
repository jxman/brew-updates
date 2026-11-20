import Foundation

/// Reads and rewrites the LaunchAgent plist so it points at the app's label and installed
/// script, keeping everything else (schedule, flags, environment, log paths) as it is.
enum LaunchAgentPlist {
    /// True when the plist already has the app's label, launcher, script and bundle identifier.
    static func isAdopted(_ data: Data, paths: AppPaths) -> Bool {
        guard let plist = try? dictionary(from: data) else { return false }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
        return plist["Label"] as? String == AppPaths.launchAgentLabel
            && arguments.first == paths.deployedLauncher.path
            && arguments.dropFirst().first == paths.deployedScript.path
            && associated.contains(AppPaths.appBundleIdentifier)
    }

    /// The plist with the app's label, `<launcher> <installed script>` followed by the
    /// existing flags, and the app's bundle identifier; every other key unchanged. Plists from
    /// before app 1.5.0 ran `/bin/bash` directly, which macOS shows as "bash".
    static func adopting(_ data: Data, paths: AppPaths) throws -> Data {
        var plist = try dictionary(from: data)
        plist["Label"] = AppPaths.launchAgentLabel

        // Flags are everything after the program part (launcher or `/bin/bash`, script path)
        let existing = plist["ProgramArguments"] as? [String] ?? []
        let flags = existing.drop { !$0.hasPrefix("-") }
        plist["ProgramArguments"] = [paths.deployedLauncher.path, paths.deployedScript.path] + flags

        var associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
        if !associated.contains(AppPaths.appBundleIdentifier) {
            associated.append(AppPaths.appBundleIdentifier)
        }
        plist["AssociatedBundleIdentifiers"] = associated

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// A new plist for a Mac without a LaunchAgent (first-run setup): the draft's schedule
    /// and flags, the given PATH (`BrewService.searchPath`) and the app's log files.
    /// Notifications aren't set here: `ENABLE_NOTIFICATIONS` in `~/.brew_update_config` (what
    /// Settings > Updates edits) overrides the environment anyway.
    static func make(_ draft: ScheduleDraft, paths: AppPaths, searchPath: String) throws -> Data {
        let intervals = draft.intervals.map(\.plistDictionary)
        let plist: [String: Any] = [
            "Label": AppPaths.launchAgentLabel,
            "ProgramArguments": [paths.deployedLauncher.path, paths.deployedScript.path] + draft.scriptArguments,
            "EnvironmentVariables": ["PATH": searchPath, "HOME": paths.home.path],
            "StartCalendarInterval": intervals.count == 1 ? intervals[0] as Any : intervals as Any,
            "StandardOutPath": paths.launchAgentLog.path,
            "StandardErrorPath": paths.launchAgentErrorLog.path,
            "AssociatedBundleIdentifiers": [AppPaths.appBundleIdentifier]
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Whether `launchctl print-disabled gui/<uid>` lists the label as disabled. Recent
    /// macOS prints `"label" => disabled`, older versions `"label" => true`.
    static func isDisabled(label: String, printDisabledOutput output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "\"\(label)\"" else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            return state == "disabled" || state == "true"
        }
        return false
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return plist
    }
}
