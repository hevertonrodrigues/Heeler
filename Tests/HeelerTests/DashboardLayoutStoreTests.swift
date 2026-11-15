import CoreGraphics
import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite struct DashboardLayoutStoreTests {
    private let suiteName = "DashboardLayoutStoreTests.\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private let host = UUID()
    private func id(_ pane: String) -> ConsoleTerminal.ID { ConsoleTerminal.ID(hostID: host, paneID: pane) }
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> DashboardGridRect {
        DashboardGridRect(x: x, y: y, w: w, h: h)
    }

    @Test func newPanesFillTheFirstFreePlaces() {
        let store = DashboardLayoutStore(defaults: makeDefaults())
        let positions = store.positions(for: [id("a"), id("b"), id("c")])
        #expect(positions[id("a")] == rect(0, 0, 6, 6))
        #expect(positions[id("b")] == rect(6, 0, 6, 6))
        #expect(positions[id("c")] == rect(0, 6, 6, 6))
    }

    @Test func committedPlacesPersistAndCompact() {
        let defaults = makeDefaults()
        let store = DashboardLayoutStore(defaults: defaults)
        store.commit([id("a"): rect(0, 10, 12, 4), id("b"): rect(0, 20, 4, 4)])
        let reloaded = DashboardLayoutStore(defaults: defaults)
        let positions = reloaded.positions(for: [id("a"), id("b")])
        // Both float up: no holes above them.
        #expect(positions[id("a")] == rect(0, 0, 12, 4))
        #expect(positions[id("b")] == rect(0, 4, 4, 4))
    }

    @Test func goneEntriesStayUntilReset() {
        let defaults = makeDefaults()
        let store = DashboardLayoutStore(defaults: defaults)
        store.commit([id("a"): rect(0, 0, 6, 6), id("gone"): rect(6, 0, 6, 6)])
        #expect(store.entries.count == 2)
        #expect(store.positions(for: [id("a")]).count == 1)
        store.reset()
        #expect(DashboardLayoutStore(defaults: defaults).entries.isEmpty)
    }

    @Test func pinnedCellPushesOthersDown() {
        let items = [id("a"): rect(0, 0, 6, 6), id("b"): rect(6, 0, 6, 6)]
        // Drag b over a's place: a moves below b.
        var moved = items
        moved[id("b")] = rect(0, 0, 6, 6)
        let positions = DashboardGrid.compact(moved, pinned: id("b"))
        #expect(positions[id("b")] == rect(0, 0, 6, 6))
        #expect(positions[id("a")] == rect(0, 6, 6, 6))
    }

    @Test func compactionNeverOverlaps() {
        let items = [
            id("a"): rect(0, 3, 8, 4), id("b"): rect(4, 0, 8, 5), id("c"): rect(2, 9, 4, 3), id("d"): rect(10, 2, 2, 9),
        ]
        let positions = Array(DashboardGrid.compact(items).values)
        for (index, lhs) in positions.enumerated() {
            for rhs in positions[(index + 1)...] { #expect(!lhs.intersects(rhs)) }
        }
    }

    @Test func metricsSnapToNearestCells() {
        let metrics = DashboardGridMetrics(width: 1188)  // 12 columns of 88 + 11 gaps of 12
        #expect(metrics.columnWidth == 88)
        let frame = metrics.frame(of: rect(2, 1, 4, 3))
        #expect(metrics.rect(movedTo: frame.offsetBy(dx: 30, dy: 10), size: rect(0, 0, 4, 3)) == rect(2, 1, 4, 3))
        #expect(metrics.rect(movedTo: frame.offsetBy(dx: 70, dy: 0), size: rect(0, 0, 4, 3)) == rect(3, 1, 4, 3))
        let grown = CGRect(origin: frame.origin, size: CGSize(width: frame.width + 100, height: frame.height))
        #expect(metrics.rect(resizedTo: grown, origin: rect(2, 1, 4, 3)) == rect(2, 1, 5, 3))
        #expect(DashboardGridMetrics(width: 400).stacks)
    }
}
