import XCTest
import AppKit
@testable import TabbyNative

final class AuthenticationSelectorTests: XCTestCase {
    @MainActor private func control(selection: String = "password", enabled: Bool = true) -> BinaryChoiceView {
        let view = BinaryChoiceView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        view.configure(selection: selection, firstValue: "password", firstTitle: "Password",
                       secondValue: "key", secondTitle: "Private key", enabled: enabled)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @MainActor func testEntireNativeSegmentsReceiveClicksIncludingEmptyCorners() throws {
        _ = NSApplication.shared
        let view = control()
        var chosen: [String] = []
        view.onSelect = { chosen.append($0) }
        for (button, value) in [(view.firstButton, "password"), (view.secondButton, "key")] {
            XCTAssertEqual(button.frame.height, 36)
            for point in [
                NSPoint(x: button.frame.minX + 0.25, y: button.frame.minY + 0.25),
                NSPoint(x: button.frame.maxX - 0.25, y: button.frame.minY + 0.25),
                NSPoint(x: button.frame.minX + 0.25, y: button.frame.maxY - 0.25),
                NSPoint(x: button.frame.maxX - 0.25, y: button.frame.maxY - 0.25),
                NSPoint(x: button.frame.midX, y: button.frame.midY)
            ] {
                let hit = try XCTUnwrap(view.hitTest(point) as? NSButton)
                XCTAssertTrue(hit === button)
                hit.performClick(nil)
                XCTAssertEqual(chosen.last, value)
                XCTAssertEqual(view.selection, value)
            }
        }
        XCTAssertEqual(chosen.count, 10)
        XCTAssertFalse(view.firstButton.selected)
        XCTAssertTrue(view.secondButton.selected)
    }

    @MainActor func testDisabledSegmentsCannotChangeSelectionOrRunAction() {
        _ = NSApplication.shared
        let view = control(enabled: false)
        var changed = false
        view.onSelect = { _ in changed = true }
        view.secondButton.performClick(nil)
        XCTAssertEqual(view.selection, "password")
        XCTAssertFalse(changed)
        XCTAssertFalse(view.secondButton.acceptsFirstResponder)
    }

    @MainActor func testArrowAndSpaceSelectWithNativeKeyboardFocus() throws {
        _ = NSApplication.shared
        let view = control()
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view.firstButton))
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                                                  charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        view.firstButton.keyDown(with: right)
        XCTAssertEqual(view.selection, "key")
        XCTAssertTrue(window.firstResponder === view.secondButton)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertTrue(window.makeFirstResponder(view.firstButton))
        view.firstButton.keyDown(with: space)
        XCTAssertEqual(view.selection, "password")
    }

    @MainActor func testAccessibleSelectionAndAlternativeStoredValues() {
        _ = NSApplication.shared
        let view = control()
        view.configure(selection: "file", firstValue: "text", firstTitle: "Paste text",
                       secondValue: "file", secondTitle: "Choose file", enabled: true)
        XCTAssertEqual(view.firstButton.accessibilityLabel(), "Paste text")
        XCTAssertEqual(view.secondButton.accessibilityLabel(), "Choose file")
        XCTAssertEqual((view.secondButton.accessibilityValue() as? NSNumber)?.intValue, 1)
        XCTAssertFalse(view.firstButton.selected)
        XCTAssertTrue(view.secondButton.selected)
        view.firstButton.performClick(nil)
        XCTAssertEqual(view.selection, "text")
        XCTAssertEqual((view.secondButton.accessibilityValue() as? NSNumber)?.intValue, 0)
    }
}
