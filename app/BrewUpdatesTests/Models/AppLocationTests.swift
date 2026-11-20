import Foundation
import Testing

@Suite("App location")
struct AppLocationTests {
    private let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    private func location(_ path: String, readOnly: Bool = false) -> AppLocation {
        AppLocation(bundleURL: URL(filePath: path, directoryHint: .isDirectory), home: home, isOnReadOnlyVolume: readOnly)
    }

    @Test func applicationsFoldersAreFine() {
        #expect(location("/Applications/Brew Updates.app").problem == nil)
        #expect(location("/Users/me/Applications/Brew Updates.app").problem == nil)
        // A development build
        #expect(location("/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/Brew Updates.app").problem == nil)
    }

    @Test func diskImageIsReadOnlyVolume() {
        #expect(location("/Volumes/Install Brew Updates/Brew Updates.app", readOnly: true).problem == .diskImage)
        // An external drive someone keeps apps on is writable, so it's left alone
        #expect(location("/Volumes/External/Applications/Brew Updates.app").problem == nil)
    }

    @Test func translocatedAndDownloads() {
        let translocated = "/private/var/folders/ab/T/AppTranslocation/1234-ABCD/d/Brew Updates.app"
        #expect(location(translocated, readOnly: true).problem == .translocated)
        #expect(location("/Users/me/Downloads/Brew Updates.app").problem == .downloads)
        // Only that user's Downloads folder, not one that just starts with the same letters
        #expect(location("/Users/me/DownloadsArchive/Brew Updates.app").problem == nil)
    }

    @Test func destinationKeepsTheBundleName() {
        #expect(location("/Volumes/X/Brew Updates.app", readOnly: true).destination.path == "/Applications/Brew Updates.app")
    }
}
