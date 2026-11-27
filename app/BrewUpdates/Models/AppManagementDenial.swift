import Foundation

/// Finding out whether macOS denied the launcher "App Management" during a scheduled run.
///
/// When a scheduled cask upgrade replaces an app from another developer, macOS's permission
/// daemon (`tccd`) logs the denied request against `brew-updates-launcher` and shows
/// "brew-updates-launcher was prevented from modifying apps on your Mac". Nothing else records
/// it (not the script's logs), so the app reads it from the unified log with `log show`.
/// This type is the pure part: the query and reading its output.
enum AppManagementDenial {
    /// tccd's name for the App Management permission
    static let service = "kTCCServiceSystemPolicyAppBundles"

    /// Matches only tccd entries that name this permission and the launcher
    static var predicate: String {
        "process == \"tccd\" AND eventMessage CONTAINS \"\(service)\" "
            + "AND eventMessage CONTAINS \"\(AppPaths.launcherName)\""
    }

    /// `log show` takes local-time dates in this form
    static func logArguments(from start: Date, to end: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["show", "--style", "compact", "--start", formatter.string(from: start),
                "--end", formatter.string(from: end), "--predicate", predicate]
    }

    /// True when `log show`'s output holds a matching tccd entry. The header it prints first
    /// ("Filtering the log data using ...") repeats the predicate, so only `tccd[` lines count.
    static func found(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.contains("tccd[") && line.contains(service) && line.contains(AppPaths.launcherName)
        }
    }
}
