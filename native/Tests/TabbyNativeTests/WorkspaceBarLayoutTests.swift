import XCTest
@testable import TabbyNative

final class WorkspaceBarLayoutTests: XCTestCase {
    func testTwoRemoteTabsAndNewTabAreFullyVisibleAtNormalAndMinimumWindowSizes() {
        let content = WorkspaceTabStripSizing.contentWidth(sessionWidths: [200, 200], showsNewTab: true)
        XCTAssertEqual(content, 592)
        // Insets match the native traffic lights and the right margin. Widths include button padding.
        for windowWidth in [CGFloat(1400), CGFloat(1050)] {
            let sizing = WorkspaceTabStripSizing.measure(availableWidth: windowWidth - 84 - 14, contentWidth: content,
                                                        fixedControlWidths: [106, 92, 28], gapCount: 4)
            XCTAssertEqual(sizing.viewportWidth, content)
            XCTAssertFalse(sizing.needsScrolling)
            XCTAssertGreaterThanOrEqual(sizing.dragWidth, 40)
        }
    }

    func testOverflowScrollsInsteadOfCompressingTabsAndKeepsAddButtonOutsideViewport() {
        let available: CGFloat = 1050 - 84 - 14
        let content = WorkspaceTabStripSizing.contentWidth(sessionWidths: [240, 200, 200, 200, 200], showsNewTab: true)
        let fixed: [CGFloat] = [106, 92, 28, 28]
        let sizing = WorkspaceTabStripSizing.measure(availableWidth: available, contentWidth: content, fixedControlWidths: fixed, gapCount: 5)
        XCTAssertTrue(sizing.needsScrolling)
        XCTAssertEqual(sizing.dragWidth, 40)
        XCTAssertEqual(sizing.viewportWidth + sizing.dragWidth + fixed.reduce(0, +) + 5 * 6, available)
        let addButtonEnd = fixed[0] + fixed[1] + sizing.viewportWidth + fixed[2] + 3 * 6
        XCTAssertLessThan(addButtonEnd, available)
        XCTAssertGreaterThanOrEqual(sizing.viewportWidth, 180)
    }

    func testNoTabsGiveAllRemainingRoomToWindowDraggingAndContentSpacingIsExact() {
        XCTAssertEqual(WorkspaceTabStripSizing.contentWidth(sessionWidths: [], showsNewTab: false), 0)
        XCTAssertEqual(WorkspaceTabStripSizing.contentWidth(sessionWidths: [], showsNewTab: true), 180)
        XCTAssertEqual(WorkspaceTabStripSizing.contentWidth(sessionWidths: [240], showsNewTab: false), 240)
        XCTAssertEqual(WorkspaceTabStripSizing.contentWidth(sessionWidths: [240, 200], showsNewTab: true), 632)
        let sizing = WorkspaceTabStripSizing.measure(availableWidth: 800, contentWidth: 0, fixedControlWidths: [120, 92, 28], gapCount: 4)
        XCTAssertEqual(sizing.viewportWidth, 0)
        XCTAssertEqual(sizing.dragWidth, 536)
        XCTAssertFalse(sizing.needsScrolling)
    }

    func testControlsConsumeNarrowSpaceWithoutNegativeViewportOrDragWidths() {
        let sizing = WorkspaceTabStripSizing.measure(availableWidth: 250, contentWidth: 1000, fixedControlWidths: [106, 92, 28], gapCount: 4)
        XCTAssertEqual(sizing.viewportWidth, 0)
        XCTAssertEqual(sizing.dragWidth, 0)
        XCTAssertTrue(sizing.needsScrolling)
    }
}
