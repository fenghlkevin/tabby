import SwiftUI

/// Measure each card at its final column width and stretch siblings to the
/// tallest content in that row. Narrow windows wrap to fewer columns; no fixed
/// height clips expanded details or complete network addresses.
struct MonitoringEqualHeightGrid: Layout {
    var minimumWidth: CGFloat = 280
    var spacing: CGFloat = 14

    private struct Geometry {
        let width: CGFloat
        let columns: Int
        let columnWidth: CGFloat
        let rowHeights: [CGFloat]
    }

    private func geometry(width: CGFloat?, subviews: Subviews) -> Geometry {
        let available = max(1, width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth)
        let columns = max(1, min(subviews.count, Int((available + spacing) / (minimumWidth + spacing))))
        let columnWidth = max(1, (available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights = [CGFloat]()
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let row = index / columns
            if row == heights.count { heights.append(height) } else { heights[row] = max(heights[row], height) }
        }
        return Geometry(width: available, columns: columns, columnWidth: columnWidth, rowHeights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = geometry(width: proposal.width, subviews: subviews)
        return CGSize(width: layout.width, height: layout.rowHeights.reduce(0, +) + CGFloat(max(0, layout.rowHeights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = geometry(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / layout.columns, column = index % layout.columns
            if column == 0 && row > 0 { y += layout.rowHeights[row - 1] + spacing }
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.columnWidth + spacing), y: y), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: layout.columnWidth, height: layout.rowHeights[row]))
        }
    }
}
