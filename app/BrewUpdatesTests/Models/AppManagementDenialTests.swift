import Foundation
import Testing

@Suite("App Management denial")
struct AppManagementDenialTests {
    private let header = "Filtering the log data using \"\(AppManagementDenial.predicate)\"\n"
        + "Timestamp               Ty Process[PID:TID]\n"

    @Test func ignoresTheHeaderWhenNothingMatched() {
        #expect(!AppManagementDenial.found(in: header))
    }

    @Test func findsTheTccdEntryNamingTheLauncher() {
        let line = "2026-11-27 08:01:17.785 Df tccd[980:6b7e9c] [com.apple.TCC:events] Publishing "
            + "<TCCDEvent: type=Create, service=kTCCServiceSystemPolicyAppBundles, "
            + "identifier=/Users/x/Library/Application Support/Brew Updates/brew-updates-launcher>"
        #expect(AppManagementDenial.found(in: header + line))
    }

    @Test func ignoresOtherPrograms() {
        let line = "2026-11-27 08:01:17.785 Df tccd[980:6b7e9c] Publishing service=kTCCServiceSystemPolicyAppBundles "
            + "identifier=/Applications/Other.app"
        #expect(!AppManagementDenial.found(in: header + line))
    }

    @Test func buildsLogShowArgumentsForTheWindow() {
        let start = Date(timeIntervalSince1970: 0)
        let arguments = AppManagementDenial.logArguments(from: start, to: start.addingTimeInterval(60))
        #expect(arguments.first == "show")
        #expect(arguments.contains(AppManagementDenial.predicate))
        #expect(arguments.contains("--start"))
    }
}
