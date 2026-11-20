import SwiftUI

/// The Settings window (⌘, or "Settings…" in the app and menu bar menus).
///
/// Each tab edits a *draft* copy and writes it only on Save: saving the schedule reloads the
/// LaunchAgent, which shouldn't happen on every click. Closing the window discards unsaved
/// drafts, so reopening always shows what is on disk.
struct SettingsView: View {
    /// Changed when the window closes. `.id(session)` on each tab's content then gives it new
    /// `@State` (fresh drafts) the next time the window opens. It's on the content, not the
    /// TabView: a TabView with a new identity lost its toolbar tabs, leaving no way to switch.
    @State private var session = UUID()
    /// `@AppStorage` reads and writes a UserDefaults key and updates the view when the key
    /// changes, so other screens can pick the tab (`SettingsTab.select`), even while the
    /// window is already open
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.schedule

    var body: some View {
        // `Tab` (macOS 15+) gives the toolbar-style tabs used by system Settings windows
        TabView(selection: $selectedTab) {
            Tab("Schedule", systemImage: "calendar", value: .schedule) {
                ScheduleSettingsView().id(session)
            }
            Tab("Updates", systemImage: "gearshape", value: .updates) {
                UpdateSettingsView().id(session)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettingsView()
            }
            Tab("Uninstall", systemImage: "trash", value: .uninstall) {
                UninstallSettingsView().id(session)
            }
        }
        .frame(width: 560, height: 640)
        // Fires when the window closes, not when switching tabs (the TabView itself stays).
        // The next opening starts on Schedule rather than wherever it was left, e.g. Uninstall
        .onDisappear {
            session = UUID()
            selectedTab = .schedule
        }
    }
}

enum SettingsTab: String {
    case schedule, updates, about, uninstall

    static let storageKey = "settingsTab"

    /// Shows this tab in the Settings window; call before `openSettings()`
    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }
}

/// Bottom bar of a settings tab: unsaved/validation/error message, Revert and Save (⌘S).
struct SaveBar: View {
    let hasChanges: Bool
    let validationError: String?
    let saveError: String?
    let isSaving: Bool
    /// Confirmation after a successful save, e.g. "Saved". A `@Binding` lets the bar clear the
    /// parent's state itself once the message has been shown for a few seconds.
    @Binding var savedMessage: String?
    let onRevert: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            message
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Button("Revert", action: onRevert)
                .disabled(!hasChanges || isSaving)
            Button("Save", action: onSave)
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || validationError != nil || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Animates the message appearing and fading out
        .animation(.default, value: savedMessage)
        // `.task(id:)` restarts whenever the id changes and is cancelled when it changes again,
        // so a second save restarts the countdown instead of the first one clearing it early
        .task(id: savedMessage) {
            guard savedMessage != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            savedMessage = nil
        }
    }

    @ViewBuilder
    private var message: some View {
        if let saveError {
            Label(saveError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else if let validationError {
            Label(validationError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if hasChanges {
            Label("Unsaved changes", systemImage: "pencil.circle.fill")
                .foregroundStyle(.orange)
        } else if let savedMessage {
            Label(savedMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
