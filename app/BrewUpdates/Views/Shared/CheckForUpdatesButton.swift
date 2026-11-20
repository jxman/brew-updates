import AppKit
import SwiftUI

/// "Check for App Updates…" for the app menu and the menu bar menu. Hidden when the updater
/// isn't running (Debug builds, or before the app is moved to Applications).
struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        if updater.isEnabled {
            // "App" because the toolbar's Check for Updates means Homebrew packages
            Button("Check for App Updates…") {
                updater.checkForUpdates()
                // From the menu bar the app isn't frontmost, and Sparkle's window would open behind
                NSApp.activate()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
