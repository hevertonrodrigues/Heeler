import CoreGraphics

/// A Dashboard cell's place on the grid, in units: column `x` and row `y` of
/// its top-left corner, `w` columns wide and `h` rows tall.
struct DashboardGridRect: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var bottom: Int { y + h }

    func intersects(_ other: DashboardGridRect) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }
}

/// The Dashboard's grid rules, after react-grid-layout: a fixed number of
/// columns, cells that fall upward into free space ("vertical compaction"),
/// and a cell being dragged or resized that stays where the finger puts it
/// while the others move out of its way.
enum DashboardGrid {
    static let columns = 12
    static let minimumWidth = 2
    static let minimumHeight = 3
    static let defaultWidth = 6
    static let defaultHeight = 6

    static func clamped(_ rect: DashboardGridRect) -> DashboardGridRect {
        let w = min(max(rect.w, minimumWidth), columns)
        return DashboardGridRect(
            x: min(max(rect.x, 0), columns - w), y: max(rect.y, 0), w: w, h: max(rect.h, minimumHeight))
    }

    /// Lays `items` out without overlaps, each as high as it can float from
    /// where it is, in top-to-bottom, left-to-right order. `pinned`, the cell
    /// under the finger, keeps its place and the others flow around it.
    static func compact<ID: Hashable>(_ items: [ID: DashboardGridRect], pinned: ID? = nil) -> [ID: DashboardGridRect] {
        var placed: [ID: DashboardGridRect] = [:]
        if let pinned, let rect = items[pinned] {
            placed[pinned] = clamped(rect)
        }
        let others = items.filter { $0.key != pinned }.sorted { lhs, rhs in
            (lhs.value.y, lhs.value.x) < (rhs.value.y, rhs.value.x)
        }
        for (id, original) in others {
            var rect = clamped(original)
            func collision(_ candidate: DashboardGridRect) -> DashboardGridRect? {
                placed.values.first { $0.intersects(candidate) }
            }
            while rect.y > 0, collision(DashboardGridRect(x: rect.x, y: rect.y - 1, w: rect.w, h: rect.h)) == nil {
                rect.y -= 1
            }
            while let blocker = collision(rect) {
                rect.y = blocker.bottom
            }
            placed[id] = rect
        }
        return placed
    }

    /// The first place, top to bottom and left to right, where a cell of
    /// `w` × `h` fits among `occupied`.
    static func firstFit(w: Int, h: Int, among occupied: [DashboardGridRect]) -> DashboardGridRect {
        let w = min(max(w, minimumWidth), columns)
        var y = 0
        while true {
            for x in 0...(columns - w) {
                let candidate = DashboardGridRect(x: x, y: y, w: w, h: h)
                if !occupied.contains(where: { $0.intersects(candidate) }) { return candidate }
            }
            y += 1
        }
    }
}

/// Points for the grid at a given width: the frame a grid rect draws in, and
/// the grid rect nearest a frame the finger is moving.
struct DashboardGridMetrics: Equatable {
    static let rowHeight: CGFloat = 36
    static let gap: CGFloat = 12
    /// Below this width the grid stacks its cells full width, in order.
    static let minimumGridWidth: CGFloat = 560

    let width: CGFloat
    let columnWidth: CGFloat

    init(width: CGFloat) {
        self.width = width
        let columns = CGFloat(DashboardGrid.columns)
        columnWidth = max((width - Self.gap * (columns - 1)) / columns, 1)
    }

    var stacks: Bool { width < Self.minimumGridWidth }
    private var columnStep: CGFloat { columnWidth + Self.gap }
    private var rowStep: CGFloat { Self.rowHeight + Self.gap }

    func frame(of rect: DashboardGridRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * columnStep, y: CGFloat(rect.y) * rowStep,
            width: CGFloat(rect.w) * columnStep - Self.gap, height: CGFloat(rect.h) * rowStep - Self.gap)
    }

    func height(of rows: Int) -> CGFloat {
        rows > 0 ? CGFloat(rows) * rowStep - Self.gap : 0
    }

    /// The cell `frame` would snap to if dropped now, keeping `size`.
    func rect(movedTo frame: CGRect, size: DashboardGridRect) -> DashboardGridRect {
        DashboardGrid.clamped(
            DashboardGridRect(
                x: Int((frame.minX / columnStep).rounded()), y: Int((frame.minY / rowStep).rounded()),
                w: size.w, h: size.h))
    }

    /// The cell `frame` would snap to if released now, keeping `origin`.
    func rect(resizedTo frame: CGRect, origin: DashboardGridRect) -> DashboardGridRect {
        var rect = DashboardGridRect(
            x: origin.x, y: origin.y,
            w: Int(((frame.width + Self.gap) / columnStep).rounded()),
            h: Int(((frame.height + Self.gap) / rowStep).rounded()))
        rect.w = min(max(rect.w, DashboardGrid.minimumWidth), DashboardGrid.columns - origin.x)
        rect.h = max(rect.h, DashboardGrid.minimumHeight)
        return rect
    }

    /// The smallest frame a resize may shrink a cell to.
    var minimumSize: CGSize {
        frame(of: DashboardGridRect(x: 0, y: 0, w: DashboardGrid.minimumWidth, h: DashboardGrid.minimumHeight)).size
    }
}
