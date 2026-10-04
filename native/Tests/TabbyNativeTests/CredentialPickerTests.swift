import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class CredentialPickerTests: XCTestCase {
    @MainActor func testSwiftUIBridgeKeepsExactFieldBoundsAndCornersThroughRerender() async throws {
        _ = NSApplication.shared
        var credential = VaultCredential(); credential.name = "Shared fixture"; credential.username = "test"
        func picker(_ id: UUID?, enabled: Bool) -> some View {
            CredentialPicker(selectedID: .constant(id), credentials: [credential], chinese: true, enabled: enabled, onNew: {})
                .frame(width: 304, height: 38)
        }
        let hosting = NSHostingView(rootView: picker(nil, enabled: true))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 38), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        let selections: [UUID?] = [nil, credential.id]
        for id in selections {
            hosting.rootView = picker(id, enabled: true)
            let button = try await bridgedButton(in: hosting)
            let rect = button.convert(button.bounds, to: hosting)
            XCTAssertEqual(rect.minX, 0, accuracy: 0.5)
            XCTAssertEqual(rect.minY, 0, accuracy: 0.5)
            XCTAssertEqual(rect.width, 304, accuracy: 0.5)
            XCTAssertEqual(rect.height, 38, accuracy: 0.5)
            XCTAssertEqual(button.bounds.width, 304, accuracy: 0.5)
            XCTAssertEqual(button.bounds.height, 38, accuracy: 0.5)
            XCTAssertEqual(button.title, id == nil ? "仅用于此主机" : credential.name)
            for x in [CGFloat(0.25), button.bounds.width - 0.25] {
                for y in [CGFloat(0.25), button.bounds.height - 0.25] {
                    let local = NSPoint(x: x, y: y)
                    XCTAssertTrue(button.hitTest(button.convert(local, to: button.superview)) === button)
                    let hostPoint = button.convert(local, to: hosting)
                    XCTAssertTrue(hosting.hitTest(hosting.convert(hostPoint, to: hosting.superview)) === button)
                }
            }
        }
        hosting.rootView = picker(credential.id, enabled: false)
        let disabledButton = try await bridgedButton(in: hosting)
        XCTAssertFalse(disabledButton.isEnabled)
    }

    @MainActor private func bridgedButton(in hosting: NSView) async throws -> CredentialPickerButton {
        func collect(_ view: NSView) -> [CredentialPickerButton] {
            let own = (view as? CredentialPickerButton).map { [$0] } ?? []
            return own + view.subviews.flatMap { collect($0) }
        }
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if collect(hosting).count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        let buttons = collect(hosting)
        XCTAssertEqual(buttons.count, 1)
        return try XCTUnwrap(buttons.first)
    }

    @MainActor func testFieldHitAreaAndMenuRerenderTrackCurrentSelectionAndLabels() throws {
        _ = NSApplication.shared
        var first = VaultCredential(); first.name = "Production"; first.username = "deploy"
        var second = VaultCredential(); second.name = "Personal"; second.username = "alice"
        let button = CredentialPickerButton(frame: NSRect(x: 0, y: 0, width: 304, height: 38))
        button.configure(selectedID: nil, credentials: [first, second], chinese: true, enabled: true)
        XCTAssertEqual(button.intrinsicContentSize.height, 38)
        XCTAssertEqual(button.title, "仅用于此主机")
        XCTAssertEqual(button.symbolName, "person.fill")
        for point in [NSPoint(x: 0.25, y: 0.25), NSPoint(x: 303.75, y: 0.25),
                      NSPoint(x: 0.25, y: 37.75), NSPoint(x: 303.75, y: 37.75), NSPoint(x: 152, y: 19)] {
            XCTAssertTrue(button.hitTest(point) === button)
        }
        let initial = button.makeMenu()
        XCTAssertEqual(initial.numberOfItems, 5)
        XCTAssertEqual(initial.item(at: 0)?.state, .on)
        XCTAssertEqual(initial.item(at: 1)?.title, "Production · deploy")
        XCTAssertEqual(initial.item(at: 4)?.title, "新建共享凭据…")
        first.name = "Renamed"; first.username = "ops"
        button.configure(selectedID: first.id, credentials: [first, second], chinese: true, enabled: true)
        XCTAssertEqual(button.title, "Renamed")
        XCTAssertEqual(button.symbolName, "key.fill")
        XCTAssertEqual(button.accessibilityLabel(), "选择登录凭据")
        XCTAssertEqual(button.accessibilityValue() as? String, "Renamed")
        let updated = button.makeMenu()
        XCTAssertEqual(updated.item(at: 0)?.state, .off)
        XCTAssertEqual(updated.item(at: 1)?.state, .on)
        XCTAssertEqual(updated.item(at: 1)?.title, "Renamed · ops")
        button.configure(selectedID: first.id, credentials: [second], chinese: false, enabled: true)
        XCTAssertEqual(button.title, "Credential unavailable")
        XCTAssertEqual(button.makeMenu().item(at: 1)?.state, .off)
    }

    @MainActor func testNativeMenuActionsSelectIndependentSharedAndCreateAndRespectDisabledState() throws {
        let app = NSApplication.shared
        var credential = VaultCredential(); credential.name = "Shared"; credential.username = "test"
        let button = CredentialPickerButton(frame: NSRect(x: 0, y: 0, width: 304, height: 38))
        button.configure(selectedID: nil, credentials: [credential], chinese: false, enabled: true)
        var calls = 0
        var selected: UUID?
        var creates = 0
        button.onSelect = { selected = $0; calls += 1 }
        button.onNew = { creates += 1 }
        func send(_ menu: NSMenu, _ index: Int) throws {
            let item = try XCTUnwrap(menu.item(at: index))
            XCTAssertTrue(app.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        try send(button.makeMenu(), 1)
        XCTAssertEqual(selected, credential.id)
        XCTAssertEqual(button.selectedID, credential.id)
        try send(button.makeMenu(), 0)
        XCTAssertNil(selected)
        XCTAssertNil(button.selectedID)
        try send(button.makeMenu(), 3)
        XCTAssertEqual(creates, 1)
        button.configure(selectedID: nil, credentials: [credential], chinese: false, enabled: false)
        let disabled = button.makeMenu()
        XCTAssertFalse(try XCTUnwrap(disabled.item(at: 1)).isEnabled)
        XCTAssertFalse(button.acceptsFirstResponder)
        try send(disabled, 1)
        try send(disabled, 3)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(creates, 1)
        XCTAssertNil(button.selectedID)
    }
}
