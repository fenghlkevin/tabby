import SwiftUI

enum WorkspaceTabDimensions {
    static let inactive: CGFloat = 200
    static let active: CGFloat = 240
    static let newTab: CGFloat = 180
    static let spacing: CGFloat = 6
    static let minimumDragArea: CGFloat = 40
}

struct WorkspaceTabStripSizing {
    let viewportWidth: CGFloat
    let dragWidth: CGFloat
    let contentWidth: CGFloat
    var needsScrolling: Bool { contentWidth > viewportWidth }

    static func contentWidth(sessionWidths: [CGFloat], showsNewTab: Bool) -> CGFloat {
        let count = sessionWidths.count + (showsNewTab ? 1 : 0)
        return sessionWidths.reduce(0, +) + (showsNewTab ? WorkspaceTabDimensions.newTab : 0)
            + CGFloat(max(0, count - 1)) * WorkspaceTabDimensions.spacing
    }

    static func measure(availableWidth: CGFloat, contentWidth: CGFloat, fixedControlWidths: [CGFloat], gapCount: Int) -> Self {
        let flexibleWidth = max(0, availableWidth - fixedControlWidths.reduce(0, +) - CGFloat(gapCount) * WorkspaceTabDimensions.spacing)
        let dragReserve = min(WorkspaceTabDimensions.minimumDragArea, flexibleWidth)
        let viewport = min(contentWidth, max(0, flexibleWidth - dragReserve))
        return Self(viewportWidth: viewport, dragWidth: flexibleWidth - viewport, contentWidth: contentWidth)
    }
}

/// Children are vault, SFTP, tab scroller, add button, drag area, and optional terminal tools.
/// The drag area receives only the space left after the tab scroller's explicit viewport.
struct WorkspaceBarLayout: Layout {
    let tabContentWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fixed = subviews.indices.filter { $0 != 2 && $0 != 4 }.map { subviews[$0].sizeThatFits(.unspecified).width }
        let idealWidth = fixed.reduce(0, +) + tabContentWidth + WorkspaceTabDimensions.minimumDragArea
            + CGFloat(max(0, subviews.count - 1)) * WorkspaceTabDimensions.spacing
        return CGSize(width: proposal.width ?? idealWidth, height: proposal.height ?? 52)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = subviews.indices.map { index in
            index == 2 || index == 4 ? CGFloat.zero : subviews[index].sizeThatFits(.unspecified).width
        }
        let sizing = WorkspaceTabStripSizing.measure(availableWidth: bounds.width, contentWidth: tabContentWidth,
                                                     fixedControlWidths: measured, gapCount: max(0, subviews.count - 1))
        var x = bounds.minX
        for index in subviews.indices {
            let width = index == 2 ? sizing.viewportWidth : index == 4 ? sizing.dragWidth : measured[index]
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                                  proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + WorkspaceTabDimensions.spacing
        }
    }
}
