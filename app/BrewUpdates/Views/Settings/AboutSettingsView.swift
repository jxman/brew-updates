import AppKit
import SwiftUI

/// Versions, and how the app keeps itself up to date (Sparkle, `AppUpdater`). Unlike the other
/// tabs there is nothing to save: Sparkle stores these choices as soon as they change.
struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        // `@Bindable` makes `$updater.automaticallyChecks` available for an `@Observable`
        // object that came from the environment
        @Bindable var updater = updater
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brew Updates").font(.title3.weight(.semibold))
                        Text("Version \(AppVersion.current.description)")
                        Text("Update script \(model.scriptVersion?.description ?? "not installed")")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if updater.isEnabled {
                    Toggle("Check for app updates automatically", isOn: $updater.automaticallyChecks)
                    Toggle("Download and install them in the background", isOn: $updater.automaticallyDownloads)
                        .disabled(!updater.automaticallyChecks)
                    HStack {
                        Text(lastCheckText).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                } else {
                    Text("Development builds don't update themselves.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("App Updates")
            } footer: {
                Text("Updates to Brew Updates itself, checked once a day. Each one is signed and "
                    + "notarized, and brings its own update script, so scheduled runs pick it up too.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}
