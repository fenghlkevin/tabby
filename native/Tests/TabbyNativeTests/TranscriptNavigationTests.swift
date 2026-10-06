import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class TranscriptNavigationTests: XCTestCase {
    func testLocateFromMountedHistorySwitchesToOutputAndRepeatedRequestReloadsLiveData() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(old ?? false, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store)
        let history = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let entry = ExecutedCommand(hostID: nil, hostName: "定位测试服务器", sessionID: session.id, command: "pwd")
        history.append(entry)
        let id = try store.sessionLogs.begin(session: session)
        defer { store.sessionLogs.stop(id) }
        store.sessionLogs.append(Array("before\n".utf8), id: id)
        store.sessionLogs.marker(entry, report: "test", id: id)
        store.sessionLogs.append(Array("/root\n".utf8), id: id)
        let host = NSHostingView(rootView: LogsView(history: history).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded() }
        func press(_ title: String) throws {
            let button = try XCTUnwrap(nodes(host).first { $0.isButton && $0.title.contains(title) }, title)
            click(button, in: window)
        }
        try await settle()
        try press("定位测试服务器"); try await settle()
        try press("定位输出"); try await settle()
        let output = try XCTUnwrap(nodes(host).compactMap { $0.object as? NSTextView }.first { $0.accessibilityIdentifier() == "axon-transcript-output" })
        XCTAssertEqual(store.sessionLogs.selectedID, id)
        XCTAssertEqual(store.sessionLogs.selectedMarker, entry.id)
        XCTAssertEqual(output.string, "before\n/root\n")
        XCTAssertEqual(output.selectedRange().location, 7)
        if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let folder = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("locate-output-result.png"))
        }
        try press("操作历史"); try await settle()
        try press("定位测试服务器"); try await settle()
        let previousRequest = store.sessionLogs.navigationRequest
        try press("定位输出"); try await settle()
        XCTAssertNotEqual(store.sessionLogs.navigationRequest, previousRequest)
        XCTAssertNotNil(nodes(host).compactMap { $0.object as? NSTextView }.first { $0.accessibilityIdentifier() == "axon-transcript-output" })
        store.sessionLogs.append(Array("new live output\n".utf8), id: id)
        XCTAssertTrue(store.sessionLogs.locate(entry)); try await settle()
        let refreshed = try XCTUnwrap(nodes(host).compactMap { $0.object as? NSTextView }.first { $0.accessibilityIdentifier() == "axon-transcript-output" })
        XCTAssertTrue(refreshed.string.contains("new live output"))
        XCTAssertEqual(refreshed.selectedRange().location, 7)
    }
    func testLongOutputCanScrollToLastColumnAndLastLine() async throws {
        _ = NSApplication.shared
        let line = String(repeating: "长输出-column-", count: 150) + "END-COLUMN"
        let text = Array(repeating: line, count: 200).joined(separator: "\n") + "\nLAST-LINE"
        let host = NSHostingView(rootView: TranscriptTextSurface(text: text, selection: nil, foreground: .white, background: .black).frame(width: 500, height: 260))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(nodes(host).compactMap { $0.object as? TranscriptScrollView }.first)
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let used = try XCTUnwrap(view.layoutManager).usedRect(for: try XCTUnwrap(view.textContainer))
        XCTAssertEqual(view.string, text)
        XCTAssertGreaterThan(view.frame.width, scroll.contentSize.width * 5)
        XCTAssertGreaterThanOrEqual(view.frame.width, used.width + 24)
        XCTAssertGreaterThanOrEqual(view.frame.height, used.height + 24)
        scroll.contentView.scroll(to: NSPoint(x: view.frame.width - scroll.contentSize.width, y: view.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 1000)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
        if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let folder = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("long-output-scrolled.png"))
        }
    }

    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var title: String { ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read($0) as? String }.first { !$0.isEmpty } ?? "" }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var isButton: Bool { read("accessibilityRole") as? String == NSAccessibility.Role.button.rawValue }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { view.subviews.forEach { visit($0, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    private func click(_ node: Node, in window: NSWindow) {
        // SwiftUI uses accessibility elements rather than NSButton tracking.
        // Exercise its actual press action, without synthetic hardware state.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.object.responds(to: selector) else { XCTFail("Button has no press action"); return }
        let press = unsafeBitCast(node.object.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        _ = press(node.object, selector)
    }
}
