import SwiftUI

/// Every live Agent and Terminal across the connected Hosts at once, each a
/// watch-only cell on a 12-column grid (after react-grid-layout). Drag a cell
/// by its header to move it and by its corner to resize it: the cell follows
/// the finger, a placeholder shows where it will land, and the other cells
/// move out of its way and close the gaps as it goes. Double-tap a header to
/// toggle full width. The arrangement persists in `DashboardLayoutStore`.
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

    /// How the cells are laid out: the free-form grid, or fixed tiles of one
    /// size (3 × 3 to a screen; on a phone 1 × 3 upright, 3 × 1 sideways),
    /// each showing its Pane's bottom.
    enum Style: String, CaseIterable, Identifiable {
        case freeForm, fixed
        var id: Self { self }
        var title: String {
            switch self {
            case .freeForm: String(localized: "Free-Form")
            case .fixed: String(localized: "Fixed Tiles")
            }
        }
        var systemImage: String {
            switch self {
            case .freeForm: "rectangle.3.group"
            case .fixed: "square.grid.3x3"
            }
        }
    }

    /// Tiles per row and rows per screen in the fixed style: 3 × 3, with one
    /// column where the screen is too narrow (an upright phone) and one row
    /// where it is too short (a phone on its side).
    static func fixedGrid(for viewport: CGSize) -> (columns: Int, rows: Int) {
        (viewport.width < DashboardGridMetrics.minimumGridWidth ? 1 : 3, viewport.height < 480 ? 1 : 3)
    }

    /// Live Attaches a Host's budget (5, `TerminalRetentionBudget`) gives the
    /// Dashboard, leaving one for opening an Agent or Terminal elsewhere.
    static let liveCellsPerHost = 4

    let console: ConsoleStore
    let hosts: HostStore
    let terminal: TerminalSettings
    let layout: DashboardLayoutStore
    let onDone: () -> Void
    /// Leaves watch-only for the Agent's or Terminal's own interactive
    /// screen, as picking its row would.
    var onTakeControl: (ConsoleTerminal) -> Void = { _ in }

    @AppStorage("dashboard.filter") private var filter = Filter.all
    @AppStorage("dashboard.style") private var style = Style.freeForm
    @State private var interaction: Interaction?
    @State private var attempts: [ConsoleTerminal.ID: Int] = [:]
    /// The cell open in the full-screen viewer.
    @State private var viewing: DashboardViewing?
    @State private var visibleCellIDs: Set<ConsoleTerminal.ID> = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Interaction: Equatable {
        enum Kind { case move, resize }
        let id: ConsoleTerminal.ID
        let kind: Kind
        let start: DashboardGridRect
        var translation: CGSize = .zero
    }

    private static let padding: CGFloat = 16
    private static let space = "dashboard.grid"

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                content(
                    metrics: DashboardGridMetrics(width: max(proxy.size.width - Self.padding * 2, 1)),
                    viewport: proxy.size)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .fullScreenCover(item: $viewing) { viewing in
            if let item = console.terminals.first(where: { $0.id == viewing.id }) {
                DashboardFullScreenView(
                    item: item, agent: agent(for: item), terminal: terminal, console: console,
                    isLive: hosts.consoleHosts.first { $0.id == item.hostID }?.serverKind != .herdrTUI,
                    onClose: { self.viewing = nil },
                    onTakeControl: {
                        self.viewing = nil
                        onTakeControl(item)
                    })
            } else {
                DashboardFullScreenGone { self.viewing = nil }
            }
        }
    }

    private func agent(for item: ConsoleTerminal) -> ConsoleAgent? {
        item.agentID.flatMap { id in console.agents.first { $0.id == id } }
    }

    // MARK: Grid

    private var shownTerminals: [ConsoleTerminal] {
        console.terminals.filter { terminal in
            switch filter {
            case .all: true
            case .agents: terminal.isAgent
            case .terminals: !terminal.isAgent
            }
        }
    }

    private var settle: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    @ViewBuilder
    private func content(metrics: DashboardGridMetrics, viewport: CGSize) -> some View {
        let shown = shownTerminals
        if shown.isEmpty {
            ContentUnavailableView(
                filter == .terminals ? "No Terminals" : "No Agents or Terminals",
                systemImage: "rectangle.3.group",
                description: Text("Connected Hosts' Panes appear here as they start."))
        } else {
            let base = layout.positions(for: shown.map(\.id))
            let preview = preview(base: base, metrics: metrics)
            let modes = cellModes(order: shown.map(\.id).sorted { (base[$0]?.y ?? 0, base[$0]?.x ?? 0) < (base[$1]?.y ?? 0, base[$1]?.x ?? 0) })
            ScrollView {
                if style == .fixed {
                    fixed(shown, positions: base, modes: modes, viewport: viewport)
                } else if metrics.stacks {
                    stacked(shown, positions: base, modes: modes, metrics: metrics)
                } else {
                    grid(shown, preview: preview, modes: modes, metrics: metrics)
                }
            }
            .scrollDisabled(interaction != nil)
        }
    }

    private struct Preview {
        var positions: [ConsoleTerminal.ID: DashboardGridRect]
        /// The cell under the finger, where the finger has it.
        var floating: CGRect?
        /// Where that cell lands if released now.
        var target: DashboardGridRect?
    }

    /// The arrangement while a cell is being moved or resized: the cell held
    /// where the finger is, snapped to a target the others flow around.
    private func preview(base: [ConsoleTerminal.ID: DashboardGridRect], metrics: DashboardGridMetrics) -> Preview {
        guard let interaction, base[interaction.id] != nil else { return Preview(positions: base) }
        let startFrame = metrics.frame(of: interaction.start)
        var floating = startFrame
        let target: DashboardGridRect
        switch interaction.kind {
        case .move:
            floating.origin.x = min(
                max(startFrame.minX + interaction.translation.width, 0), metrics.width - startFrame.width)
            floating.origin.y = max(startFrame.minY + interaction.translation.height, 0)
            target = metrics.rect(movedTo: floating, size: interaction.start)
        case .resize:
            let minimum = metrics.minimumSize
            floating.size.width = min(
                max(startFrame.width + interaction.translation.width, minimum.width), metrics.width - startFrame.minX)
            floating.size.height = max(startFrame.height + interaction.translation.height, minimum.height)
            target = metrics.rect(resizedTo: floating, origin: interaction.start)
        }
        var items = base
        items[interaction.id] = target
        let positions = DashboardGrid.compact(items, pinned: interaction.id)
        return Preview(positions: positions, floating: floating, target: positions[interaction.id])
    }

    private func grid(
        _ shown: [ConsoleTerminal], preview: Preview, modes: [ConsoleTerminal.ID: CellMode], metrics: DashboardGridMetrics
    ) -> some View {
        let rows = preview.positions.values.map(\.bottom).max() ?? 0
        let floatingBottom = preview.floating?.maxY ?? 0
        // Room below the last cell to drag into.
        let height = max(metrics.height(of: rows), floatingBottom) + DashboardGridMetrics.rowHeight * 4
        return ZStack(alignment: .topLeading) {
            if let target = preview.target {
                let frame = metrics.frame(of: target)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .animation(settle, value: target)
            }
            ForEach(shown) { item in
                if let rect = preview.positions[item.id] {
                    let isActive = interaction?.id == item.id
                    let frame = isActive ? (preview.floating ?? metrics.frame(of: rect)) : metrics.frame(of: rect)
                    cell(item, mode: modes[item.id] ?? .snapshot(note: ""), rect: rect, isActive: isActive, metrics: metrics)
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(isActive && interaction?.kind == .move ? 1.02 : 1)
                        .shadow(color: .black.opacity(isActive ? 0.25 : 0), radius: isActive ? 18 : 0, y: isActive ? 8 : 0)
                        .offset(x: frame.minX, y: frame.minY)
                        .zIndex(isActive ? 1 : 0)
                        .animation(isActive ? nil : settle, value: frame)
                }
            }
        }
        .frame(width: metrics.width, height: height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .padding(Self.padding)
    }

    /// Too narrow for the grid: the cells one under another, in grid order,
    /// at their grid height.
    private func stacked(
        _ shown: [ConsoleTerminal], positions: [ConsoleTerminal.ID: DashboardGridRect],
        modes: [ConsoleTerminal.ID: CellMode], metrics: DashboardGridMetrics
    ) -> some View {
        let ordered = shown.sorted {
            let lhs = positions[$0.id], rhs = positions[$1.id]
            return (lhs?.y ?? 0, lhs?.x ?? 0) < (rhs?.y ?? 0, rhs?.x ?? 0)
        }
        return LazyVStack(spacing: DashboardGridMetrics.gap) {
            ForEach(ordered) { item in
                let rect = positions[item.id] ?? DashboardGridRect(x: 0, y: 0, w: 12, h: DashboardGrid.defaultHeight)
                cell(item, mode: modes[item.id] ?? .snapshot(note: ""), rect: rect, isActive: false, interactive: false, metrics: metrics)
                    .frame(height: metrics.height(of: rect.h))
            }
        }
        .padding(Self.padding)
    }

    /// Fixed tiles in grid order, all one size, a screenful at a time (nine
    /// on an iPad, three on a phone), more scrolling the page. Each tile
    /// shows its Pane at the tile's width, from the bottom.
    private func fixed(
        _ shown: [ConsoleTerminal], positions: [ConsoleTerminal.ID: DashboardGridRect],
        modes: [ConsoleTerminal.ID: CellMode], viewport: CGSize
    ) -> some View {
        let ordered = shown.sorted {
            let lhs = positions[$0.id], rhs = positions[$1.id]
            return (lhs?.y ?? 0, lhs?.x ?? 0) < (rhs?.y ?? 0, rhs?.x ?? 0)
        }
        let grid = Self.fixedGrid(for: viewport)
        let count = grid.columns
        let gap = DashboardGridMetrics.gap
        let tile = CGSize(
            width: max((viewport.width - Self.padding * 2 - gap * CGFloat(count - 1)) / CGFloat(count), 1),
            height: max((viewport.height - Self.padding * 2 - gap * CGFloat(grid.rows - 1)) / CGFloat(grid.rows), 120))
        let rows = stride(from: 0, to: ordered.count, by: count).map { Array(ordered[$0..<min($0 + count, ordered.count)]) }
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: gap) {
                    ForEach(row) { item in
                        let rect = positions[item.id] ?? DashboardGridRect(x: 0, y: 0, w: 4, h: DashboardGrid.defaultHeight)
                        cell(
                            item, mode: modes[item.id] ?? .snapshot(note: ""), rect: rect, isActive: false,
                            interactive: false, fit: .widthFromBottom, metrics: DashboardGridMetrics(width: tile.width))
                            .frame(width: tile.width, height: tile.height)
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cells

    private enum CellMode {
        case live
        case snapshot(note: String)
    }

    /// Live up to each Host's share of the budget, top to bottom; a Herdr TUI
    /// Host never, since its attach takes the Pane over.
    private func cellModes(order: [ConsoleTerminal.ID]) -> [ConsoleTerminal.ID: CellMode] {
        let previewOnlyHosts = Set(hosts.consoleHosts.filter { $0.serverKind == .herdrTUI }.map(\.id))
        let liveIDs = Self.liveCellIDs(
            order: order, visible: visibleCellIDs, previewOnlyHosts: previewOnlyHosts,
            mode: console.powerSettings.mode)
        var modes: [ConsoleTerminal.ID: CellMode] = [:]
        for id in order {
            if previewOnlyHosts.contains(id.hostID) {
                modes[id] = .snapshot(note: String(localized: "Preview"))
            } else if liveIDs.contains(id) {
                modes[id] = .live
            } else {
                modes[id] = .snapshot(note: String(localized: "Preview · live limit"))
            }
        }
        return modes
    }

    /// Economy spends the live budget on visible cells; hidden cells cannot
    /// reserve all of a Host's slots above the viewport.
    static func liveCellIDs(
        order: [ConsoleTerminal.ID], visible: Set<ConsoleTerminal.ID>,
        previewOnlyHosts: Set<Host.ID>, mode: AppPowerMode
    ) -> Set<ConsoleTerminal.ID> {
        var used: [Host.ID: Int] = [:]
        var result: Set<ConsoleTerminal.ID> = []
        for id in order {
            guard !previewOnlyHosts.contains(id.hostID),
                mode == .performance || visible.contains(id),
                used[id.hostID, default: 0] < mode.dashboardLiveCellsPerHost
            else { continue }
            if result.insert(id).inserted { used[id.hostID, default: 0] += 1 }
        }
        return result
    }

    static func shouldRunCell(
        mode: AppPowerMode, isVisible: Bool, isCovered: Bool, isBackground: Bool
    ) -> Bool {
        !isBackground && (mode == .performance || (isVisible && !isCovered))
    }

    private func cell(
        _ item: ConsoleTerminal, mode: CellMode, rect: DashboardGridRect, isActive: Bool, interactive: Bool = true,
        fit: DashboardLiveTerminal.Fit = .whole, metrics: DashboardGridMetrics
    ) -> some View {
        let agent = agent(for: item)
        return VStack(spacing: 0) {
            header(item, agent: agent, rect: rect, interactive: interactive, metrics: metrics)
            Divider()
            cellBody(item, mode: mode, fit: fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { viewing = DashboardViewing(id: item.id) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens full screen")
                .accessibilityAction { viewing = DashboardViewing(id: item.id) }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isActive ? 2 : 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if interactive { resizeHandle(for: item.id, rect: rect, metrics: metrics) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.cell")
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            if isVisible {
                visibleCellIDs.insert(item.id)
            } else {
                visibleCellIDs.remove(item.id)
            }
        }
    }

    @ViewBuilder
    private func cellBody(_ item: ConsoleTerminal, mode: CellMode, fit: DashboardLiveTerminal.Fit) -> some View {
        if !Self.shouldRunCell(
            mode: console.powerSettings.mode, isVisible: visibleCellIDs.contains(item.id),
            isCovered: viewing != nil, isBackground: scenePhase == .background)
        {
            DashboardTileMessage(text: String(localized: "Paused"), showsProgress: false)
        } else {
            switch mode {
            case .live:
                let generation = console.hostConnectionGenerations[item.hostID]
                let runner = console.terminalRunner(for: item.hostID)
                let target: TerminalAttachTarget = item.isAgent ? .agentPane(item.paneID) : .terminal(item.terminalID)
                DashboardLiveTerminal(
                    terminal: terminal, powerSettings: console.powerSettings,
                    remoteColumns: item.gridColumns, remoteRows: item.gridRows, fit: fit,
                    onReconnect: { attempts[item.id, default: 0] += 1 },
                    makeStore: {
                        AttachTerminalStore(
                            target: target, takeover: false, viewer: .observe, isViewed: true,
                            transportGeneration: generation, runTerminal: runner)
                    })
                .id("\(item.hostID)|\(item.paneID)|\(generation ?? 0)|\(attempts[item.id] ?? 0)")
            case .snapshot(let note):
                DashboardSnapshotTerminal(
                    console: console, hostID: item.hostID, paneID: item.paneID, isAgent: item.isAgent, note: note)
            }
        }
    }

    private func header(
        _ item: ConsoleTerminal, agent: ConsoleAgent?, rect: DashboardGridRect, interactive: Bool,
        metrics: DashboardGridMetrics
    ) -> some View {
        HStack(spacing: 8) {
            if interactive {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            DashboardStatusMark(agent: agent)
            Text(agent.map(AgentTerminalView.displayTitle(for:)) ?? item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let agent, agent.agent.status.displayTitle != nil {
                AgentStatusBadge(status: agent.agent.status)
                    .fixedSize()
            }
            Text([item.hostName, item.workspaceLabel].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let columns = item.gridColumns, let rows = item.gridRows {
                Text(verbatim: "\(columns)×\(rows)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .highPriorityGesture(interactive ? moveGesture(for: item.id, rect: rect, metrics: metrics) : nil)
        .onTapGesture(count: 2) {
            guard interactive else { return }
            toggleFullWidth(item.id, rect: rect)
        }
        .accessibilityAction(named: "Toggle Full Width") { toggleFullWidth(item.id, rect: rect) }
    }

    private func resizeHandle(for id: ConsoleTerminal.ID, rect: DashboardGridRect, metrics: DashboardGridMetrics) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            DashboardResizeGrip()
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .shadow(color: .black.opacity(0.5), radius: 1)
                .frame(width: 14, height: 14)
                .padding(7)
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .highPriorityGesture(resizeGesture(for: id, rect: rect, metrics: metrics))
        .accessibilityLabel("Resize")
        .accessibilityIdentifier("dashboard.cell.resize")
    }

    // MARK: Gestures

    private func moveGesture(for id: ConsoleTerminal.ID, rect: DashboardGridRect, metrics: DashboardGridMetrics) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if interaction == nil { interaction = Interaction(id: id, kind: .move, start: rect) }
                interaction?.translation = value.translation
            }
            .onEnded { _ in finishInteraction(metrics: metrics) }
    }

    private func resizeGesture(for id: ConsoleTerminal.ID, rect: DashboardGridRect, metrics: DashboardGridMetrics) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if interaction == nil { interaction = Interaction(id: id, kind: .resize, start: rect) }
                interaction?.translation = value.translation
            }
            .onEnded { _ in finishInteraction(metrics: metrics) }
    }

    /// Lands the cell on its target and lets everything settle upward.
    private func finishInteraction(metrics: DashboardGridMetrics) {
        guard interaction != nil else { return }
        let base = layout.positions(for: shownTerminals.map(\.id))
        let preview = preview(base: base, metrics: metrics)
        withAnimation(settle) {
            layout.commit(DashboardGrid.compact(preview.positions))
            interaction = nil
        }
    }

    private func toggleFullWidth(_ id: ConsoleTerminal.ID, rect: DashboardGridRect) {
        var positions = layout.positions(for: shownTerminals.map(\.id))
        positions[id] =
            rect.w >= DashboardGrid.columns
            ? DashboardGridRect(x: 0, y: rect.y, w: DashboardGrid.defaultWidth, h: rect.h)
            : DashboardGridRect(x: 0, y: rect.y, w: DashboardGrid.columns, h: rect.h)
        withAnimation(settle) {
            layout.commit(DashboardGrid.compact(positions, pinned: id))
        }
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
                Picker("Layout", selection: $style) {
                    ForEach(Style.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                Divider()
                Button("Reset Layout", systemImage: "arrow.counterclockwise", role: .destructive) {
                    withAnimation(settle) { layout.reset() }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Two short diagonal strokes in a cell's corner, the usual resize grip.
private struct DashboardResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.maxY))
        return path
    }
}

struct DashboardViewing: Identifiable, Equatable {
    let id: ConsoleTerminal.ID
}

/// The status the Agents list shows, at header size: the program's mark in
/// its status ring (turning while it works). A shell Terminal has no status.
struct DashboardStatusMark: View {
    let agent: ConsoleAgent?

    var body: some View {
        if let agent {
            AgentStatusAvatar(mark: AgentKindMark(kind: agent.agent.kind), status: agent.agent.status, diameter: 24)
                .accessibilityLabel(Text(verbatim: agent.agent.status.displayTitle ?? ""))
        } else {
            Image(systemName: "apple.terminal")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}

/// One cell full screen, still watch-only: the Pane at the screen's width,
/// its bottom in view when it is taller than the screen, centered on black
/// when shorter. Its own observe Attach, so the cell keeps drawing behind it.
struct DashboardFullScreenView: View {
    let item: ConsoleTerminal
    let agent: ConsoleAgent?
    let terminal: TerminalSettings
    let console: ConsoleStore
    let isLive: Bool
    /// Nil shows it in place, as an Agent's or Terminal's locked detail:
    /// no close, and the window's status bar and appearance left alone.
    let onClose: (() -> Void)?
    let onTakeControl: () -> Void
    /// In place in a narrow window, where nothing else leads back.
    var onBack: (() -> Void)? = nil

    @State private var attempt = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if let onClose {
            content
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .gesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        if value.translation.height > 120, abs(value.translation.width) < 80 { onClose() }
                    })
        } else {
            content
                .environment(\.colorScheme, .dark)
        }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            Group {
                if isLive {
                    let generation = console.hostConnectionGenerations[item.hostID]
                    let runner = console.terminalRunner(for: item.hostID)
                    let target: TerminalAttachTarget = item.isAgent ? .agentPane(item.paneID) : .terminal(item.terminalID)
                    DashboardLiveTerminal(
                        terminal: terminal, powerSettings: console.powerSettings,
                        remoteColumns: item.gridColumns, remoteRows: item.gridRows,
                        fit: .widthFromBottom,
                        // In place it is a locked detail: pooled, so going back is instant.
                        pooled: onClose == nil
                            ? console.viewOnlyPool.state(for: .init(id: item.id, generation: generation, attempt: attempt))
                            : nil,
                        onReconnect: { attempt += 1 },
                        makeStore: {
                            AttachTerminalStore(
                                target: target, takeover: false, viewer: .observe, isViewed: true,
                                transportGeneration: generation, runTerminal: runner)
                        })
                    .id("\(generation ?? 0)|\(attempt)")
                } else {
                    DashboardSnapshotTerminal(
                        console: console, hostID: item.hostID, paneID: item.paneID, isAgent: item.isAgent,
                        note: String(localized: "Preview"))
                }
            }
            .padding(.top, 52)
            bar
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: onTakeControl) {
                Label("Take Control", systemImage: "hand.point.up.left.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.15)) }
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityIdentifier("dashboard.fullscreen.takeControl")
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if let onBack, horizontalSizeClass == .compact {
                Button("Back", systemImage: "chevron.backward", action: onBack)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            DashboardStatusMark(agent: agent)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.map(AgentTerminalView.displayTitle(for:)) ?? item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text([item.hostName, item.workspaceLabel].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let agent, agent.agent.status.displayTitle != nil {
                AgentStatusBadge(status: agent.agent.status)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let columns = item.gridColumns, let rows = item.gridRows {
                Text(verbatim: "\(columns)×\(rows)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let onClose {
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityIdentifier("dashboard.fullscreen.close")
            } else {
                Label("View only", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.black)
    }
}

/// The Pane closed while it was full screen.
struct DashboardFullScreenGone: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("This Pane has closed.")
                    .foregroundStyle(.secondary)
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .preferredColorScheme(.dark)
    }
}
