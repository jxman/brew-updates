import Foundation
import Synchronization

/// Stands in for `/bin/launchctl` so tests never touch the real launchd jobs. Records each
/// call; `print <target>` succeeds only for targets in `loaded`, `print-disabled` returns
/// `disabledOutput`, everything else succeeds.
final class FakeLaunchctl: Sendable {
    private struct State {
        var calls: [[String]] = []
        var loaded: Set<String> = []
        var disabledOutput = ""
    }

    private let state = Mutex(State())

    init(loaded: Set<String> = [], disabledOutput: String = "") {
        state.withLock {
            $0.loaded = loaded
            $0.disabledOutput = disabledOutput
        }
    }

    var calls: [[String]] { state.withLock { $0.calls } }
    /// Calls without the read-only `print` and `print-disabled` queries
    var changes: [[String]] { calls.filter { !["print", "print-disabled"].contains($0.first) } }

    var run: LaunchAgentService.Launchctl {
        { [self] arguments in
            let output: String? = state.withLock { state in
                state.calls.append(arguments)
                switch arguments.first {
                case "print": return state.loaded.contains(arguments[1]) ? "" : nil
                case "print-disabled": return state.disabledOutput
                default: return ""
                }
            }
            guard let output else {
                throw ProcessRunnerError.failed(command: "launchctl", exitCode: 113, stderr: "Could not find service")
            }
            return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }
    }
}
