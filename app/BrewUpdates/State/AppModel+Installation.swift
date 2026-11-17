import Foundation
import os

// Setting up what the app needs outside its bundle: the update script and the LaunchAgent.
// This replaces what scripts/setup.sh did for app users.
extension AppModel {
    private static let log = Logger(subsystem: AppPaths.appBundleIdentifier, category: "installation")

    /// Installs the script bundled in the app (when the installed copy is missing or
    /// different, e.g. after an app update), then moves an existing LaunchAgent over to it.
    /// Runs at every launch; does nothing when everything is already in place.
    func prepareInstallation() async {
        // `Bundle.main` is the app itself; project.yml copies brew-updates.sh from the
        // repo root into its Resources folder
        guard let bundled = Bundle.main.url(forResource: "brew-updates", withExtension: "sh") else {
            installationError = ScriptInstallError.notBundled.localizedDescription
            return
        }
        do {
            if try ScriptInstaller(paths: paths).install(from: bundled) {
                Self.log.info("Installed the bundled script at \(self.paths.deployedScript.path, privacy: .public)")
            }
        } catch {
            installationError = "Couldn't install the update script: \(error.localizedDescription)"
            return
        }

        // Moving the LaunchAgent reloads it, which would stop a scheduled run in progress.
        // Holding the run lock rules that out; if a run has it, try again at the next launch.
        let lock = RunLock(paths: paths)
        do {
            try lock.acquire()
        } catch {
            Self.log.info("Run in progress, LaunchAgent check postponed to the next launch")
            return
        }
        defer { lock.release() }
        do {
            let result = try await LaunchAgentService(paths: paths).adoptExistingAgent()
            Self.log.info("LaunchAgent: \(String(describing: result), privacy: .public)")
            // The LaunchAgent (if any) now runs deployedScript, so the old copy is unused
            ScriptInstaller(paths: paths).removeRetiredCopy()
            installationError = nil
        } catch {
            installationError = "Couldn't move the schedule over to the app's script: \(error.localizedDescription)"
        }
    }
}
