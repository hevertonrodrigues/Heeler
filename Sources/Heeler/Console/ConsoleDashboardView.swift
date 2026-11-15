import SwiftUI
import UniformTypeIdentifiers

/// Every live Agent and Terminal across the connected Hosts at once, each a
/// watch-only cell the user can drag to reorder and resize by its corner.
/// The arrangement persists in `DashboardLayoutStore`.
struct ConsoleDashboardView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, agents, terminals
        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .agents: String(localized: "Agents")
            case .terminals: String(localized: "Terminals")
            }
        }
    }

    /// Live Attaches a Host's budget (5, `TerminalRetentionBudget`) gives the
    /// Dashboard, leaving one for opening an Agent or Terminal elsewhere.
    static let liveCellsPerHost = 4

    let console: ConsoleStore
    let hosts: HostStore
    let terminal: TerminalSettings
    let layout: DashboardLayoutStore
    let onDone: () -> Void

    @AppStorage("dashboard.filter") private var filter = Filter.all
    @State private var resizing: [ConsoleTerminal.ID: DashboardSpan] = [:]
    @State private var attempts: [ConsoleTerminal.ID: Int] = [:]
    @State private var dropTarget: ConsoleTerminal.ID?
    @Environment(\.scenePhase) private var scenePhase

    private static let padding: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let metrics = DashboardGridMetrics(width: max(proxy.size.width - Self.padding * 2, 1))
                content(metrics: metrics)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    // MARK: Cells

    private var shownTerminals: [ConsoleTerminal] {
        console.terminals.filter { terminal in
            switch filter {
            case .all: true
            case .agents: terminal.isAgent
            case .terminals: !terminal.isAgent
            }
        }
    }

    @ViewBuilder
    private func content(metrics: DashboardGridMetrics) -> some View {
        let shown = shownTerminals
        if shown.isEmpty {
            ContentUnavailableView(
                filter == .terminals ? "No Terminals" : "No Agents or Terminals",
                systemImage: "rectangle.3.group",
                description: Text("Connected Hosts' Panes appear here as they start."))
        } else {
            let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let order = layout.arranged(shown.map(\.id))
            let modes = cellModes(order: order, byID: byID)
            ScrollView {
                DashboardGridLayout {
                    ForEach(order, id: \.self) { id in
                        if let item = byID[id] {
                            cell(item, mode: modes[id] ?? .snapshot(note: ""), metrics: metrics, order: order)
                                .dashboardSpan(resizing[id] ?? layout.span(for: id))
                        }
                    }
                }
                .padding(Self.padding)
                .animation(.snappy, value: order)
                .animation(.snappy, value: resizing)
            }
        }
    }

    private enum CellMode {
        case live
        case snapshot(note: String)
    }

    /// Live up to each Host's share of the budget, in Dashboard order; a
    /// Herdr TUI Host never, since its attach takes the Pane over.
    private func cellModes(
        order: [ConsoleTerminal.ID], byID: [ConsoleTerminal.ID: ConsoleTerminal]
    ) -> [ConsoleTerminal.ID: CellMode] {
        var used: [Host.ID: Int] = [:]
        var modes: [ConsoleTerminal.ID: CellMode] = [:]
        for id in order where byID[id] != nil {
            let kind = hosts.consoleHosts.first { $0.id == id.hostID }?.serverKind
            if kind == .herdrTUI {
                modes[id] = .snapshot(note: String(localized: "Preview"))
            } else if used[id.hostID, default: 0] < Self.liveCellsPerHost {
                used[id.hostID, default: 0] += 1
                modes[id] = .live
            } else {
                modes[id] = .snapshot(note: String(localized: "Preview · live limit"))
            }
        }
        return modes
    }

    private func cell(
        _ item: ConsoleTerminal, mode: CellMode, metrics: DashboardGridMetrics, order: [ConsoleTerminal.ID]
    ) -> some View {
        let agent = item.agentID.flatMap { id in console.agents.first { $0.id == id } }
        let span = resizing[item.id] ?? layout.span(for: item.id)
        return VStack(spacing: 0) {
            header(item, agent: agent, span: span, metrics: metrics)
            Divider()
            cellBody(item, mode: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTarget == item.id ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: dropTarget == item.id ? 3 : 1)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle(for: item.id, span: span, metrics: metrics)
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard let moving = payloads.first.flatMap(Self.decodeID) else { return false }
            withAnimation(.snappy) { layout.move(moving, before: item.id, in: order) }
            return true
        } isTargeted: { targeted in
            if targeted { dropTarget = item.id } else if dropTarget == item.id { dropTarget = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.cell")
    }

    @ViewBuilder
    private func cellBody(_ item: ConsoleTerminal, mode: CellMode) -> some View {
        if scenePhase == .background {
            DashboardTileMessage(text: String(localized: "Paused"), showsProgress: false)
        } else {
            switch mode {
            case .live:
                let generation = console.hostConnectionGenerations[item.hostID]
                DashboardLiveTerminal(
                    store: AttachTerminalStore(
                        target: item.isAgent ? .agentPane(item.paneID) : .terminal(item.terminalID),
                        takeover: false, viewer: .observe, isViewed: true,
                        transportGeneration: generation,
                        runTerminal: console.terminalRunner(for: item.hostID)),
                    terminal: terminal,
                    remoteColumns: item.gridColumns, remoteRows: item.gridRows,
                    onReconnect: { attempts[item.id, default: 0] += 1 })
                .id("\(item.hostID)|\(item.paneID)|\(generation ?? 0)|\(attempts[item.id] ?? 0)")
            case .snapshot(let note):
                DashboardSnapshotTerminal(
                    console: console, hostID: item.hostID, paneID: item.paneID, isAgent: item.isAgent, note: note)
            }
        }
    }

    private func header(
        _ item: ConsoleTerminal, agent: ConsoleAgent?, span: DashboardSpan, metrics: DashboardGridMetrics
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            if let agent {
                Circle()
                    .fill(Color(uiColor: agent.agent.status.inkUIColor))
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "apple.terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.map(AgentTerminalView.displayTitle(for:)) ?? item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text([item.hostName, item.workspaceLabel].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            sizeMenu(for: item.id, span: span, metrics: metrics)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .draggable(Self.encodeID(item.id)) {
            Label(agent.map(AgentTerminalView.displayTitle(for:)) ?? item.displayTitle, systemImage: "rectangle.on.rectangle")
                .padding(8)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private func sizeMenu(for id: ConsoleTerminal.ID, span: DashboardSpan, metrics: DashboardGridMetrics) -> some View {
        Menu {
            let presets: [DashboardSpan] = [
                .init(columns: 1, rows: 1), .init(columns: 2, rows: 1), .init(columns: 1, rows: 2),
                .init(columns: 2, rows: 2), .init(columns: 3, rows: 2), .init(columns: 4, rows: 2),
                .init(columns: 4, rows: 3),
            ]
            ForEach(presets.filter { $0.columns <= metrics.columns }, id: \.self) { preset in
                Button {
                    withAnimation(.snappy) { layout.setSpan(preset, for: id) }
                } label: {
                    if preset == span.clamped(toColumns: metrics.columns) {
                        Label("\(preset.columns) × \(preset.rows)", systemImage: "checkmark")
                    } else {
                        Text(verbatim: "\(preset.columns) × \(preset.rows)")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Size")
        .accessibilityIdentifier("dashboard.cell.size")
    }

    /// A corner grip: dragging it snaps the cell to the nearest span live,
    /// and lifting the finger keeps that span.
    private func resizeHandle(for id: ConsoleTerminal.ID, span: DashboardSpan, metrics: DashboardGridMetrics) -> some View {
        let committed = layout.span(for: id).clamped(toColumns: metrics.columns)
        return Image(systemName: "arrow.down.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let base = metrics.size(of: committed)
                        let proposed = CGSize(
                            width: base.width + value.translation.width, height: base.height + value.translation.height)
                        let next = metrics.span(nearest: proposed)
                        if resizing[id] != next { resizing[id] = next }
                    }
                    .onEnded { _ in
                        if let next = resizing[id] { layout.setSpan(next, for: id) }
                        resizing[id] = nil
                    }
            )
            .accessibilityLabel("Resize")
            .accessibilityIdentifier("dashboard.cell.resize")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: onDone)
                .accessibilityIdentifier("dashboard.done")
        }
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Reset Layout", systemImage: "arrow.counterclockwise", role: .destructive) {
                    withAnimation(.snappy) { layout.reset() }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Drag payload

    private static func encodeID(_ id: ConsoleTerminal.ID) -> String {
        "heeler-dashboard|\(id.hostID.uuidString)|\(id.paneID)"
    }

    private static func decodeID(_ payload: String) -> ConsoleTerminal.ID? {
        let parts = payload.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "heeler-dashboard", let host = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        return ConsoleTerminal.ID(hostID: host, paneID: String(parts[2]))
    }
}
