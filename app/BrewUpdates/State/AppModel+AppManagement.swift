import AppKit
import Foundation

// MARK: - App Management notice

// macOS blocks background programs from changing other developers' apps unless they have the
// App Management permission. The scheduled job is the launcher, so a scheduled cask upgrade
// can make macOS show "brew-updates-launcher was prevented from modifying apps on your Mac".
// The upgrade still works, but the message looks like an error, so the app explains it.
extension AppModel {
    private static let seenKey = "appManagementDenialSeen"
    private static let dismissedKey = "appManagementNoticeDismissed"
    private static let checkedRunKey = "appManagementCheckedRunID"
    /// `-ShowAppManagementNotice YES` shows the banner for one launch, like `-ShowSetup YES`
    private static let previewKey = "ShowAppManagementNotice"

    /// Looks at the newest scheduled run when it upgraded casks and hasn't been looked at yet.
    /// macOS only logs a first denial, so a hit is remembered until the banner is dismissed.
    func checkAppManagementDenial() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.previewKey) {
            appManagementNotice = true
            return
        }
        guard !defaults.bool(forKey: Self.dismissedKey) else { return }
        if defaults.bool(forKey: Self.seenKey) {
            appManagementNotice = true
            return
        }
        // Only scheduled runs go through the launcher, and only cask upgrades change apps
        guard let run = latestSummarizedRun, let summary = run.summary,
              summary.trigger == "scheduled", !summary.upgraded.casks.isEmpty,
              defaults.string(forKey: Self.checkedRunKey) != run.id else { return }
        defaults.set(run.id, forKey: Self.checkedRunKey)
        let end = summary.finishedAt.addingTimeInterval(60)
        if await AppManagementCheck().wasDenied(from: summary.startedAt.addingTimeInterval(-5), to: end) {
            defaults.set(true, forKey: Self.seenKey)
            appManagementNotice = true
        }
    }

    /// "Dismiss": hides the banner for good (macOS offers no way to see if it was allowed)
    func dismissAppManagementNotice() {
        if !UserDefaults.standard.bool(forKey: Self.previewKey) {
            UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        }
        appManagementNotice = false
    }

    /// Privacy & Security > App Management (`Privacy_AppBundles` is that pane's anchor)
    func openAppManagementSettings() {
        let link = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}
