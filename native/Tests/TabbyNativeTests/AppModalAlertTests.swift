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
    @MainActor func testSnippetDeleteAndCancelViaNativeMouseClickPersistCorrectly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var value = CommandSnippet(); value.name = "ls 副本 · 长名称用于删除确认"; value.body = "ls -lah"; try store.saveSnippet(value)
        var other = CommandSnippet(); other.name = "保留片段"; other.body = "pwd"; try store.saveSnippet(other)
        for index in [1, 0] {
            var clicked = false
            let fallback = DispatchWorkItem { XCTFail("Modal button did not end the dialog"); NSApp.stopModal(withCode: .abort) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let window = NSApp.modalWindow, let view = window.contentView else { XCTFail("Missing modal"); return }
                func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
                guard let button = buttons(view).first(where: { $0.identifier?.rawValue == "axon-modal-action-\(index)" }) else { XCTFail("Missing native action"); return }
                XCTAssertTrue(button.isEnabled); XCTAssertEqual(button.keyEquivalent, index == 1 ? "\r" : "")
                let point = button.convert(NSPoint(x: 5, y: button.bounds.midY), to: nil)
                XCTAssertTrue(view.hitTest(view.superview?.convert(point, from: nil) ?? point) === button, "Padding is clickable")
                if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let dir = URL(fileURLWithPath: path); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("snippet-delete-\(index).png"))
                }
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                NSApp.postEvent(up, atStart: true); window.sendEvent(down); clicked = true
            }
            store.confirmSnippetDeletion(value); fallback.cancel(); XCTAssertTrue(clicked)
            XCTAssertEqual(store.workspace.snippets.contains(where: { $0.id == value.id }), index == 1)
            let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL))
            XCTAssertEqual(saved.snippets.contains(where: { $0.id == value.id }), index == 1)
            XCTAssertTrue(saved.snippets.contains(where: { $0.id == other.id }))
        }
    }

}
