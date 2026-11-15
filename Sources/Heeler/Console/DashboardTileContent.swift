import SwiftUI

/// A watch-only live terminal for one Dashboard cell: an observe Attach
/// (`takeover: false`, `viewer: .observe`) that never types, scrolls or sizes
/// the remote Pane. When the remote grid is known (tmux and herdr-core report
/// it) the font shrinks until the whole Pane fits the cell, so its output is
/// drawn at the Pane's real width instead of wrapping.
struct DashboardLiveTerminal: View {
    let terminal: TerminalSettings
    let remoteColumns: Int?
    let remoteRows: Int?
    /// Recreates the Attach; a `retry()` would come back interactive.
    let onReconnect: () -> Void

    @State private var store: AttachTerminalStore
    @State private var fontSize: Float
    @State private var fitPasses = 0
    @Environment(\.themeAppearance) private var themeAppearance

    init(
        store: AttachTerminalStore, terminal: TerminalSettings, remoteColumns: Int?, remoteRows: Int?,
        onReconnect: @escaping () -> Void
    ) {
        _store = State(wrappedValue: store)
        self.terminal = terminal
        self.remoteColumns = remoteColumns
        self.remoteRows = remoteRows
        self.onReconnect = onReconnect
        _fontSize = State(wrappedValue: max(terminal.zoom.fontSize * 0.6, 3))
    }

    var body: some View {
        screen
            .allowsHitTesting(false)
            .overlay { statusOverlay }
            .onDisappear {
                let store = store
                Task { await store.stop() }
            }
    }

    private var screen: TerminalScreenView {
        var screen = TerminalScreenView(feed: store.feed)
        screen.onSizeChanged = { cols, rows in
            fit(reportedColumns: cols, reportedRows: rows)
            store.viewDidResize(cols: cols, rows: rows)
        }
        screen.isLocalInputEnabled = false
        screen.isRemoteScrollEnabled = false
        screen.theme = terminal.themes.terminalTheme(for: themeAppearance)
        screen.displayColors = terminal.themes.colors(for: themeAppearance)
        screen.fontSize = fontSize
        screen.fontFamily = terminal.fonts.familyName
        return screen
    }

    /// Columns and rows scale inversely with the font size, so one report
    /// says what size fits the remote grid. A second pass corrects rounding.
    private func fit(reportedColumns: Int, reportedRows: Int) {
        guard fitPasses < 2, let remoteColumns, remoteColumns > 0, reportedColumns > 0, reportedRows > 0 else { return }
        var scale = Float(reportedColumns) / Float(remoteColumns)
        if let remoteRows, remoteRows > 0 {
            scale = min(scale, Float(reportedRows) / Float(remoteRows))
        }
        guard abs(1 - scale) > 0.03 else { return }
        let fitted = min(max(fontSize * scale * 0.98, 2), terminal.zoom.fontSize)
        guard abs(fitted - fontSize) > 0.05 else { return }
        fitPasses += 1
        fontSize = fitted
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .waitingForSize, .connecting:
            DashboardTileMessage(text: String(localized: "Connecting…"), showsProgress: true)
        case .reconnecting, .restarting:
            DashboardTileMessage(text: String(localized: "Reconnecting…"), showsProgress: true)
        case .finished:
            DashboardTileMessage(text: String(localized: "The program exited."), showsProgress: false)
        case .ended(let message):
            DashboardTileMessage(text: message, showsProgress: false) {
                Button("Reconnect", systemImage: "arrow.clockwise", action: onReconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .live, .stopped:
            EmptyView()
        }
    }
}

/// A Pane's screen read on a timer, for a cell that cannot hold a live
/// Attach: a Herdr TUI Host (whose attach would take the Pane over and resize
/// it) or a Host already at its live-terminal budget.
struct DashboardSnapshotTerminal: View {
    let console: ConsoleStore
    let hostID: Host.ID
    let paneID: String
    let isAgent: Bool
    let note: String

    @State private var lines: [String] = []
    @State private var failure: String?

    var body: some View {
        GeometryReader { proxy in
            let fontSize = max(min(proxy.size.width / 70, 11), 6)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                ForEach(Array(lines.suffix(Int(proxy.size.height / (fontSize * 1.25))).enumerated()), id: \.offset) {
                    Text(verbatim: $0.element.isEmpty ? " " : $0.element)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            Text(note)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .padding(6)
        }
        .overlay {
            if lines.isEmpty {
                DashboardTileMessage(
                    text: failure ?? (isAgent ? String(localized: "Reading…") : String(localized: "No preview for this Terminal")),
                    showsProgress: failure == nil && isAgent)
            }
        }
        .task(id: paneID) {
            guard isAgent else { return }
            while !Task.isCancelled {
                do {
                    let screen = try await console.readAgentScreen(paneID, on: hostID)
                    lines = screen.rows.map(\.text)
                    failure = nil
                } catch is CancellationError {
                    return
                } catch {
                    failure = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct DashboardTileMessage<Action: View>: View {
    let text: String
    let showsProgress: Bool
    @ViewBuilder let action: () -> Action

    init(text: String, showsProgress: Bool, @ViewBuilder action: @escaping () -> Action) {
        self.text = text
        self.showsProgress = showsProgress
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsProgress { ProgressView() }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.6))
    }
}

extension DashboardTileMessage where Action == EmptyView {
    init(text: String, showsProgress: Bool) {
        self.init(text: text, showsProgress: showsProgress) { EmptyView() }
    }
}
