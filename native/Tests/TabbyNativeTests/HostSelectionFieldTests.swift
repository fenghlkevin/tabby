import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

final class HostSelectionFieldTests: XCTestCase {
    func testJumpChoicesExcludeSelfDescendantsCyclesAndMissingRoutes() {
        var edited = TabbyNative.Host(); edited.name = "Target"; edited.address = "target.invalid"
        var direct = TabbyNative.Host(); direct.name = "Direct"; direct.address = "direct.invalid"
        var viaDirect = TabbyNative.Host(); viaDirect.name = "Via direct"; viaDirect.jumpHostID = direct.id
        var viaTarget = TabbyNative.Host(); viaTarget.name = "Via target"; viaTarget.jumpHostID = edited.id
        var cycleA = TabbyNative.Host(); var cycleB = TabbyNative.Host(); cycleA.jumpHostID = cycleB.id; cycleB.jumpHostID = cycleA.id
        var missing = TabbyNative.Host(); missing.jumpHostID = UUID()
        let choices = JumpHostChoices.candidates(for: edited, hosts: [edited, direct, viaDirect, viaTarget, cycleA, cycleB, missing])
        XCTAssertEqual(choices.map(\.id), [direct.id, viaDirect.id])
        edited.jumpHostID = viaTarget.id
        XCTAssertEqual(JumpHostChoices.candidates(for: edited, hosts: [edited, direct, viaTarget]).map(\.id), [direct.id])
    }

    @MainActor func testGroupMenuSelectionAndWholeFieldBoundsSurviveUpdates() async throws {
        _ = NSApplication.shared
        var group = "Alpha"
        let binding = Binding<String>(get: { group }, set: { group = $0 })
        let picker = GroupPicker(selection: binding, groups: ["Alpha", "Beta"], chinese: true)
        let menu = picker.makeMenu(width: 304)
        XCTAssertEqual(menu.items.map(\.title), ["无分组", "Alpha", "Beta"])
        XCTAssertEqual(menu.items[1].state, .on)
        let selectBeta = try XCTUnwrap(menu.items[2].action)
        XCTAssertTrue(NSApp.sendAction(selectBeta, to: menu.items[2].target, from: menu.items[2]))
        XCTAssertEqual(group, "Beta")
        let selectNone = try XCTUnwrap(menu.items[0].action)
        XCTAssertTrue(NSApp.sendAction(selectNone, to: menu.items[0].target, from: menu.items[0]))
        XCTAssertEqual(group, "")
        let hosting = NSHostingView(rootView: picker.frame(width: 304, height: 38))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 38), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(find(SelectionFieldButton.self, in: hosting).first)
        let rect = button.convert(button.bounds, to: hosting)
        XCTAssertEqual(rect.width, 304, accuracy: 0.5); XCTAssertEqual(rect.height, 38, accuracy: 0.5)
        XCTAssertEqual(button.title, "无分组")
        for x in [CGFloat(0.25), 303.75] { for y in [CGFloat(0.25), 37.75] {
            XCTAssertTrue(button.hitTest(button.convert(NSPoint(x: x, y: y), to: button.superview)) === button)
        } }
        var opens = 0; button.onOpen = { opens += 1 }; button.performClick(nil)
        XCTAssertEqual(opens, 1)
        button.isEnabled = false; button.performClick(nil)
        XCTAssertEqual(opens, 1)
        try await captureJumpPickerIfRequested()
    }

    @MainActor func testActualRootLayoutSwitchUpdatesButtonAndRendersBothGroupLayouts() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.groups = ["Company", "Personal", "Imported", "Lab"]
        let hosting = NSHostingView(rootView: MainView().environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(find(NSSegmentedControl.self, in: hosting).first { $0.identifier?.rawValue == "host-layout-picker" })
        XCTAssertEqual(button.selectedSegment, 0)
        XCTAssertEqual(button.accessibilityValue() as? String, "网格视图")
        try capture(hosting, named: "host-library-grid")
        button.selectedSegment = 1
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.selectedSegment, 1)
        XCTAssertEqual(button.accessibilityValue() as? String, "列表视图")
        try capture(hosting, named: "host-library-list")
        XCTAssertTrue(store.sessions.isEmpty)
        button.selectedSegment = 0
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(button.selectedSegment, 0)
        XCTAssertEqual(button.accessibilityValue() as? String, "网格视图")
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
    @MainActor private func captureJumpPickerIfRequested() async throws {
        guard ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] != nil else { return }
        var candidate = TabbyNative.Host(); candidate.name = "Company gateway"; candidate.address = "192.0.2.10"; candidate.group = "Company"
        var second = TabbyNative.Host(); second.name = "Lab gateway"; second.address = "192.0.2.20"; second.group = "Lab"
        let hosting = NSHostingView(rootView: JumpHostChooser(selection: candidate.id, hosts: [candidate, second], chinese: true, select: { _ in }))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 390), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        try capture(hosting, named: "jump-host-chooser")
    }
    @MainActor private func capture(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }
}
