import SwiftUI

/// A watch-only live terminal for one Dashboard cell: an observe Attach
/// (`takeover: false`, `viewer: .observe`) that never types, scrolls or sizes
/// the remote Pane.
///
/// Where the remote grid is known (tmux and herdr-core report it), the
/// terminal lays out on a fixed canvas exactly that many columns and rows at
/// the user's font size, and the cell only scales the picture. Resizing a cell
/// is then a zoom: the terminal never reflows, so the Pane looks as it does on
/// the machine. The canvas follows the remote Pane when that one resizes.
struct DashboardLiveTerminal: View {
    let terminal: TerminalSettings
    let remoteColumns: Int?
    let remoteRows: Int?
    /// Recreates the Attach; a `retry()` would come back interactive.
    let onReconnect: () -> Void

    @State private var store: AttachTerminalStore?
    private let makeStore: () -> AttachTerminalStore
    /// The fixed size the terminal lays out at, converging on the remote grid.
    @State private var canvas: CGSize?
    @State private var fitPasses = 0
    @Environment(\.themeAppearance) private var themeAppearance

    private struct GridSize: Equatable {
        let columns: Int
        let rows: Int
    }

    /// Upscaling past this blurs; a cell larger than the Pane leaves margins.
    private static let maximumScale: CGFloat = 1.5

    init(
        terminal: TerminalSettings, remoteColumns: Int?, remoteRows: Int?,
        onReconnect: @escaping () -> Void, makeStore: @escaping () -> AttachTerminalStore
    ) {
        self.terminal = terminal
        self.remoteColumns = remoteColumns
        self.remoteRows = remoteRows
        self.onReconnect = onReconnect
        self.makeStore = makeStore
    }

    private var remoteGrid: GridSize? {
        guard let remoteColumns, let remoteRows, remoteColumns > 0, remoteRows > 0 else { return nil }
        return GridSize(columns: remoteColumns, rows: remoteRows)
    }

    var body: some View {
        GeometryReader { proxy in
            if let store {
                if let remoteGrid {
                    let canvas = canvas ?? Self.estimatedCanvas(for: remoteGrid)
                    let scale = min(
                        proxy.size.width / canvas.width, proxy.size.height / canvas.height, Self.maximumScale)
                    screen(store)
                        .frame(width: canvas.width, height: canvas.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    screen(store)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .overlay { statusOverlay }
        .onAppear {
            if store == nil { store = makeStore() }
        }
        .onChange(of: remoteGrid) { _, _ in
            // The remote Pane resized: converge on its new grid.
            fitPasses = 0
        }
        .onDisappear {
            guard let store else { return }
            Task { await store.stop() }
        }
    }

    private func screen(_ store: AttachTerminalStore) -> TerminalScreenView {
        var screen = TerminalScreenView(feed: store.feed)
        screen.onSizeChanged = { cols, rows in
            fit(reportedColumns: cols, reportedRows: rows)
            store.viewDidResize(cols: cols, rows: rows)
        }
        screen.isLocalInputEnabled = false
        screen.isRemoteScrollEnabled = false
        screen.theme = terminal.themes.terminalTheme(for: themeAppearance)
        screen.displayColors = terminal.themes.colors(for: themeAppearance)
        screen.fontSize = remoteGrid == nil ? max(terminal.zoom.fontSize * 0.7, 4) : terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        return screen
    }

    /// A first guess before the terminal reports: about 7 × 16 points a cell.
    private static func estimatedCanvas(for grid: GridSize) -> CGSize {
        CGSize(width: CGFloat(grid.columns) * 7 + 8, height: CGFloat(grid.rows) * 16 + 8)
    }

    /// Each report says how many cells the current canvas holds, so it says
    /// how much wider or taller the canvas must be for the remote grid. A few
    /// passes absorb the terminal's padding and rounding.
    private func fit(reportedColumns: Int, reportedRows: Int) {
        guard let remoteGrid, reportedColumns > 0, reportedRows > 0, fitPasses < 6 else { return }
        let current = canvas ?? Self.estimatedCanvas(for: remoteGrid)
        if reportedColumns == remoteGrid.columns, reportedRows == remoteGrid.rows { return }
        let cellWidth = current.width / CGFloat(reportedColumns)
        let cellHeight = current.height / CGFloat(reportedRows)
        let next = CGSize(
            width: (current.width + CGFloat(remoteGrid.columns - reportedColumns) * cellWidth).rounded(.up),
            height: (current.height + CGFloat(remoteGrid.rows - reportedRows) * cellHeight).rounded(.up))
        guard next != current else { return }
        fitPasses += 1
        canvas = next
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store?.status ?? .waitingForSize {
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
