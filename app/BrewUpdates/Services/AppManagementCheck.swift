import Foundation

/// Asks the macOS unified log whether a run's cask upgrades were denied App Management
/// (see `AppManagementDenial`). A narrow predicate keeps it to about a second or two.
struct AppManagementCheck: Sendable {
    /// Runs `log show`; replaced in tests
    typealias Runner = @Sendable ([String]) async throws -> String

    let runner: Runner

    init(runner: @escaping Runner = Self.runLogShow) {
        self.runner = runner
    }

    /// False when the log can't be read, so a failure never shows a false warning
    func wasDenied(from start: Date, to end: Date) async -> Bool {
        let arguments = AppManagementDenial.logArguments(from: start, to: end)
        guard let output = try? await runner(arguments) else { return false }
        return AppManagementDenial.found(in: output)
    }

    private static func runLogShow(_ arguments: [String]) async throws -> String {
        try await ProcessRunner.output(URL(filePath: "/usr/bin/log"), arguments: arguments).stdoutText
    }
}
