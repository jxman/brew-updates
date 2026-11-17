import Foundation

enum LaunchAgentError: LocalizedError {
    case notInstalled
    case runInProgress
    case reloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The LaunchAgent isn't installed. Run scripts/setup.sh in the repo to install it."
        case .runInProgress:
            "An update is running. Reloading the LaunchAgent now would stop a scheduled run, so wait until it finishes."
        case .reloadFailed(let detail):
            "The schedule was saved, but launchd couldn't reload it: \(detail)"
        }
    }
}

/// What `adoptExistingAgent` changed
enum LaunchAgentAdoption: Equatable, Sendable {
    /// No LaunchAgent exists yet
    case none
    /// Already uses the app's label and installed script
    case unchanged
    /// Moved from `com.user.brew-update` to the app's label
    case migratedFromLegacy
    /// Same label, but now runs the app's installed script
    case repointed
}

/// Changes the LaunchAgent: its schedule and flags (by rewriting the plist) and whether
/// launchd runs it at all.
///
/// launchd reads the plist only when the job is loaded, so every change is followed by
/// `launchctl bootout` + `bootstrap`, the same reload `scripts/setup.sh` does.
struct LaunchAgentService: Sendable {
    /// Runs `/bin/launchctl` with the given arguments. Tests pass a fake, so they never
    /// touch the real launchd jobs.
    typealias Launchctl = @Sendable ([String]) async throws -> ProcessResult

    let paths: AppPaths
    private let launchctl: Launchctl

    init(paths: AppPaths, launchctl: @escaping Launchctl = LaunchAgentService.systemLaunchctl) {
        self.paths = paths
        self.launchctl = launchctl
    }

    static let systemLaunchctl: Launchctl = { arguments in
        try await ProcessRunner.output(URL(filePath: "/bin/launchctl"), arguments: arguments)
    }

    private var domain: String { "gui/\(getuid())" }
    private var target: String { "\(domain)/\(AppPaths.launchAgentLabel)" }
    private var legacyTarget: String { "\(domain)/\(AppPaths.legacyLaunchAgentLabel)" }
    private var backupURL: URL { paths.launchAgentPlist.appendingPathExtension("app-backup") }

    /// Writes the draft into the plist and reloads the job if it was loaded.
    /// The previous plist is kept as `<plist>.app-backup`.
    func save(_ draft: ScheduleDraft, isLoaded: Bool) async throws {
        let plistURL = paths.launchAgentPlist
        guard FileManager.default.fileExists(atPath: plistURL.path) else { throw LaunchAgentError.notInstalled }

        let original = try Data(contentsOf: plistURL)
        let updated = try draft.updatedPlist(original)
        try original.write(to: backupURL, options: .atomic)
        try updated.write(to: plistURL, options: .atomic)

        if isLoaded {
            try await reload()
        }
    }

    /// Turning the schedule off uses `launchctl disable`, which survives logging out and
    /// back in; a plain `bootout` would be undone at the next login.
    func setEnabled(_ enabled: Bool) async throws {
        guard FileManager.default.fileExists(atPath: paths.launchAgentPlist.path) else { throw LaunchAgentError.notInstalled }
        if enabled {
            _ = try await launchctl(["enable", target])
            try await reload()
        } else {
            _ = try await launchctl(["disable", target])
            // Fails harmlessly when the job isn't loaded
            _ = try? await launchctl(["bootout", target])
        }
    }

    /// Makes an existing LaunchAgent run the app's installed script under the app's label,
    /// keeping its schedule, flags and on/off state.
    ///
    /// - A `com.user.brew-update` agent from `scripts/setup.sh` is moved to the new label:
    ///   the new plist is written, the old job stopped and its plist renamed to
    ///   `<plist>.migrated`, then the new job loaded (or left disabled, as the old one was).
    /// - An agent that already has the new label but runs another script (e.g. `~/bin`, from
    ///   `setup.sh`) is pointed at the installed script and reloaded if it was loaded.
    ///
    /// The caller must hold the run lock: stopping the old job would kill a run in progress.
    func adoptExistingAgent() async throws -> LaunchAgentAdoption {
        let fileManager = FileManager.default
        let hasLegacy = fileManager.fileExists(atPath: paths.legacyLaunchAgentPlist.path)
        let hasCurrent = fileManager.fileExists(atPath: paths.launchAgentPlist.path)

        if hasLegacy {
            try await migrateLegacy(keepingCurrent: hasCurrent)
            return .migratedFromLegacy
        }
        guard hasCurrent else { return .none }

        let original = try Data(contentsOf: paths.launchAgentPlist)
        guard !LaunchAgentPlist.isAdopted(original, paths: paths) else { return .unchanged }
        let wasLoaded = await isLoaded(target)
        try original.write(to: backupURL, options: .atomic)
        try LaunchAgentPlist.adopting(original, paths: paths).write(to: paths.launchAgentPlist, options: .atomic)
        if wasLoaded {
            try await reload()
        }
        return .repointed
    }

    private func migrateLegacy(keepingCurrent hasCurrent: Bool) async throws {
        let legacyPlist = paths.legacyLaunchAgentPlist
        let disabled = await isDisabled(AppPaths.legacyLaunchAgentLabel)

        // An agent under the new label wins (only an old setup.sh would have recreated the
        // legacy one next to it); otherwise the legacy plist becomes the new one
        let source = hasCurrent ? paths.launchAgentPlist : legacyPlist
        let original = try Data(contentsOf: source)
        if hasCurrent {
            try original.write(to: backupURL, options: .atomic)
        }
        try LaunchAgentPlist.adopting(original, paths: paths).write(to: paths.launchAgentPlist, options: .atomic)

        // Stop the old job and keep its plist under another name, so launchd won't load it
        // again at the next login
        _ = try? await launchctl(["bootout", legacyTarget])
        let archived = legacyPlist.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: archived)
        try FileManager.default.moveItem(at: legacyPlist, to: archived)

        if disabled {
            _ = try await launchctl(["disable", target])
            _ = try? await launchctl(["bootout", target])
        } else {
            _ = try await launchctl(["enable", target])
            try await reload()
        }
    }

    private func isLoaded(_ target: String) async -> Bool {
        (try? await launchctl(["print", target])) != nil
    }

    private func isDisabled(_ label: String) async -> Bool {
        guard let result = try? await launchctl(["print-disabled", domain]) else { return false }
        return LaunchAgentPlist.isDisabled(label: label, printDisabledOutput: result.stdoutText)
    }

    private func reload() async throws {
        _ = try? await launchctl(["bootout", target])
        // bootout finishes asynchronously, so an immediate bootstrap can fail with
        // "Input/output error"; retry briefly
        var lastError: Error?
        for attempt in 0..<5 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(300))
            }
            do {
                _ = try await launchctl(["bootstrap", domain, paths.launchAgentPlist.path])
                return
            } catch {
                lastError = error
            }
        }
        throw LaunchAgentError.reloadFailed(lastError?.localizedDescription ?? "unknown error")
    }
}
