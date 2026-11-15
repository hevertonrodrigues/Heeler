import Foundation
import Observation

/// The Dashboard's arrangement: each cell's grid rect, keyed like pins by
/// `{hostID, paneID}`. Panes the Dashboard has never seen take the first free
/// place at the default size. Rects for Panes that are gone are kept (a tmux
/// or herdr Pane id can come back after a restart) until Reset.
@MainActor
@Observable
final class DashboardLayoutStore {
    struct Entry: Codable, Hashable, Sendable {
        let hostID: UUID
        let paneID: String
        var rect: DashboardGridRect

        var id: ConsoleTerminal.ID { ConsoleTerminal.ID(hostID: hostID, paneID: paneID) }
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [Entry]
    }

    static let defaultsKey = "dashboard.layout"
    private static let version = 2

    private(set) var entries: [Entry]
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == Self.version {
            entries = stored.entries
        } else {
            // Version 1 kept an order and spans, not places; start fresh.
            entries = []
        }
    }

    /// Where each of `ids` sits: remembered cells where they were, new ones in
    /// the first free place, all compacted so the grid has no holes.
    func positions(for ids: [ConsoleTerminal.ID]) -> [ConsoleTerminal.ID: DashboardGridRect] {
        let remembered = Dictionary(entries.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        var positions: [ConsoleTerminal.ID: DashboardGridRect] = [:]
        for id in ids {
            if let rect = remembered[id] { positions[id] = rect }
        }
        positions = DashboardGrid.compact(positions)
        for id in ids where positions[id] == nil {
            positions[id] = DashboardGrid.firstFit(
                w: DashboardGrid.defaultWidth, h: DashboardGrid.defaultHeight, among: Array(positions.values))
        }
        return positions
    }

    /// Keeps `positions` as the arrangement of those cells; other remembered
    /// cells stay as they were.
    func commit(_ positions: [ConsoleTerminal.ID: DashboardGridRect]) {
        var changed = false
        for (id, rect) in positions {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                if entries[index].rect != rect {
                    entries[index].rect = rect
                    changed = true
                }
            } else {
                entries.append(Entry(hostID: id.hostID, paneID: id.paneID, rect: rect))
                changed = true
            }
        }
        if changed { save() }
    }

    func reset() {
        entries = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(version: Self.version, entries: entries)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
