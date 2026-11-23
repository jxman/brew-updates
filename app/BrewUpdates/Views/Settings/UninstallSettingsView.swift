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
    @State private var trashError: String?
    @State private var didCopy = false
    /// What can be done about the app bundle itself. Passed in so previews can show each case;
    /// the app uses the plan for the running copy
    private let trashPlan: AppTrashPlan

    init(trashPlan: AppTrashPlan = .current) {
        self.trashPlan = trashPlan
    }

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
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Brew Updates is uninstalled")
                .font(.title2.bold())
            Text("Scheduled updates are off.")
                .foregroundStyle(.secondary)
            nextSteps
            if let trashError {
                Label(trashError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            finishedButtons
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What is left to do, as a card so it stands out from the confirmation above it. The
    /// command is a separate monospaced, selectable box: inside a plain `Text` the backticks
    /// would show literally (only a `LocalizedStringKey` or `AttributedString` renders Markdown).
    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next steps")
                .font(.headline)
            switch trashPlan {
            case .homebrewCask(let token):
                stepRow(1, "Quit Brew Updates.")
                stepRow(2, "Run this in Terminal to remove the app:")
                commandBox("brew uninstall --cask \(token)")
                Text("This copy came from Homebrew. Dragging it to the Trash instead would leave Homebrew thinking it is still installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .trash:
                stepRow(1, "Move Brew Updates to the Trash. The button below does it and quits.")
                Text("If you close this window and open the app again instead, it offers to set everything up again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .unavailable:
                stepRow(1, "Quit Brew Updates.")
                stepRow(2, "Move it to the Trash from Finder.")
                reopenNote
            }
        }
        .padding(16)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var reopenNote: some View {
        Text("If you open the app again instead, it offers to set everything up again.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    @ViewBuilder
    private var finishedButtons: some View {
        HStack {
            switch trashPlan {
            case .trash(let bundle):
                // One button: a plain Quit would leave the app installed, and the user would
                // have to guess that it isn't finished
                Button("Quit and Move App to Trash") { trashApp(bundle) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .homebrewCask:
                Button("Quit Brew Updates") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            case .unavailable:
                Button("Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Button("Quit Brew Updates") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Trashes the app, then quits. A failure (no permission) leaves the app open with the
    /// reason, so the user can still do it by hand.
    private func trashApp(_ bundle: URL) {
        do {
            try uninstaller.trashApp(bundle)
            NSApp.terminate(nil)
        } catch {
            trashError = "Couldn't move the app to the Trash: \(error.localizedDescription)"
        }
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

#Preview("Options") {
    UninstallSettingsView()
        .environment(AppModel())
}

// The finished screen has three versions, one per `AppTrashPlan`. The model is marked
// uninstalled so the preview skips the form. Previews don't uninstall anything: the buttons
// only act when clicked in the running app.
#Preview("Finished: in Applications") {
    finishedPreview(.trash(URL(filePath: "/Applications/Brew Updates.app")))
}

#Preview("Finished: Homebrew cask") {
    finishedPreview(.homebrewCask(token: "brew-updates"))
}

#Preview("Finished: elsewhere") {
    finishedPreview(.unavailable)
}

@MainActor
private func finishedPreview(_ plan: AppTrashPlan) -> some View {
    let model = AppModel()
    model.isUninstalled = true
    return UninstallSettingsView(trashPlan: plan)
        .environment(model)
        // About the size of a small Settings window, so a cramped layout shows here first
        .frame(width: 600, height: 460)
}
