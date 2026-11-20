import Foundation

/// Where the app is running from, and whether it has to be moved to Applications first.
///
/// The app writes its own path for the script (the notification marker) and installs the
/// LaunchAgent's helper from its bundle, so it must run from a copy that stays put. Opening it
/// straight from the downloaded disk image is the common mistake: that path disappears when
/// the image is ejected.
struct AppLocation: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        /// Opened from the disk image (a read-only volume under /Volumes)
        case diskImage
        /// macOS runs a downloaded app that hasn't been moved from a random read-only copy
        /// ("App Translocation") until it is
        case translocated
        /// Still in Downloads
        case downloads
    }

    let bundleURL: URL
    let home: URL
    /// Whether the bundle is on a read-only volume. Passed in so this stays pure: a disk image
    /// is read-only, an external drive the user keeps apps on usually isn't
    let isOnReadOnlyVolume: Bool

    var problem: Problem? {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") && isOnReadOnlyVolume { return .diskImage }
        if path.hasPrefix(home.appending(path: "Downloads").standardizedFileURL.path + "/") { return .downloads }
        return nil
    }

    var needsMove: Bool { problem != nil }

    /// Where the move puts it: /Applications, under the bundle's own name
    var destination: URL {
        URL(filePath: "/Applications", directoryHint: .isDirectory).appending(path: bundleURL.lastPathComponent)
    }

    /// The running app's location
    static var current: AppLocation {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return AppLocation(bundleURL: bundle, home: FileManager.default.homeDirectoryForCurrentUser, isOnReadOnlyVolume: readOnly)
    }
}
