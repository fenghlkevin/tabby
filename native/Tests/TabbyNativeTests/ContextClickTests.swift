import XCTest
import AppKit
@testable import TabbyNative

final class ContextClickTests: XCTestCase {
    @MainActor func testRightClickOnlyInsideVisibleSurfaceAndControlClick() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = parent
        window.orderFront(nil)
        let surface = ContextClickView(frame: NSRect(x: 20, y: 20, width: 200, height: 100)); parent.addSubview(surface)
        var clicks = 0; surface.action = { _ in clicks += 1 }
        func event(_ type: NSEvent.EventType, point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        XCTAssertFalse(surface.handle(try event(.leftMouseDown, point: NSPoint(x: 50, y: 50))))
        XCTAssertFalse(surface.handle(try event(.rightMouseDown, point: NSPoint(x: 250, y: 150))))
        XCTAssertTrue(surface.handle(try event(.rightMouseDown, point: NSPoint(x: 50, y: 50))))
        XCTAssertTrue(surface.handle(try event(.leftMouseDown, point: NSPoint(x: 50, y: 50), flags: .control)))
        surface.isHidden = true
        XCTAssertFalse(surface.handle(try event(.rightMouseDown, point: NSPoint(x: 50, y: 50))))
        XCTAssertEqual(clicks, 2)
        XCTAssertNil(surface.hitTest(NSPoint(x: 50, y: 50)))
        surface.stopMonitoring()
    }
}
