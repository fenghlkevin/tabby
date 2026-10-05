import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class BatchTasksUITests: XCTestCase {
    func testRealWorkspaceLayoutSelectionOutputAndRunningState() async throws {
        _ = NSApplication.shared
        let axKey = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(axKey)
        NSApp.accessibilitySetValue(true, forAttribute: axKey)
        defer { NSApp.accessibilitySetValue(previousAX ?? false, forAttribute: axKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-batch-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.section = "batchTasks"
        store.workspace.hosts = (0..<39).map { i in
            var host = TabbyNative.Host()
            host.name = i == 1 ? "production-api-with-a-very-long-host-name-供测试窄窗口" : "server-prod-" + String(i + 1)
            host.address = "172.26.150.\(200 + i)"; host.username = "root"; host.group = i < 6 ? "生产" : "测试"; host.tags = i < 3 ? "web" : "api"
            return host
        }
        store.batchTasks.command = "hostname\nuptime\ndf -h"
        let now = Date()
        store.batchTasks.results = (0..<3).map { i in
            var result = BatchResult(hostID: store.workspace.hosts[i].id, hostName: store.workspace.hosts[i].name)
            result.state = i == 2 ? "failed" : "success"; result.exitCode = i == 2 ? 1 : 0
            result.started = now.addingTimeInterval(-Double(i + 1)); result.finished = now
            result.output = i == 2 ? "" : "web-prod-0\(i + 1)\nFilesystem   Size  Used  Avail  Use%  Mounted on\n/dev/vda1    80G   31G   45G    41%  /"
            if i == 0 { result.output = "/root" }
            result.error = i == 2 ? "Permission denied / 权限不足" : ""
            return result
        }
        for (width, language): (CGFloat, String) in [(1050, "zh-CN"), (1400, "zh-CN"), (1050, "en-US")] {
            store.workspace.preferences.language = language
            let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light).tint(Palette.accent))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
            defer { window.close() }
            try await settle(hosting)
            XCTAssertEqual(find(PreferencesNavigationNativeButton.self, in: hosting).count, 10)
            let initialPageButtonY = try button("hosts-next", in: hosting).convert(.zero, to: hosting).y
            while try button("hosts-next", in: hosting).isEnabled {
                try click(try button("hosts-next", in: hosting)); try await settle(hosting)
            }
            XCTAssertEqual(try button("hosts-next", in: hosting).convert(.zero, to: hosting).y, initialPageButtonY, accuracy: 1)
            try capture(hosting, name: "batch-last-page-\(Int(width))-\(language)")
            while try button("hosts-previous", in: hosting).isEnabled {
                try click(try button("hosts-previous", in: hosting)); try await settle(hosting)
            }
            let run = try button("run", in: hosting)
            XCTAssertFalse(run.isEnabled)
            try press("axon-batch-host-" + store.workspace.hosts[0].id.uuidString, in: hosting)
            try await settle(hosting)
            XCTAssertTrue(try button("run", in: hosting).isEnabled)
            try click(try button("show-selected", in: hosting)); try await settle(hosting)
            XCTAssertEqual(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-batch-show-selected" }?.title, store.text("Back to all", "返回全部"))
            try capture(hosting, name: "batch-selected-review-\(Int(width))-\(language)")
            try click(try button("show-selected", in: hosting)); try await settle(hosting)
            try click(try button("hosts-next", in: hosting)); try await settle(hosting)
            try press("axon-batch-host-" + store.workspace.hosts[12].id.uuidString, in: hosting)
            try click(try button("hosts-previous", in: hosting)); try await settle(hosting)
            XCTAssertTrue(try button("run", in: hosting).isEnabled)
            let selectAll = try button("select-all", in: hosting)
            try click(selectAll)
            try await settle(hosting)
            XCTAssertTrue(try button("run", in: hosting).isEnabled)
            try capture(hosting, name: "batch-workspace-\(Int(width))-\(language)-selected")
            try click(try button("run", in: hosting)); try await settle(hosting)
            let sheet = try XCTUnwrap(window.attachedSheet)
            try press("axon-batch-confirm-cancel", in: XCTUnwrap(sheet.contentView))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(store.batchTasks.running, "Cancelling confirmation must not start any SSH task")
            try click(try button("clear", in: hosting)); try await settle(hosting)
            XCTAssertFalse(try button("run", in: hosting).isEnabled)
            let failed = store.batchTasks.results[2]
            try press("axon-batch-output-" + failed.id.uuidString, in: hosting); try await settle(hosting)
            try press("axon-batch-copy", in: hosting)
            XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("Permission denied") == true)
            try press("axon-batch-filter-failed", in: hosting); try await settle(hosting)
            XCTAssertEqual(store.batchTasks.results.filter { $0.state == "failed" }.count, 1)
            try capture(hosting, name: "batch-workspace-\(Int(width))-\(language)-failed")
            try press("axon-batch-filter-all", in: hosting); try await settle(hosting)
            let editor = try XCTUnwrap(find(NSTextView.self, in: hosting).first { $0.string == store.batchTasks.command })
            XCTAssertTrue(editor.isEditable)
            store.batchTasks.running = true
            store.batchTasks.results[0].state = "running"; store.batchTasks.results[0].finished = nil
            try await settle(hosting)
            XCTAssertFalse(editor.isEditable, "Running command snapshots must not be editable")
            XCTAssertFalse(try button("select-all", in: hosting).isEnabled)
            XCTAssertFalse(try button("retry", in: hosting).isEnabled)
            XCTAssertTrue(try button("cancel-all", in: hosting).isEnabled)
            try capture(hosting, name: "batch-workspace-\(Int(width))-\(language)-running")
            store.batchTasks.running = false
            store.batchTasks.results[0].state = "success"; store.batchTasks.results[0].finished = now
        }
        store.workspace.preferences.language = "zh-CN"
        store.batchTasks.results = []; store.workspace.hosts = []; store.batchTasks.command = ""
        let narrow = NSHostingView(rootView: BatchTasksView(center: store.batchTasks).environmentObject(store).preferredColorScheme(.light))
        narrow.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = narrow; window.orderFront(nil); defer { window.close() }
        try await settle(narrow)
        XCTAssertFalse(try button("run", in: narrow).isEnabled)
        XCTAssertFalse(try button("select-all", in: narrow).isEnabled)
        try capture(narrow, name: "batch-narrow-empty")
    }
    private func press(_ identifier: String, in root: NSView) throws {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
            if read("accessibilityIdentifier") as? String == identifier, read("accessibilityRole") as? String == "AXButton" { return object }
            for child in read("accessibilityChildren") as? [NSObject] ?? [] {
                if let found = visit(child, depth: depth + 1) { return found }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = visit(child, depth: depth + 1) { return found } }
            }
            return nil
        }
        let object = try XCTUnwrap(visit(root, depth: 0), identifier)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(object.responds(to: selector))
        let implementation = try XCTUnwrap(object.method(for: selector))
        let perform = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        XCTAssertTrue(perform(object, selector), identifier)
    }
    private func button(_ id: String, in view: NSView) throws -> PreferencesRectNativeButton {
        try XCTUnwrap(find(PreferencesRectNativeButton.self, in: view).first { $0.identifier?.rawValue == "axon-batch-" + id })
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) } }
    private func click(_ button: NSButton) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: button.bounds.width - 2, y: button.bounds.height - 2)] {
            let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
            XCTAssertTrue(hit === button, "Whole action area must remain clickable")
        }
        button.performClick(nil)
    }
    private func settle(_ view: NSView) async throws { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    private func capture(_ view: NSView, name: String) throws {
        for button in find(PreferencesRectNativeButton.self, in: view) {
            let frame = button.convert(button.bounds, to: view)
            XCTAssertGreaterThanOrEqual(frame.minX, -1, name)
            XCTAssertLessThanOrEqual(frame.maxX, view.bounds.width + 1, name)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-" + name + ".png"))
    }
}
