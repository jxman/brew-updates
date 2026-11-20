import Foundation

enum ScriptInstallError: LocalizedError {
    case notBundled
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .notBundled:
            "The app doesn't contain the update script or its launcher. Reinstall Brew Updates."
        case .verificationFailed:
            "The update script was copied but the copy doesn't match the app's. Quit and reopen Brew Updates to try again."
        }
    }
}

/// Installs the script bundled inside the app to `AppPaths.deployedScript`, so the app and
/// the script always ship as a matched pair.
struct ScriptInstaller: Sendable {
    let paths: AppPaths

    /// Copies `bundled` over the installed script when it is missing or different.
    /// Returns true when it wrote a new copy.
    @discardableResult
    func install(from bundled: URL) throws -> Bool {
        try installFile(from: bundled, to: paths.deployedScript)
    }

    /// Copies the bundled launcher next to the script, the same way. Its code signature is
    /// inside the file, so the copy stays signed.
    @discardableResult
    func installLauncher(from bundled: URL) throws -> Bool {
        try installFile(from: bundled, to: paths.deployedLauncher)
    }

    private func installFile(from bundled: URL, to destination: URL) throws -> Bool {
        let source = try Data(contentsOf: bundled)
        if let installed = try? Data(contentsOf: destination), installed == source {
            return false
        }
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        // `.atomic` writes a temporary file and renames it over the old one. bash reads a
        // script as it runs, so overwriting the file in place could break a run in progress;
        // after a rename that run keeps reading the old file it already has open.
        try source.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        guard try Data(contentsOf: destination) == source else {
            throw ScriptInstallError.verificationFailed
        }
        return true
    }

    /// Deletes the copy installed under the script's old name (`brew-updates.command`). Call
    /// it only once the LaunchAgent runs `deployedScript`, or a scheduled run would find no
    /// script. Safe even mid-run: bash keeps reading the file it already has open.
    func removeRetiredCopy() {
        try? FileManager.default.removeItem(at: paths.retiredDeployedScript)
    }
}
