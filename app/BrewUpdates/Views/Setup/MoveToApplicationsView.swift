import AppKit
import SwiftUI

/// Shown in the main window instead of everything else when the app runs from its disk image,
/// a translocated copy or Downloads (`AppLocation`). Nothing else starts until it's moved:
/// setup would point the schedule at a copy that disappears when the image is ejected.
struct MoveToApplicationsView: View {
    let location: AppLocation

    @State private var isMoving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Move Brew Updates to Applications")
                .font(.title2.weight(.semibold))
            Text(explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let other = otherRunningCopy {
                Label("Another copy of Brew Updates is open. Moving quits it.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(other.bundleURL?.path ?? "")
            }
            HStack(spacing: 12) {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    move()
                } label: {
                    if isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Applications")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isMoving)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        let reason = switch location.problem {
        case .diskImage: "You opened Brew Updates from its disk image."
        case .translocated: "macOS is running Brew Updates from a temporary copy because it hasn't been moved yet."
        case .downloads: "Brew Updates is in your Downloads folder."
        case nil: ""
        }
        return reason + " It needs to be in Applications so scheduled updates keep working "
            + "after the disk image is ejected. It moves itself and reopens from there."
    }

    /// Another instance with the same bundle ID, e.g. an older version already in Applications.
    /// Opening the moved copy would only bring that one forward, so it has to quit first
    private var otherRunningCopy: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.appBundleIdentifier)
            .first { $0 != NSRunningApplication.current }
    }

    /// Quits the other copy before its bundle goes to the Trash. `terminate()` asks nicely, but
    /// it's an Apple event, which the hardened runtime doesn't let this app send, so it can be
    /// ignored; `forceTerminate()` is a plain signal. That copy is being replaced anyway.
    private func quit(_ other: NSRunningApplication) async {
        other.terminate()
        for attempt in 0..<20 where !other.isTerminated {
            if attempt == 8 { other.forceTerminate() }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func move() {
        isMoving = true
        error = nil
        Task {
            defer { isMoving = false }
            do {
                if let other = otherRunningCopy {
                    await quit(other)
                }
                let moved = try AppMover(source: location.bundleURL, destination: location.destination).move()
                let configuration = NSWorkspace.OpenConfiguration()
                // This copy is still running with the same bundle ID; without this, macOS
                // would bring it forward instead of opening the moved one
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: moved, configuration: configuration)
                NSApp.terminate(nil)
            } catch {
                self.error = "Couldn't move it: \(error.localizedDescription) "
                    + "Drag Brew Updates into the Applications folder in Finder instead."
            }
        }
    }
}

#Preview {
    MoveToApplicationsView(location: AppLocation(
        bundleURL: URL(filePath: "/Volumes/Install Brew Updates/Brew Updates.app"),
        home: URL(filePath: "/Users/me"),
        isOnReadOnlyVolume: true
    ))
    .frame(width: 960, height: 600)
}
