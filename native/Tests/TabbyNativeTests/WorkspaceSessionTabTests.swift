import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class WorkspaceSessionTabTests: XCTestCase {
    @MainActor func testNativeLabelStartsDragAfterThresholdAndClickControlsStayIndependent() throws {
        _ = NSApplication.shared
        let view = RecordingSessionTabView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        let window = testWindow(view)
        defer { window.close() }
        let id = UUID()
        view.configure(id: id, title: "root@Production (2)", selected: true, connected: true, dark: true,
                       chinese: true, remote: true, canMoveLeft: true, canMoveRight: true)
        var actions: [SessionTabAction] = []
        view.onAction = { actions.append($0) }
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.hitTest(NSPoint(x: 100, y: 17)) === view)

        window.isMovable = true
        let originalFrame = window.frame
        view.mouseDown(with: try mouse(.leftMouseDown, in: view, x: 100))
        XCTAssertFalse(window.isMovable)
        view.mouseDragged(with: try mouse(.leftMouseDragged, in: view, x: 102))
        XCTAssertEqual(view.drags.count, 0)
        view.mouseDragged(with: try mouse(.leftMouseDragged, in: view, x: 115))
        view.mouseDragged(with: try mouse(.leftMouseDragged, in: view, x: 140))
        view.mouseUp(with: try mouse(.leftMouseUp, in: view, x: 140))
        XCTAssertTrue(window.isMovable)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(view.drags.count, 1)
        XCTAssertEqual(view.drags.first?.string(forType: WorkspaceSessionDrag.type), id.uuidString)
        XCTAssertNil(view.drags.first?.string(forType: .string))
        XCTAssertTrue(actions.isEmpty, "Dragging an inactive tab must not activate or close it")

        for (x, expected) in [(CGFloat(100), SessionTabAction.select), (20, .close), (220, .tools)] {
            view.mouseDown(with: try mouse(.leftMouseDown, in: view, x: x))
            view.mouseUp(with: try mouse(.leftMouseUp, in: view, x: x))
            XCTAssertEqual(actions.last, expected)
        }
        view.mouseDown(with: try mouse(.leftMouseDown, in: view, x: 20))
        view.mouseDragged(with: try mouse(.leftMouseDragged, in: view, x: 100))
        view.mouseUp(with: try mouse(.leftMouseUp, in: view, x: 100))
        XCTAssertEqual(view.drags.count, 1, "Dragging from close must not start a tab drag or accidentally close")
        XCTAssertEqual(actions, [.select, .close, .tools])
    }

    @MainActor func testNativeDropUsesPointerSideAndRejectsForeignStaleAndSelfDrags() throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = TerminalSession(host: nil, store: store), b = TerminalSession(host: nil, store: store), c = TerminalSession(host: nil, store: store)
        store.sessions = [a, b, c]; store.activeSession = a.id; store.section = "terminal"
        let target = NativeSessionTabView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        let window = testWindow(target)
        defer { window.close() }
        target.configure(id: b.id, title: b.displayTitle, selected: false, connected: false, dark: true,
                         chinese: true, remote: false, canMoveLeft: true, canMoveRight: true)
        target.canDropSession = { id in store.sessions.contains { $0.id == id } }
        target.onDropSession = { id, placement in
            if placement == .split { store.pairSessions(id, with: b.id) }
            else if placement == .before { store.moveSession(id, before: b.id) }
            else { store.moveSession(id, after: b.id) }
        }
        let left = DragInfo(id: c.id, window: window, point: target.convert(NSPoint(x: 20, y: 17), to: nil))
        XCTAssertEqual(target.draggingEntered(left), .move)
        XCTAssertEqual(target.dropPlacement, .before)
        XCTAssertTrue(target.prepareForDragOperation(left))
        XCTAssertTrue(target.performDragOperation(left))
        XCTAssertEqual(store.sessions.map(\.id), [a.id, c.id, b.id])
        XCTAssertNil(target.dropPlacement)
        let right = DragInfo(id: a.id, window: window, point: target.convert(NSPoint(x: target.bounds.width - 20, y: 17), to: nil))
        XCTAssertEqual(target.draggingEntered(right), .move)
        XCTAssertEqual(target.dropPlacement, .after)
        XCTAssertTrue(target.performDragOperation(right))
        XCTAssertEqual(store.sessions.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(store.activeSession, a.id)
        let center = DragInfo(id: a.id, window: window, point: target.convert(NSPoint(x: target.bounds.midX, y: 17), to: nil))
        let originalIDs = store.sessions.map(\.id)
        XCTAssertEqual(target.draggingEntered(center), .move)
        XCTAssertEqual(target.dropPlacement, .split)
        XCTAssertTrue(target.performDragOperation(center))
        XCTAssertEqual(store.sessions.map(\.id), originalIDs)
        XCTAssertEqual(store.splitPartners[a.id], b.id)
        XCTAssertEqual(store.splitPartners[b.id], a.id)
        XCTAssertEqual(store.terminalTabs.count, 2)
        XCTAssertFalse(store.terminalTabs.contains { $0.id == a.id && store.terminalTabs.contains { $0.id == b.id } })
        XCTAssertEqual(store.activeSession, b.id)
        store.pairSessions(c.id, with: b.id)
        XCTAssertNil(store.splitPartners[a.id])
        XCTAssertEqual(store.splitPartners[c.id], b.id)

        for rejected in [DragInfo(id: b.id, window: window, point: .zero),
                         DragInfo(id: UUID(), window: window, point: .zero),
                         DragInfo(id: c.id, window: window, point: .zero, type: .string),
                         DragInfo(id: c.id, window: window, point: .zero, mask: .copy)] {
            XCTAssertEqual(target.draggingEntered(rejected), [])
            XCTAssertFalse(target.prepareForDragOperation(rejected))
            XCTAssertFalse(target.performDragOperation(rejected))
            XCTAssertNil(target.dropPlacement)
        }
        XCTAssertEqual(store.sessions.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(target.draggingEntered(left), .move)
        target.draggingExited(left)
        XCTAssertNil(target.dropPlacement)
    }

    @MainActor func testReorderMenuUsesCurrentBoundaryStateAndDispatchesNativeActions() throws {
        let app = NSApplication.shared
        let view = NativeSessionTabView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        view.configure(id: UUID(), title: "Local terminal", selected: false, connected: false, dark: true,
                       chinese: true, remote: false, canMoveLeft: false, canMoveRight: true)
        var actions: [SessionTabAction] = []
        view.onAction = { actions.append($0) }
        let menu = view.makeMenu()
        let left = try XCTUnwrap(menu.items.first { $0.tag == SessionTabAction.moveLeft.rawValue })
        let right = try XCTUnwrap(menu.items.first { $0.tag == SessionTabAction.moveRight.rawValue })
        XCTAssertEqual(left.title, "标签左移"); XCTAssertFalse(left.isEnabled)
        XCTAssertEqual(right.title, "标签右移"); XCTAssertTrue(right.isEnabled)
        XCTAssertEqual(menu.items.first { $0.tag == SessionTabAction.moveFirst.rawValue }?.title, "移到最前")
        XCTAssertEqual(menu.items.first { $0.tag == SessionTabAction.moveLast.rawValue }?.title, "移到最后")
        XCTAssertTrue(app.sendAction(try XCTUnwrap(left.action), to: left.target, from: left))
        XCTAssertTrue(app.sendAction(try XCTUnwrap(right.action), to: right.target, from: right))
        XCTAssertEqual(actions, [.moveRight])
        view.configure(id: view.sessionID, title: view.title, selected: true, connected: true, dark: false,
                       chinese: false, remote: true, canMoveLeft: true, canMoveRight: false)
        let updated = view.makeMenu()
        XCTAssertEqual(updated.items.first { $0.tag == SessionTabAction.moveLeft.rawValue }?.title, "Move tab left")
        XCTAssertTrue(try XCTUnwrap(updated.items.first { $0.tag == SessionTabAction.moveLeft.rawValue }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(updated.items.first { $0.tag == SessionTabAction.moveRight.rawValue }).isEnabled)
        XCTAssertTrue(updated.items.contains { $0.tag == SessionTabAction.reconnect.rawValue })
        // A still-open stale menu must not move past the newly reached boundary.
        XCTAssertTrue(app.sendAction(try XCTUnwrap(right.action), to: right.target, from: right))
        XCTAssertEqual(actions, [.moveRight])
        let accessibleClose = try XCTUnwrap(view.accessibilityCustomActions()?.first { $0.name == "Close tab" })
        XCTAssertTrue(try XCTUnwrap(accessibleClose.handler)())
        XCTAssertEqual(actions, [.moveRight, .close])
    }

    @MainActor func testMovingBeforeAfterAndMenuDirectionsPreservesLiveSessionsAndSplitTitles() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var host = TabbyNative.Host(); host.name = "Production"; host.address = "192.0.2.10"; host.username = "root"
        let a = TerminalSession(host: host, store: store), b = TerminalSession(host: host, store: store), c = TerminalSession(host: host, store: store)
        a.connected = true; b.connected = true; a.status = "live connection"
        store.sessions = [a, b, c]; store.activeSession = b.id; store.section = "terminal"
        store.splitPartners = [a.id: b.id, b.id: a.id]
        let titles = store.sessionTitles, split = store.splitPartners
        store.moveSession(a.id, after: b.id)
        XCTAssertEqual(store.sessions.map(\.id), [b.id, a.id, c.id])
        store.moveSession(c.id, before: b.id)
        XCTAssertEqual(store.sessions.map(\.id), [c.id, b.id, a.id])
        store.moveSession(a.id, by: -1)
        XCTAssertEqual(store.sessions.map(\.id), [c.id, a.id, b.id])
        store.moveSession(c.id, by: 1)
        XCTAssertEqual(store.sessions.map(\.id), [a.id, c.id, b.id])
        store.moveSessionToBeginning(b.id)
        store.moveSessionToEnd(a.id)
        XCTAssertEqual(store.sessions.map(\.id), [b.id, c.id, a.id])
        store.moveSession(c.id, by: Int.min)
        XCTAssertEqual(store.sessions.map(\.id), [c.id, b.id, a.id])
        store.moveSession(c.id, by: Int.max)
        XCTAssertEqual(store.sessions.map(\.id), [b.id, a.id, c.id])
        let stableOrder = store.sessions.map(\.id)
        store.moveSession(c.id, by: 1); store.moveSession(b.id, by: -1)
        store.moveSession(a.id, after: a.id); store.moveSession(a.id, after: UUID())
        store.moveSession(UUID(), by: 1); store.moveSessionToBeginning(UUID()); store.moveSessionToEnd(UUID())
        XCTAssertEqual(store.sessions.map(\.id), stableOrder)
        XCTAssertTrue(store.sessions[0] === b); XCTAssertTrue(store.sessions[1] === a); XCTAssertTrue(store.sessions[2] === c)
        XCTAssertEqual(store.activeSession, b.id); XCTAssertEqual(store.section, "terminal")
        XCTAssertEqual(store.splitPartners, split); XCTAssertEqual(store.sessionTitles, titles)
        XCTAssertTrue(a.connected); XCTAssertTrue(b.connected); XCTAssertEqual(a.status, "live connection")
    }

    @MainActor func testSwiftUIBridgeKeepsWholeNativeHitAreaAtBothTabWidths() async throws {
        _ = NSApplication.shared
        let id = UUID()
        func tab(_ selected: Bool) -> some View {
            NativeSessionTab(id: id, title: "root@Production (2)", selected: selected, connected: true, dark: true,
                             chinese: true, remote: true, canMoveLeft: true, canMoveRight: true,
                             onAction: { _ in }, canDropSession: { _ in true }, onDropSession: { _, _ in })
                .frame(width: selected ? 240 : 200, height: 34).frame(width: 240, height: 34, alignment: .leading)
        }
        let hosting = NSHostingView(rootView: tab(false)); hosting.sizingOptions = []
        let window = testWindow(hosting, width: 240)
        defer { window.close() }
        for selected in [false, true, false] {
            hosting.rootView = tab(selected)
            let native = try await bridgedTab(in: hosting)
            XCTAssertEqual(native.sessionID, id)
            XCTAssertEqual(native.bounds.width, selected ? 240 : 200, accuracy: 0.5)
            XCTAssertEqual(native.bounds.height, 34, accuracy: 0.5)
            XCTAssertEqual(native.accessibilityLabel(), "root@Production (2)")
            for point in [NSPoint(x: 1, y: 1), NSPoint(x: native.bounds.width - 1, y: 33), NSPoint(x: 100, y: 17)] {
                let hostPoint = native.convert(point, to: hosting)
                XCTAssertTrue(hosting.hitTest(hosting.convert(hostPoint, to: hosting.superview)) === native)
            }
            if let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
                let destination = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(selected ? "session-tab-active.png" : "session-tab-inactive.png"))
            }
        }
    }

    @MainActor private func bridgedTab(in hosting: NSView) async throws -> NativeSessionTabView {
        func collect(_ view: NSView) -> [NativeSessionTabView] {
            (view as? NativeSessionTabView).map { [$0] } ?? view.subviews.flatMap { collect($0) }
        }
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if collect(hosting).count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30)); hosting.layoutSubtreeIfNeeded()
        return try XCTUnwrap(collect(hosting).first)
    }
    @MainActor private func testWindow(_ view: NSView, width: CGFloat = 240) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 34), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        return window
    }
    @MainActor private func mouse(_ type: NSEvent.EventType, in view: NSView, x: CGFloat) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: 17), to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class RecordingSessionTabView: NativeSessionTabView {
    var drags: [NSPasteboardItem] = []
    override func beginTabDrag(with event: NSEvent) { drags.append(draggingPasteboardItem()) }
}

@MainActor private final class DragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("axon-tab-test-" + UUID().uuidString))
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(id: UUID, window: NSWindow, point: NSPoint, type: NSPasteboard.PasteboardType = WorkspaceSessionDrag.type, mask: NSDragOperation = .move) {
        draggingDestinationWindow = window; draggingSourceOperationMask = mask; draggingLocation = point
        super.init()
        draggingPasteboard.setString(id.uuidString, forType: type)
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
