import SwiftUI

/// First-run setup, shown as a sheet over the main window when the Mac has no update schedule
/// yet: checks Homebrew, picks the schedule, turns notifications on or off and points at the
/// optional security scanner. "Set Up" does what `scripts/setup.sh` used to do for app users.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = Self.defaultSchedule
    @State private var notifications = true
    /// nil until checked, so the Homebrew row can show a spinner first
    @State private var brewExecutable: URL?
    @State private var brewVersion: String?
    @State private var hasCheckedBrew = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Daily at 3 AM with verbose logs, the same default `scripts/setup.sh` writes
    private static var defaultSchedule: ScheduleDraft {
        var draft = ScheduleDraft()
        draft.verbose = true
        return draft
    }

    private var isPreview: Bool { model.setupMode == .preview }
    private var canSetUp: Bool { brewExecutable != nil && draft.validationError == nil && !isSaving }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                homebrewSection
                Section {
                    ScheduleFields(draft: $draft)
                    Toggle("Notify me when an update finishes", isOn: $notifications)
                } header: {
                    Text("When to Update")
                } footer: {
                    Text("If your Mac is asleep at that time, the update runs when it wakes. "
                        + "macOS asks to allow notifications when you click Set Up.")
                        .foregroundStyle(.secondary)
                }
                appManagementSection
                // No section header: the card has its own headline
                Section {
                    GrypeInstallRow(brewExecutable: brewExecutable, style: .compact)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 580, height: 740)
        // `.task` runs when the sheet appears; the checks are quick but involve running brew
        .task { await checkTools() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Brew Updates")
                    .font(.title2.weight(.semibold))
                Text("Choose when updates run. You can change everything later in Settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homebrewSection: some View {
        Section("Homebrew") {
            if !hasCheckedBrew {
                ProgressView().controlSize(.small)
            } else if let brewExecutable {
                Label {
                    VStack(alignment: .leading) {
                        Text(brewVersion ?? "Homebrew")
                        Text(brewExecutable.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("Homebrew isn't installed. Brew Updates needs it to update your packages.")
                } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                HStack {
                    // `Link` opens the URL in the default browser
                    Link("Get Homebrew at brew.sh", destination: URL(string: "https://brew.sh")!)
                    Spacer()
                    Button("Check Again") { Task { await checkTools() } }
                }
            }
        }
    }

    /// Casks replace apps in /Applications. macOS blocks that for apps from other developers
    /// unless the program that runs the scheduled update has the App Management permission,
    /// and shows "brew-updates-launcher was prevented from modifying apps on your Mac".
    /// There is no API to ask for it, so this explains it and opens the right Settings pane.
    private var appManagementSection: some View {
        Section {
            Text("When a scheduled update replaces an app, macOS may show \u{201C}brew-updates-launcher was "
                + "prevented from modifying apps on your Mac\u{201D}. Allow it once to avoid that.")
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click Open Settings and choose + in App Management.")
                Text("2. Click Show in Finder and drag brew-updates-launcher into the list, then switch it on.")
            }
            .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings") { model.openAppManagementSettings() }
                Button("Show in Finder") { model.revealLauncher() }
                Spacer()
            }
        } header: {
            Text("Allow App Updates")
        } footer: {
            Text("Optional. Without it updates still run, but macOS may show that message.")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if isPreview {
                Label("Preview: nothing on this Mac changes", systemImage: "eye")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Button("Not Now") { model.postponeSetup() }
                // Esc chooses it, like Cancel in a dialog
                .keyboardShortcut(.cancelAction)
            Button("Set Up") { Task { await setUp() } }
                // Return chooses it; also draws it as the window's default button
                .keyboardShortcut(.defaultAction)
                .disabled(!canSetUp)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func checkTools() async {
        // Located again (not taken from the model), so Check Again finds a Homebrew installed
        // while the sheet is open
        let brew = BrewService(executable: BrewService.locate())
        brewExecutable = brew.executable
        brewVersion = try? await brew.version()
        model.security.checkGrype(brewExecutable: brew.executable)
        hasCheckedBrew = true
    }

    private func setUp() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.completeSetup(schedule: draft, notifications: notifications, brewExecutable: brewExecutable)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SetupView()
        .environment(AppModel())
}
