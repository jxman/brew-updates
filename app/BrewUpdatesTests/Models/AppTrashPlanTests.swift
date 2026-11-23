import Foundation
import Testing

@Suite("App trash plan")
struct AppTrashPlanTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func plan(_ path: String, cask: Bool = false) -> AppTrashPlan {
        AppTrashPlan(bundleURL: URL(filePath: path), home: home, isHomebrewCask: cask)
    }

    @Test func trashesAnAppInApplications() {
        let url = URL(filePath: "/Applications/Brew Updates.app").standardizedFileURL
        #expect(plan("/Applications/Brew Updates.app") == .trash(url))
    }

    @Test func trashesAnAppInTheUsersApplications() {
        let url = URL(filePath: "/Users/someone/Applications/Brew Updates.app").standardizedFileURL
        #expect(plan("/Users/someone/Applications/Brew Updates.app") == .trash(url))
    }

    @Test func leavesAHomebrewCaskToHomebrew() {
        #expect(plan("/Applications/Brew Updates.app", cask: true) == .homebrewCask(token: "brew-updates"))
    }

    @Test func neverTouchesBuildsOrOtherLocations() {
        #expect(plan("/Users/someone/Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/Brew Updates.app") == .unavailable)
        #expect(plan("/Volumes/Brew Updates/Brew Updates.app") == .unavailable)
        #expect(plan("/private/var/folders/xx/AppTranslocation/ABC/d/Brew Updates.app") == .unavailable)
        #expect(plan("/Users/someone/Downloads/Brew Updates.app") == .unavailable)
    }

    @Test func refusesAFolderThatIsNotAnAppBundle() {
        #expect(plan("/Applications/Utilities") == .unavailable)
    }

    @Test func refusesANestedBundle() {
        #expect(plan("/Applications/Other.app/Contents/Brew Updates.app") == .unavailable)
    }
}
