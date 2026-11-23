import Foundation

/// What the Uninstall screen can do about the app bundle itself once everything else is gone.
///
/// Only an app in Applications is moved to the Trash. A Homebrew cask is left to Homebrew:
/// trashing it by hand leaves its record in the Caskroom, so a later `brew install --cask`
/// fails with "there is already an App". Anything else (a Debug build in DerivedData, a
/// translocated copy, the disk image) is never touched.
enum AppTrashPlan: Equatable, Sendable {
    /// Move the bundle to the Trash
    case trash(URL)
    /// Installed by Homebrew; the user runs `brew uninstall --cask <token>`
    case homebrewCask(token: String)
    /// Not somewhere the app should delete itself from
    case unavailable

    static let caskToken = "brew-updates"

    /// - Parameters:
    ///   - bundleURL: the running app
    ///   - home: the user's home folder (for ~/Applications)
    ///   - isHomebrewCask: whether the Caskroom has a folder for this cask
    init(bundleURL: URL, home: URL, isHomebrewCask: Bool) {
        if isHomebrewCask {
            self = .homebrewCask(token: Self.caskToken)
            return
        }
        let bundle = bundleURL.standardizedFileURL
        let applications = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory)
        ].map(\.standardizedFileURL)
        let isInApplications = applications.contains { $0 == bundle.deletingLastPathComponent() }
        self = bundle.pathExtension == "app" && isInApplications ? .trash(bundle) : .unavailable
    }

    /// The plan for the running app. Apple silicon Homebrew keeps its Caskroom in
    /// /opt/homebrew, Intel in /usr/local
    static var current: AppTrashPlan {
        let isCask = ["/opt/homebrew", "/usr/local"].contains {
            FileManager.default.fileExists(atPath: "\($0)/Caskroom/\(caskToken)")
        }
        return AppTrashPlan(
            bundleURL: Bundle.main.bundleURL,
            home: FileManager.default.homeDirectoryForCurrentUser,
            isHomebrewCask: isCask
        )
    }
}
