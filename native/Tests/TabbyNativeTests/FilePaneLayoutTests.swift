import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

final class FilePaneLayoutTests: XCTestCase {
    func testDividerStoresVisibleProportionAfterDraggingToEitherLimit() {
        for requested in [CGFloat(-2), CGFloat(3)] {
            let dragged = FileSplitMetrics(width: 1200, fraction: requested)
            let stored = dragged.visibleFraction
            XCTAssertGreaterThan(stored, 0)
            XCTAssertLessThan(stored, 1)
            let enlarged = FileSplitMetrics(width: 2000, fraction: stored)
            XCTAssertEqual(enlarged.leftWidth / enlarged.availableWidth, stored, accuracy: 0.001)
            XCTAssertGreaterThan(enlarged.leftWidth, 300)
            XCTAssertGreaterThan(enlarged.rightWidth, 300)
        }
        XCTAssertEqual(FileSplitMetrics(width: 4, fraction: 0).visibleFraction, 0.5)
        XCTAssertEqual(FileSplitMetrics(width: 0, fraction: 1).visibleFraction, 0.5)
    }

    func testFilterMovesToItsOwnRowAtNarrowWidthsAndRemainsInlineWhenWide() {
        for width in [CGFloat(300), CGFloat(321), CGFloat(519)] {
            let hidden = FilePaneToolbarLayout(width: width, showingFilter: false, filter: "")
            XCTAssertTrue(hidden.compact)
            XCTAssertFalse(hidden.showsFilterRow)
            XCTAssertEqual(hidden.height, 52)
            for layout in [FilePaneToolbarLayout(width: width, showingFilter: true, filter: ""),
                           FilePaneToolbarLayout(width: width, showingFilter: false, filter: "name")] {
                XCTAssertTrue(layout.showsFilterRow)
                XCTAssertFalse(layout.showsInlineFilter)
                XCTAssertEqual(layout.height, 92)
            }
        }
        for width in [CGFloat(520), CGFloat(650)] {
            let layout = FilePaneToolbarLayout(width: width, showingFilter: true, filter: "name")
            XCTAssertFalse(layout.compact)
            XCTAssertTrue(layout.showsInlineFilter)
            XCTAssertFalse(layout.showsFilterRow)
            XCTAssertEqual(layout.height, 52)
        }
    }

    @MainActor func testExpandedFilterReservesOneRowWithoutEnlargingActualNarrowFilePane() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        defer { model.close() }
        let pane = FilePane(path: root.path, backend: LocalFiles())
        pane.entries = [FileEntry(name: "fixture.txt", path: root.appendingPathComponent("fixture.txt").path, directory: false)]
        pane.filter = "fixture"
        model.local = pane
        let hosting = NSHostingView(rootView: FilePaneView(pane: pane, model: model, remote: false).environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func tables(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).flatMap { $0.documentView is FileNativeTable ? $0 : nil }.map { [$0] } ?? []
            return own + view.subviews.flatMap { tables(in: $0) }
        }
        func tableFrame(width: CGFloat) async throws -> NSRect {
            window.setContentSize(NSSize(width: width, height: 420))
            for _ in 0..<50 {
                hosting.layoutSubtreeIfNeeded()
                if !tables(in: hosting).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(tables(in: hosting).first)
            let frame = scroll.convert(scroll.bounds, to: hosting)
            XCTAssertEqual(frame.width, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            XCTAssertEqual(pane.filter, "fixture")
            return frame
        }
        let wide = try await tableFrame(width: 650)
        let narrow = try await tableFrame(width: 300)
        XCTAssertEqual(wide.height - narrow.height, FilePaneToolbarLayout.filterRowHeight, accuracy: 1)
        let restored = try await tableFrame(width: 650)
        XCTAssertEqual(restored.height, wide.height, accuracy: 1)
    }
}
