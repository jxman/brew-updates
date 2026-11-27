import Foundation
import Testing

@Suite("App Management check")
struct AppManagementCheckTests {
    @Test func reportsADenialFoundInTheLog() async {
        let line = "tccd[1:2] service=kTCCServiceSystemPolicyAppBundles brew-updates-launcher"
        let check = AppManagementCheck { _ in line }
        #expect(await check.wasDenied(from: .now, to: .now))
    }

    @Test func reportsNothingWhenTheLogHasNoEntry() async {
        let check = AppManagementCheck { _ in "Timestamp Ty Process[PID:TID]\n" }
        #expect(await !check.wasDenied(from: .now, to: .now))
    }

    @Test func neverWarnsWhenTheLogCantBeRead() async {
        struct Failure: Error {}
        let check = AppManagementCheck { _ in throw Failure() }
        #expect(await !check.wasDenied(from: .now, to: .now))
    }
}
