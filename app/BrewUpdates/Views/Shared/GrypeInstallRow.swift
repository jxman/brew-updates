import SwiftUI

/// Why grype is worth installing, and a button that installs it. Shown in the setup sheet and
/// as a card at the top of the Security screen while grype is missing; a green check once
/// it's there.
struct GrypeInstallRow: View {
    @Environment(AppModel.self) private var model
    /// The brew to install with. The setup sheet passes the one it just found, which can be
    /// newer than the model's (Homebrew installed while the sheet is open)
    let brewExecutable: URL?
    /// `.card` for the Security screen; `.compact` for the setup sheet, where height is short
    var style = Style.card

    enum Style { case card, compact }

    private var security: SecurityScanModel { model.security }

    var body: some View {
        if security.isGrypeInstalled {
            Label {
                Text("grype is installed. Each update also scans for known vulnerabilities.")
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
        } else if style == .compact {
            compactLayout
        } else {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Install grype for full security scanning")
                            .font(.headline)
                        RecommendedTag()
                    }
                    Text(Self.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // `fixedSize(vertical:)` wraps the text instead of truncating it. The
                        // minimum width matters: SwiftUI works out a view's minimum size at
                        // almost no width, where this text is one word per line and thousands
                        // of points tall, and the main window then grew to fit that
                        .frame(minWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                }
                Spacer(minLength: 8)
                installButton
                    .controlSize(.large)
            }
        }
    }

    /// Headline, tag and button on one row, the explanation below
    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                Text("Install grype for full security scanning")
                    .font(.headline)
                RecommendedTag()
                Spacer(minLength: 8)
                installButton
            }
            Text(Self.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            status
        }
    }

    private var installButton: some View {
        Button {
            Task { await security.installGrype(brewExecutable: brewExecutable, paths: model.paths) }
        } label: {
            Label("Install grype", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(brewExecutable == nil || security.isInstallingGrype || model.isRunInProgress)
    }

    /// Progress, why the button is off, or the install error
    @ViewBuilder
    private var status: some View {
        if security.isInstallingGrype {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing with Homebrew…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if let error = security.grypeInstallError {
            Label(error, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        } else if brewExecutable == nil {
            Text("Needs Homebrew").font(.callout).foregroundStyle(.secondary)
        } else if model.isRunInProgress {
            Text("Available when the running update finishes").font(.callout).foregroundStyle(.secondary)
        }
    }

    static let explanation = "grype checks the files Homebrew installed, including libraries bundled inside "
        + "packages. Without it only brew vulns runs, which misses those libraries, and the trend chart "
        + "has no grype line."
}

/// A small orange "Recommended" capsule
private struct RecommendedTag: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
    }
}
