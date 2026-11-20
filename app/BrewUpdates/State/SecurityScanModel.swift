import Foundation
import Observation

/// Scans started from the Security screen (Scan Now).
///
/// Like Doctor's Check Now, the result is kept in memory only: ~/.brew_logs belongs to the
/// script, and its scans still come from runs.
@MainActor
@Observable
final class SecurityScanModel {
    struct Scan: Sendable {
        let date: Date
        /// nil when that scanner failed (the reason is in `scanError`)
        let grype: [Vulnerability]?
        let brewVulns: BrewVulnsReport?
    }

    private(set) var latest: Scan?
    private(set) var isScanning = false
    var scanError: String?

    // grype is optional but recommended: without it only brew vulns runs, which can't see
    // libraries bundled inside formulae, and the trend chart has no data
    /// Found on the PATH runs use (`checkGrype`, at every refresh)
    private(set) var isGrypeInstalled = false
    private(set) var isInstallingGrype = false
    var grypeInstallError: String?

    private var scanner: SecurityScanner

    init(scanner: SecurityScanner) {
        self.scanner = scanner
    }

    /// Homebrew was installed (or removed) while the app was open (`AppModel.locateHomebrew`)
    func use(_ scanner: SecurityScanner) {
        self.scanner = scanner
    }

    /// Looks for grype where runs would find it
    func checkGrype(brewExecutable: URL?) {
        isGrypeInstalled = SecurityScanner.locate(in: BrewService.searchPath(brewExecutable: brewExecutable)) != nil
    }

    /// `brew install grype`, holding the run lock so it can't overlap a run (brew would refuse
    /// anyway, but with a less helpful error). Callers pass the brew they found, because the
    /// setup sheet can find a Homebrew installed after the model last looked.
    func installGrype(brewExecutable: URL?, paths: AppPaths) async {
        guard !isInstallingGrype else { return }
        isInstallingGrype = true
        grypeInstallError = nil
        defer { isInstallingGrype = false }

        let lock = RunLock(paths: paths)
        do {
            try lock.acquire()
            defer { lock.release() }
            try await BrewService(executable: brewExecutable).install(formula: "grype")
        } catch {
            grypeInstallError = error.localizedDescription
        }
        checkGrype(brewExecutable: brewExecutable)
        if !isGrypeInstalled, grypeInstallError == nil {
            grypeInstallError = "brew finished, but grype wasn't found afterwards."
        }
    }

    /// Runs both scanners at once. Returns true when at least one produced a report; a
    /// scanner that failed is reported in `scanError` without discarding the other's result.
    @discardableResult
    func scanNow() async -> Bool {
        guard !isScanning else { return false }
        isScanning = true
        defer { isScanning = false }

        // `async let` starts each scan as a child task straight away; the `await`s below
        // wait for both, so the total time is that of the slower one (grype)
        let scanner = scanner
        async let grypeScan = Self.capture { try await scanner.scan() }
        async let brewVulnsScan = Self.capture { try await scanner.scanBrewVulns() }
        let (grype, brewVulns) = await (grypeScan, brewVulnsScan)

        let errors = [grype.error, brewVulns.error].compactMap { $0?.localizedDescription }
        scanError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        guard grype.value != nil || brewVulns.value != nil else { return false }
        latest = Scan(date: .now, grype: grype.value, brewVulns: brewVulns.value)
        return true
    }

    /// A throwing scan's value or error, so one failing scanner doesn't cancel the other
    private static func capture<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async -> (value: T?, error: (any Error)?) {
        do {
            return (try await work(), nil)
        } catch {
            return (nil, error)
        }
    }
}
