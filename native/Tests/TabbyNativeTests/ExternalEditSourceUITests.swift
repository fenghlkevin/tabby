import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative
@MainActor final class ExternalEditSourceUITests: XCTestCase {
    func testAlignedComparison() {
        let result = EditComparison.make(old: "first\nlast", new: "first\nadded\nlast")
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertNil(result.rows[1].oldNumber)
        XCTAssertEqual(result.rows[2].oldNumber, 2)
        XCTAssertEqual(result.rows[2].newNumber, 3)
        XCTAssertFalse(result.rows[2].changed)
        let replacement = EditComparison.make(old: "123", new: "123kkk")
        XCTAssertEqual(replacement.rows[0].oldText, "123")
        XCTAssertEqual(replacement.rows[0].newText, "123kkk")
        XCTAssertTrue(replacement.rows[0].changed)
    }
    func testComparisonRender() async throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)); store.workspace.preferences.language = "zh-CN"
        let comparison = EditComparison.make(old: "123\nunchanged\nremoved", new: "123kkk\nunchanged\nadded\nextra")
        for width in [700, 1000] {
            let view = NSHostingView(rootView: EditComparisonView(comparison: comparison).padding(20).environmentObject(store).preferredColorScheme(.light))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-diff-\(width).png"))
            window.close()
        }
    }
    func testSameFilenameDifferentHostsRenderSourceSnapshots() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let center = ExternalEditCenter()
        for i in 1...2 {
            var host = TabbyNative.Host(); host.name = "生产服务器-\(i)"; host.address = "server\(i).fixture.invalid"; host.username = "root"
            let edit = ExternalEdit(backend: LocalFiles(), entry: FileEntry(name: "nohup.out", path: "/root/nohup.out", directory: false), localURL: root.appendingPathComponent("copy\(i)/nohup.out"), original: Data())
            edit.sourceHost = host; edit.sourceUsername = "deployer"; center.edits.append(edit)
        }
        let view = NSHostingView(rootView: ExternalEditSheet(center: center, dismiss: {}).environmentObject(store).preferredColorScheme(.light))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(center.edits[0].sourceHost?.address, center.edits[1].sourceHost?.address)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-edit-sources.png"))
        center.edits.removeAll()
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        let empty = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: empty)
        try XCTUnwrap(empty.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-edit-empty.png"))
    }
}
