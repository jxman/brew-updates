// brew-updates-launcher: what the LaunchAgent runs instead of /bin/bash.
//
// It only replaces itself with `/bin/bash <arguments>` (the plist passes the installed script
// and its flags). It exists so the scheduled job's program is signed with the app's team ID:
// macOS links a background job to its app (`AssociatedBundleIdentifiers`) only then, and
// otherwise lists it in Login Items as "bash" from an "Unknown Developer".
//
// The app installs it next to the script in ~/Library/Application Support/Brew Updates/
// (ScriptInstaller). execv keeps the process and its environment, so the script still sees
// launchd's XPC_SERVICE_NAME and records the run as scheduled.
import Darwin

let bash = "/bin/bash"
let arguments = [bash] + CommandLine.arguments.dropFirst()
var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
argv.append(nil)
execv(bash, argv)
// Only reached when exec fails
perror("brew-updates-launcher: \(bash)")
exit(127)
