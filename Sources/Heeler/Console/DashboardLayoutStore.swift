import Foundation
import Observation

/// The size of one Dashboard cell, in grid units: columns across, rows down.
struct DashboardSpan: Codable, Hashable, Sendable {
    var columns: Int
    var rows: Int

    static let standard = DashboardSpan(columns: 1, rows: 1)
    static let maximumColumns = 4
    static let maximumRows = 4

    func clamped(toColumns available: Int) -> DashboardSpan {
        DashboardSpan(
            columns: min(max(columns, 1), max(available, 1), Self.maximumColumns),
            rows: min(max(rows, 1), Self.maximumRows))
    }
}

/// The Dashboard's arrangement: the order of its cells and each one's span,
/// keyed like pins by `{hostID, paneID}`. Panes the Dashboard has never seen
/// join at the end at the standard span; entries for Panes that are gone are
/// kept (a tmux or herdr Pane id can come back after a restart) and only
/// dropped by Reset.
@MainActor
@Observable
final class DashboardLayoutStore {
    struct Entry: Codable, Hashable, Sendable {
        let hostID: UUID
        let paneID: String
        var span: DashboardSpan

        var id: ConsoleTerminal.ID { ConsoleTerminal.ID(hostID: hostID, paneID: paneID) }
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [Entry]
    }

    static let defaultsKey = "dashboard.layout"
    private static let version = 1

    private(set) var entries: [Entry]
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == Self.version {
            entries = stored.entries
        } else {
            entries = []
        }
    }

    /// `ids` in Dashboard order: remembered ones as arranged, new ones after
    /// them in the order given.
    func arranged(_ ids: [ConsoleTerminal.ID]) -> [ConsoleTerminal.ID] {
        let present = Set(ids)
        let remembered = entries.map(\.id).filter { present.contains($0) }
        let known = Set(remembered)
        return remembered + ids.filter { !known.contains($0) }
    }

    func span(for id: ConsoleTerminal.ID) -> DashboardSpan {
        entries.first { $0.id == id }?.span ?? .standard
    }

    func setSpan(_ span: DashboardSpan, for id: ConsoleTerminal.ID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            guard entries[index].span != span else { return }
            entries[index].span = span
        } else {
            entries.append(Entry(hostID: id.hostID, paneID: id.paneID, span: span))
        }
        save()
    }

    /// Moves `moving` to just before `target` within the arrangement of
    /// `shown`, the cells on screen now, remembering every one of them so the
    /// new order survives Panes coming and going.
    func move(_ moving: ConsoleTerminal.ID, before target: ConsoleTerminal.ID, in shown: [ConsoleTerminal.ID]) {
        guard moving != target else { return }
        var order = arranged(shown)
        guard let from = order.firstIndex(of: moving) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(moving, at: to)
        let spans = Dictionary(entries.map { ($0.id, $0.span) }, uniquingKeysWith: { first, _ in first })
        let reordered = order.map { Entry(hostID: $0.hostID, paneID: $0.paneID, span: spans[$0] ?? .standard) }
        // Entries for Panes not shown now keep their relative place at the end.
        let shownSet = Set(order)
        entries = reordered + entries.filter { !shownSet.contains($0.id) }
        save()
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
