import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

final class SFTPHostPickerBackTests: XCTestCase {
    @MainActor func testWholeHeadingPaddingArrowAndTextAreOneActionAtNarrowWidth() async throws {
        _ = NSApplication.shared
        let calls = Calls()
        let hosting = NSHostingView(rootView: AnyView(SFTPHostPickerBackButton(title: "选择主机", label: "返回文件列表", action: { calls.count += 1 }).frame(width: 150, height: 40)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        let button = try await findButton(in: hosting)
        XCTAssertEqual(button.bounds.width, 150, accuracy: 0.5)
        XCTAssertEqual(button.bounds.height, 40, accuracy: 0.5)
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 149, y: 39), NSPoint(x: 18, y: 20), NSPoint(x: 80, y: 20), NSPoint(x: 140, y: 20)] {
            XCTAssertTrue(button.hitTest(button.convert(point, to: button.superview)) === button)
            try pressAt(button, point: point)
        }
        XCTAssertEqual(calls.count, 5)
        hosting.rootView = AnyView(SFTPHostPickerBackButton(title: "选择主机", label: "返回文件列表", action: { calls.count += 10 }).frame(width: 150, height: 40).disabled(true))
        try await Task.sleep(for: .milliseconds(30))
        let disabled = try await findButton(in: hosting)
        XCTAssertFalse(disabled.isEnabled)
        disabled.performClick(nil)
        XCTAssertEqual(calls.count, 5)
    }

    @MainActor func testActualPickerBackKeepsExistingPaneAndPath() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        model.local = FilePane(path: root.path, backend: LocalFiles())
        await model.selectLocal(path: root.path)
        let previous = try XCTUnwrap(model.remote)
        model.showHostPicker()
        XCTAssertTrue(model.showingHostPicker)
        let hosting = NSHostingView(rootView: SFTPHostPicker(model: model).environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.close() }
        let button = try await findButton(in: hosting)
        let frame = button.convert(button.bounds, to: hosting)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 300)
        try pressAt(button, point: NSPoint(x: 80, y: 20))
        XCTAssertFalse(model.showingHostPicker)
        XCTAssertTrue(model.remote === previous)
        XCTAssertEqual(model.remote?.path, root.path)
        if let output = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("sftp-back-heading-300.png"))
        }
    }

    @MainActor func testInitialPickerBackReturnsToCurrentLocalFolder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        model.local = FilePane(path: root.path, backend: LocalFiles())
        model.showHostPicker()
        XCTAssertNil(model.remote)
        let hosting = NSHostingView(rootView: SFTPHostPicker(model: model).environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.close() }
        let button = try await findButton(in: hosting)
        XCTAssertTrue(button.isEnabled)
        try pressAt(button, point: NSPoint(x: 140, y: 20))
        for _ in 0..<50 where model.showingHostPicker { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.showingHostPicker)
        XCTAssertEqual(model.remote?.path, root.path)
        XCTAssertTrue(model.rightIsLocal)
    }

    @MainActor private func pressAt(_ button: NSButton, point: NSPoint) throws {
        let window = try XCTUnwrap(button.window)
        let content = try XCTUnwrap(window.contentView)
        let target = content.hitTest(button.convert(point, to: content.superview))
        XCTAssertTrue(target === button, "The window must route arrow, text and padding to the same button")
        try XCTUnwrap(target as? NSButton).performClick(nil)
    }

    @MainActor private func findButton(in hosting: NSView) async throws -> SFTPHostPickerNativeBackButton {
        func collect(_ view: NSView) -> [SFTPHostPickerNativeBackButton] {
            (view as? SFTPHostPickerNativeBackButton).map { [$0] } ?? view.subviews.flatMap { collect($0) }
        }
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if let button = collect(hosting).first { return button }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(collect(hosting).first)
    }
}

@MainActor private final class Calls { var count = 0 }
