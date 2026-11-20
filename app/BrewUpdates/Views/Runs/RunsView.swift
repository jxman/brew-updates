import SwiftUI

/// Run history on the left, the selected run's summary and logs on the right.
struct RunsView: View {
    /// What the left-hand list can select: a run, the LaunchAgent's own output files, or the
    /// live output of a run started from the app
    enum Item: Hashable {
        case run(Run.ID)
        case launchAgentOutput
        case live
    }

    @Environment(AppModel.self) private var model
    @State private var selection: Item?

    var body: some View {
        // A plain HStack, not HSplitView: AppKit's split view asked the window for more width
        // than it had at the minimum window size, which clipped the whole window on both sides
        HStack(spacing: 0) {
            List(selection: $selection) {
                if let live = model.liveRun {
                    Section("From This App") {
                        LiveRunRow(run: live).tag(Item.live)
                    }
                }
                Section("LaunchAgent") {
                    Label("Scheduler output", systemImage: "terminal")
                        .tag(Item.launchAgentOutput)
                }
                Section("Runs (\(model.runs.count))") {
                    ForEach(model.runs) { run in
                        RunRow(run: run).tag(Item.run(run.id))
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 280, maxWidth: 380)

            Divider()

            Group {
                switch selection {
                case .run(let id):
                    if let run = model.run(withID: id) {
                        RunDetailView(run: run)
                    } else {
                        EmptyStateView(title: "Run not found", systemImage: "questionmark.folder")
                    }
                case .launchAgentOutput:
                    LaunchAgentOutputView(paths: model.paths)
                case .live:
                    if let live = model.liveRun {
                        LiveRunView(run: live) { runID in
                            model.selectedRunID = runID
                            selection = .run(runID)
                        }
                    } else {
                        EmptyStateView(title: "No run started", systemImage: "terminal")
                    }
                case nil:
                    EmptyStateView(title: "No Run Selected", systemImage: "clock.arrow.circlepath")
                }
            }
            // The explicit ideal width matters: without one the pane's ideal is its content's
            // (every pill and log line on one row), and the main window's split view sizes its
            // detail column towards that, past the window's edge. 280 + 1 + 480 fits beside
            // the sidebar at the window's minimum width.
            .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            // An HStack offers space to higher-priority children first, so the list stays near
            // its minimum and the output gets the rest
            .layoutPriority(1)
        }
        .navigationTitle("Runs")
        // Keep the list in sync when another screen (e.g. the dashboard) picks a run
        .onAppear {
            if model.liveRun?.isActive == true {
                selection = .live
            } else {
                syncSelectionFromModel()
            }
        }
        .onChange(of: model.selectedRunID) { syncSelectionFromModel() }
        // A new run from the app: switch to its output
        .onChange(of: model.liveRun?.id) {
            if model.liveRun != nil {
                selection = .live
            }
        }
        .onChange(of: selection) {
            if case .run(let id) = selection {
                model.selectedRunID = id
            }
        }
    }

    private func syncSelectionFromModel() {
        if let id = model.selectedRunID, selection != .launchAgentOutput, selection != .live {
            selection = .run(id)
        }
    }
}

/// The list entry for the run started from the app.
private struct LiveRunRow: View {
    let run: LiveRun

    var body: some View {
        HStack {
            if run.isActive {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Image(systemName: run.systemImage).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch run.state {
        case .starting, .running: "Live output · \(run.lines.count) lines"
        case .stopping: "Stopping…"
        case .finished(let outcome): outcome.message
        case .failedToStart: "Couldn't start"
        }
    }
}

/// Summary header plus a tab per log file of one run.
struct RunDetailView: View {
    let run: Run
    @State private var selectedLog: RunFileKind = .log

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RunSummaryHeader(run: run)
                .padding()
            Divider()
            if run.viewableLogs.isEmpty {
                EmptyStateView(title: "No log files", systemImage: "doc")
            } else {
                Picker("Log", selection: $selectedLog) {
                    ForEach(run.viewableLogs) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // A new control whenever the tabs change: the AppKit segmented control keeps
                // its old width, so going from a 1-log run to a 5-log run squeezed them to "Ma…"
                .id(run.viewableLogs)
                .padding(8)
                if let url = run.files[selectedLog] {
                    // `.id(url)` gives each file a fresh LogView, resetting its filters and scroll
                    LogView(url: url).id(url)
                }
            }
        }
        // When switching runs, fall back to the main log if this run lacks the selected one
        .onChange(of: run.id, initial: true) {
            if run.files[selectedLog] == nil {
                selectedLog = run.viewableLogs.first ?? .log
            }
        }
    }
}

private struct RunSummaryHeader: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // `ViewThatFits` uses the first layout that fits the width it's offered: the full
            // date on one row, then a shorter date, then the date on its own row. A fixed row
            // would make the pane wider than the window, which then clips it on both sides.
            ViewThatFits(in: .horizontal) {
                titleRow(date: run.date.formatted(date: .complete, time: .standard))
                titleRow(date: run.date.formatted(date: .abbreviated, time: .shortened))
                VStack(alignment: .leading, spacing: 4) {
                    titleRow(date: nil)
                    Text(run.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = run.summary {
                details(summary)
            } else if run.status == .legacy {
                Text("This run is from before script v2.2.0, so only its log files are available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func titleRow(date: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusBadge(status: run.status)
                .font(.title2.weight(.semibold))
            if let date {
                Text(date)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let urlString = run.summary?.files.log {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: urlString)])
                }
            }
        }
    }

    private func details(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wraps onto another line when the pane is narrow instead of widening it
            FlowLayout(spacing: 6) {
                Pill(text: summary.trigger)
                if let label = summary.previewLabel { Pill(text: label, color: .purple) }
                Pill(text: summary.durationSeconds.durationDescription)
                Pill(text: "exit \(summary.exitCode)", color: summary.exitCode == 0 ? .green : .red)
                Pill(text: "doctor: \(summary.doctor.status)")
                Pill(text: "security: \(summary.security.status)")
                if let vulns = summary.vulns {
                    Pill(text: "brew vulns: \(vulns.status)")
                }
                Pill(text: "cleanup: \(summary.cleanup.status)")
            }
            packageLine("Upgraded", summary.upgraded.all.map { "\($0.name) \($0.from) → \($0.to)" }, color: .green)
            if summary.dryRun {
                packageLine("Would upgrade", summary.outdated.all.map(\.name), color: .orange)
            }
            packageLine("Failed", summary.failed.all, color: .red)
            packageLine("Excluded", summary.skipped.excluded, color: .secondary)
            packageLine("Pinned", summary.skipped.pinned, color: .secondary)
            packageLine("Not outdated", summary.skipped.notOutdated, color: .secondary)
            // Checked before upgrading: which upgrades replace a version with known vulnerabilities
            packageLine(
                "Vulnerable",
                summary.vulns?.beforeUpgrade.map { "\($0.name) (\($0.vulnerabilityCount))" } ?? [],
                color: .orange
            )
            if let deprecations = summary.deprecations {
                packageLine(
                    "Deprecated",
                    (deprecations.formulae + deprecations.casks).map { "\($0.name)\($0.disabled ? " (disabled)" : "")" },
                    color: .orange
                )
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func packageLine(_ title: String, _ names: [String], color: Color) -> some View {
        if !names.isEmpty {
            let list = names.joined(separator: ", ")
            HStack(alignment: .firstTextBaseline) {
                Text(names.count > 1 ? "\(title) (\(names.count))" : title)
                    .foregroundStyle(color)
                    .frame(width: 120, alignment: .leading)
                Text(list)
                    .textSelection(.enabled)
                    // Wrap rather than widen, but at most 3 lines: the header isn't scrollable,
                    // and a run that upgraded dozens of packages made the window's content
                    // taller than the window. The tooltip and the log have the full list.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(list)
            }
        }
    }
}

/// launchagent.log / launchagent_error.log: what launchd captured from scheduled runs.
private struct LaunchAgentOutputView: View {
    let paths: AppPaths
    @State private var showErrors = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Output", selection: $showErrors) {
                Text("Standard output").tag(false)
                Text("Errors").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            let url = showErrors ? paths.launchAgentErrorLog : paths.launchAgentLog
            LogView(url: url, tailLines: 3000).id(url)
        }
    }
}
