import AppKit
import SwiftUI

/// Settings > Uninstall: removes what the app set up outside its bundle. Dragging the app to
/// the Trash alone would leave the LaunchAgent running the script every day.
struct UninstallSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var options = UninstallOptions()
    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var error: String?

    private var uninstaller: AppUninstaller { AppUninstaller(paths: model.paths) }

    var body: some View {
        if model.isUninstalled {
            finished
        } else {
            VStack(spacing: 0) {
                form
                Divider()
                bottomBar
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Label("The update schedule (LaunchAgent \(AppPaths.launchAgentLabel))", systemImage: "calendar.badge.minus")
                Label("The app's copy of the update script", systemImage: "doc.badge.gearshape")
            } header: {
                Text("Always Removed")
            } footer: {
                Text("Homebrew and the packages it installed are not touched.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run logs and security reports (~/.brew_logs)", isOn: $options.logs)
                Toggle("Brewfile backups (~/.brew_backups)", isOn: $options.backups)
                Toggle("Settings (~/.brew_update_config)", isOn: $options.config)
            } header: {
                Text("Also Remove")
            } footer: {
                Text("Removed items go to the Trash, so you can put them back until you empty it.")
                    .foregroundStyle(.secondary)
            }

            if FileManager.default.fileExists(atPath: uninstaller.commandLineScript.path) {
                Section {
                    Text("""
                    ~/bin/brew-updates.sh is kept: scripts/setup.sh installed it for running by hand. \
                    scripts/uninstall.sh removes it.
                    """)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else if model.isRunInProgress {
                Label("Wait for the running update to finish.", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Uninstall…", role: .destructive) { isConfirming = true }
                .disabled(isWorking || model.isRunInProgress)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // `confirmationDialog` is SwiftUI's sheet-style "Are you sure?" prompt. A button with
        // `role: .destructive` is drawn in red and `.cancel` is added for Escape.
        .confirmationDialog("Uninstall Brew Updates?", isPresented: $isConfirming) {
            Button("Uninstall", role: .destructive) { Task { await uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scheduled updates stop. \(uninstaller.items(for: options).count) items will be moved to the Trash.")
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Brew Updates is uninstalled")
                .font(.title2.bold())
            Text("""
            Scheduled updates are off. To finish, quit the app and move it to the Trash. \
            If you open it again instead, it offers to set everything up again.
            """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack {
                Button("Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Button("Quit Brew Updates") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.uninstall(options)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    UninstallSettingsView()
        .environment(AppModel())
}
