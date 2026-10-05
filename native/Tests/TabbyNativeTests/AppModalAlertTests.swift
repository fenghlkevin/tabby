import XCTest
import AppKit
@testable import TabbyNative

final class AppModalAlertTests: XCTestCase {
    @MainActor func testInputDialogKeepsFocusValueAndCompactLayout() throws {
        let alert = AppModalAlert(); alert.messageText = "新建目录"
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "test-directory")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        var sawWindow = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let window = NSApp.modalWindow, let view = window.contentView {
                sawWindow = true
                XCTAssertLessThan(view.bounds.width, 600)
                XCTAssertLessThan(view.bounds.height, 400)
                XCTAssertGreaterThanOrEqual(field.frame.height, 24)
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/axon-0.8.8-dialog.png"))
                }
            }
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
        XCTAssertEqual(alert.runModal(), .alertSecondButtonReturn)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(field.stringValue, "test-directory")
    }
}
