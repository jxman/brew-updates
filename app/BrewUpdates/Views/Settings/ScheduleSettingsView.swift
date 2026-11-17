import SwiftUI

/// When the LaunchAgent runs the script, and with which options.
struct ScheduleSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// What is on disk, and the edited copy. Comparing them tells us if there are unsaved changes.
    @State private var original = ScheduleDraft()
    @State private var draft = ScheduleDraft()
    @State private var isSaving = false
    @State private var isTogglingEnabled = false
    @State private var saveError: String?
    @State private var savedMessage: String?

    private var hasChanges: Bool { draft != original }
    private var isInstalled: Bool { model.schedule != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                statusSection
                if isInstalled {
                    if !original.isRepresentable {
                        Section {
                            Label(
                                "The current schedule (\(model.schedule?.description ?? "")) can't be shown here. Saving replaces it.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    whenSection
                    optionsSection
                }
            }
            .formStyle(.grouped)
            Divider()
            SaveBar(
                hasChanges: hasChanges,
                validationError: draft.validationError,
                saveError: saveError,
                isSaving: isSaving,
                savedMessage: $savedMessage,
                onRevert: { draft = original },
                onSave: { Task { await save() } }
            )
        }
        // Re-read the plist each time the tab opens, in case it was edited elsewhere, but keep
        // unsaved edits when just switching tabs
        .task {
            await model.reloadSettings()
            if !hasChanges { load() }
        }
        // Pick up outside changes, but never throw away the user's unsaved edits
        .onChange(of: model.schedule) {
            if !hasChanges { load() }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            Toggle("Run updates on a schedule", isOn: enabledBinding)
                .disabled(!isInstalled || isTogglingEnabled)
            if !isInstalled {
                LabeledContent("No update schedule is set up yet.") {
                    // The setup sheet belongs to the main window, so bring that forward
                    Button("Set Up…") {
                        model.setupMode = .install
                        openWindow(id: "main")
                    }
                }
                .foregroundStyle(.secondary)
            } else if model.isLaunchAgentLoaded == true, let next = original.schedule.nextRun(after: .now) {
                LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
            } else if model.isLaunchAgentLoaded == false {
                Text("Scheduled updates are off. Updates only run when started from the app or Terminal.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var whenSection: some View {
        Section("When") {
            ScheduleFields(draft: $draft)
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Verbose logging", isOn: $draft.verbose)
            Toggle("Skip casks", isOn: $draft.skipCasks)
            Toggle("Skip cleanup", isOn: $draft.skipCleanup)
            Toggle("Skip security scan", isOn: $draft.skipSecurityScan)
            LabeledContent("Command") {
                Text((["brew-updates.sh"] + draft.scriptArguments).joined(separator: " "))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Scheduled Run Options")
        } footer: {
            Text("--yes is always included because nobody is there to answer prompts at night.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bindings

    /// The toggle applies immediately (it doesn't touch the plist, only whether launchd runs it)
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.isLaunchAgentLoaded == true },
            set: { enabled in
                Task {
                    isTogglingEnabled = true
                    defer { isTogglingEnabled = false }
                    do {
                        try await model.setScheduleEnabled(enabled)
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            }
        )
    }

    // MARK: Loading and saving

    private func load() {
        let loaded = model.schedule.map(ScheduleDraft.init(schedule:)) ?? ScheduleDraft()
        original = loaded
        draft = loaded
    }

    /// "Saved · next run Nov 18, 2026 at 8:00 AM", or just "Saved" when scheduled runs are off
    private func savedConfirmation() -> String {
        guard model.isLaunchAgentLoaded == true, let next = original.schedule.nextRun(after: .now) else {
            return "Saved"
        }
        return "Saved · next run \(next.formatted(date: .abbreviated, time: .shortened))"
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveSchedule(draft)
            saveError = nil
            load()
            savedMessage = savedConfirmation()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    ScheduleSettingsView()
        .environment(AppModel())
        .frame(width: 560, height: 640)
}
