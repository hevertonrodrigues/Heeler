import SwiftUI

/// The Dashboard's grid geometry for a given width: how many unit columns fit
/// and how large one unit is. The layout and the resize handle both read it,
/// so a drag maps onto the same cells the layout draws.
struct DashboardGridMetrics: Equatable {
    static let minimumUnitWidth: CGFloat = 300
    static let unitHeight: CGFloat = 220
    static let spacing: CGFloat = 12

    let columns: Int
    let unitWidth: CGFloat

    init(width: CGFloat) {
        let spacing = Self.spacing
        let fitting = Int(((width + spacing) / (Self.minimumUnitWidth + spacing)).rounded(.down))
        columns = min(max(fitting, 1), DashboardSpan.maximumColumns)
        unitWidth = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
    }

    func size(of span: DashboardSpan) -> CGSize {
        CGSize(
            width: unitWidth * CGFloat(span.columns) + Self.spacing * CGFloat(span.columns - 1),
            height: Self.unitHeight * CGFloat(span.rows) + Self.spacing * CGFloat(span.rows - 1))
    }

    /// The span whose cell is nearest `size`, for a resize drag.
    func span(nearest size: CGSize) -> DashboardSpan {
        let columns = Int(((size.width + Self.spacing) / (unitWidth + Self.spacing)).rounded())
        let rows = Int(((size.height + Self.spacing) / (Self.unitHeight + Self.spacing)).rounded())
        return DashboardSpan(columns: columns, rows: rows).clamped(toColumns: self.columns)
    }
}

private struct DashboardSpanKey: LayoutValueKey {
    static let defaultValue = DashboardSpan.standard
}

extension View {
    func dashboardSpan(_ span: DashboardSpan) -> some View {
        layoutValue(key: DashboardSpanKey.self, value: span)
    }
}

/// Packs cells of different spans into unit columns, in order, each into the
/// first free place that holds it (top to bottom, left to right).
struct DashboardGridLayout: Layout {
    struct Cache {
        var width: CGFloat = -1
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? DashboardGridMetrics.minimumUnitWidth
        pack(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        pack(width: bounds.width, subviews: subviews, cache: &cache)
        for (subview, frame) in zip(subviews, cache.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func pack(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        // Packed afresh on every pass: a span change does not always reach
        // updateCache, and a few dozen cells cost nothing to pack.
        let metrics = DashboardGridMetrics(width: width)
        var occupied: [[Bool]] = []
        var frames: [CGRect] = []
        var bottom = 0

        func isFree(row: Int, column: Int, span: DashboardSpan) -> Bool {
            for r in row..<(row + span.rows) {
                guard r < occupied.count else { continue }
                for c in column..<(column + span.columns) where occupied[r][c] { return false }
            }
            return true
        }

        for subview in subviews {
            let span = subview[DashboardSpanKey.self].clamped(toColumns: metrics.columns)
            var row = 0
            var placed: (row: Int, column: Int)?
            while placed == nil {
                for column in 0...(metrics.columns - span.columns) where isFree(row: row, column: column, span: span) {
                    placed = (row, column)
                    break
                }
                if placed == nil { row += 1 }
            }
            guard let placed else { continue }
            while occupied.count < placed.row + span.rows {
                occupied.append(Array(repeating: false, count: metrics.columns))
            }
            for r in placed.row..<(placed.row + span.rows) {
                for c in placed.column..<(placed.column + span.columns) { occupied[r][c] = true }
            }
            bottom = max(bottom, placed.row + span.rows)
            let size = metrics.size(of: span)
            frames.append(
                CGRect(
                    x: CGFloat(placed.column) * (metrics.unitWidth + DashboardGridMetrics.spacing),
                    y: CGFloat(placed.row) * (DashboardGridMetrics.unitHeight + DashboardGridMetrics.spacing),
                    width: size.width, height: size.height))
        }
        cache.width = width
        cache.frames = frames
        cache.height =
            bottom == 0
            ? 0 : CGFloat(bottom) * DashboardGridMetrics.unitHeight + CGFloat(bottom - 1) * DashboardGridMetrics.spacing
    }
}
