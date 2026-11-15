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

    @Test func newPanesKeepTheirOrderAfterRememberedOnes() {
        let store = DashboardLayoutStore(defaults: makeDefaults())
        store.setSpan(DashboardSpan(columns: 2, rows: 1), for: id("c"))
        #expect(store.arranged([id("a"), id("b"), id("c")]) == [id("c"), id("a"), id("b")])
    }

    @Test func moveAndSpanPersist() {
        let defaults = makeDefaults()
        let store = DashboardLayoutStore(defaults: defaults)
        let shown = [id("a"), id("b"), id("c")]
        store.move(id("c"), before: id("a"), in: shown)
        store.setSpan(DashboardSpan(columns: 2, rows: 2), for: id("b"))

        let reloaded = DashboardLayoutStore(defaults: defaults)
        #expect(reloaded.arranged(shown) == [id("c"), id("a"), id("b")])
        #expect(reloaded.span(for: id("b")) == DashboardSpan(columns: 2, rows: 2))
        #expect(reloaded.span(for: id("a")) == .standard)
    }

    @Test func goneEntriesStayUntilReset() {
        let defaults = makeDefaults()
        let store = DashboardLayoutStore(defaults: defaults)
        store.move(id("b"), before: id("a"), in: [id("a"), id("b"), id("gone")])
        #expect(store.arranged([id("a"), id("b")]) == [id("b"), id("a")])
        store.reset()
        #expect(store.entries.isEmpty)
        #expect(DashboardLayoutStore(defaults: defaults).entries.isEmpty)
    }

    @Test func metricsFitColumnsAndSnapSpans() {
        let metrics = DashboardGridMetrics(width: 1000)
        #expect(metrics.columns == 3)
        let twoByTwo = metrics.size(of: DashboardSpan(columns: 2, rows: 2))
        #expect(metrics.span(nearest: twoByTwo) == DashboardSpan(columns: 2, rows: 2))
        #expect(metrics.span(nearest: CGSize(width: 5000, height: 10)) == DashboardSpan(columns: 3, rows: 1))
        #expect(DashboardGridMetrics(width: 200).columns == 1)
    }
}
