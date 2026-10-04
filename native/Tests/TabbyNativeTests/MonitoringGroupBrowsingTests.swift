import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class MonitoringGroupBrowsingTests: XCTestCase {
    func testRootGroupsUseVaultAndConnectedSessionGroupsWithoutFlatteningHosts() {
        let entries = [entry("production.invalid", group: "Production", connected: true), entry("staging.invalid", group: "staging"), entry("quick.invalid", group: "Ad hoc"), entry("local.invalid", group: "")]
        let root = MonitoringBrowseCatalog(entries: entries, declaredGroups: ["Production", "Staging", "Empty", "production"], scope: nil, query: "")
        XCTAssertTrue(root.isRootBrowse)
        XCTAssertEqual(root.groups.map(\.name), ["Ad hoc", "Empty", "Production", "Staging"])
        XCTAssertEqual(root.groups.first { $0.name == "Production" }?.hostCount, 1)
        XCTAssertEqual(root.groups.first { $0.name == "Production" }?.connectedCount, 1)
        XCTAssertEqual(root.groups.first { $0.name == "Empty" }?.hostCount, 0)
        XCTAssertEqual(root.visibleEntries.map(\.address), ["local.invalid"], "Root browsing must not dump every grouped host into cards")

        let group = MonitoringBrowseCatalog(entries: entries, declaredGroups: [], scope: .group("STAGING"), query: " staging.invalid ")
        XCTAssertEqual(group.visibleEntries.map(\.address), ["staging.invalid"])
        XCTAssertTrue(MonitoringBrowseCatalog(entries: entries, declaredGroups: [], scope: .group("Production"), query: "staging").visibleEntries.isEmpty)
        XCTAssertEqual(MonitoringBrowseCatalog(entries: entries, declaredGroups: [], scope: nil, query: "Production").visibleEntries.map(\.address), ["production.invalid"], "Root search searches all groups")
        XCTAssertEqual(MonitoringBrowseCatalog(entries: entries, declaredGroups: [], scope: .all, query: "").visibleEntries.count, 4)
    }

    func testNativeGroupCornersNavigateAndReturnWithListSearchAndIndependentConnect() async throws {
        _ = NSApplication.shared
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let restore = enableAccessibility(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-group-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        var production = host("Production server", address: "127.0.0.1", group: "Production")
        production.username = "test"; production.auth = "key"
        production.port = try XCTUnwrap(info["port"] as? Int); production.keyPath = try XCTUnwrap(info["clientKey"] as? String)
        let staging = host("Staging server", address: "staging.invalid", group: "Staging")
        let ungrouped = host("Ungrouped server", address: "ungrouped.invalid", group: "")
        store.workspace.hosts = [production, staging, ungrouped]; store.workspace.groups = ["Empty"]
        store.workspace.trustedKeys["127.0.0.1:\(production.port)"] = try XCTUnwrap(info["hostKey"] as? String)
        let preferences = store.workspace.preferences
        store.section = "monitoring"
        let center = store.monitoring; center.configure(store: store, terminalStatusVisible: false, foreground: false)
        defer { center.stop(); for session in store.sessions { session.disconnect() } }
        for width: CGFloat in [650, 1100] {
            for session in store.sessions { session.disconnect() }
            store.sessions = []; store.activeSession = nil
            center.connectionsChanged()
            let hosting = NSHostingView(rootView: MonitoringVaultView(center: center).environmentObject(store).preferredColorScheme(.light)); hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 840), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
            defer { window.close() }
            try await settle(hosting)
            XCTAssertEqual(find(MonitoringGroupNativeButton.self, in: hosting).count, 3)
            XCTAssertEqual(find(MonitoringTerminalNativeButton.self, in: hosting).map { $0.identifier?.rawValue }, ["monitoring-connect-ungrouped.invalid"])
            try capture(hosting, name: "monitor-groups-root-\(Int(width))")
            let group = try XCTUnwrap(find(MonitoringGroupNativeButton.self, in: hosting).first { $0.title == "Production" })
            try activateAtPoint(group, point: NSPoint(x: group.bounds.width - 3, y: group.bounds.height - 3))
            try await settle(hosting)
            XCTAssertTrue(find(MonitoringGroupNativeButton.self, in: hosting).isEmpty)
            let connect = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            XCTAssertEqual(connect.identifier?.rawValue, "monitoring-connect-127.0.0.1")
            XCTAssertFalse(connect.isBordered, "The monitor action uses the application flat surface, not a system bezel")
            XCTAssertTrue(store.sessions.isEmpty); XCTAssertNil(center.selectedTargetID, "Grouping must neither connect nor select a target")
            try capture(hosting, name: "monitor-group-cards-\(Int(width))")

            let picker = try XCTUnwrap(find(NSSegmentedControl.self, in: hosting).first)
            picker.selectedSegment = 1; picker.sendAction(picker.action, to: picker.target)
            try await settle(hosting)
            try capture(hosting, name: "monitor-group-list-\(Int(width))")
            let rowConnect = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            rowConnect.isEnabled = false
            try activateAtPoint(rowConnect, point: NSPoint(x: 3, y: 3))
            XCTAssertTrue(store.sessions.isEmpty, "A disabled native connect action must not create a terminal")
            rowConnect.isEnabled = true
            try activateAtPoint(rowConnect, point: NSPoint(x: 3, y: 3))
            XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.sessions.first?.host?.id, production.id)
            XCTAssertEqual(store.section, "monitoring"); XCTAssertNil(store.activeSession)
            XCTAssertNil(center.selectedTargetID, "The whole connect button activates only login, not the sibling detail action")
            let session = try XCTUnwrap(store.sessions.first)
            XCTAssertNotNil(session.terminal); XCTAssertNotNil(session.task)
            for _ in 0..<300 where !session.connected { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(session.connected, session.status)
            XCTAssertEqual(store.section, "monitoring"); XCTAssertNil(store.activeSession)
            try await settle(hosting)
            XCTAssertTrue(find(MonitoringGroupNativeButton.self, in: hosting).isEmpty, "Connection preserves the current group")

            store.section = "monitoring"
            try press(identifier: "monitoring-groups-back", in: hosting); try await settle(hosting)
            XCTAssertEqual(find(MonitoringGroupNativeButton.self, in: hosting).count, 3)
            XCTAssertEqual(picker.selectedSegment, 1, "List selection survives group navigation")
            try press(identifier: "monitoring-all-hosts", in: hosting); try await settle(hosting)
            XCTAssertEqual(find(MonitoringTerminalNativeButton.self, in: hosting).count, 3)
            XCTAssertEqual(store.sessions.count, 1)
            try press(identifier: "monitoring-groups-back", in: hosting); try await settle(hosting)

            let field = try XCTUnwrap(find(NSTextField.self, in: hosting).first { $0.placeholderString == "Search hosts, addresses or groups" })
            field.stringValue = "Production"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await settle(hosting)
            XCTAssertTrue(find(MonitoringGroupNativeButton.self, in: hosting).isEmpty)
            XCTAssertEqual(find(MonitoringTerminalNativeButton.self, in: hosting).map { $0.identifier?.rawValue }, ["monitoring-connect-127.0.0.1"])
            try capture(hosting, name: "monitor-group-search-\(Int(width))")
            XCTAssertEqual(store.workspace.hosts, [production, staging, ungrouped]); XCTAssertEqual(store.workspace.groups, ["Empty"])
            XCTAssertEqual(store.workspace.preferences, preferences, "Group/search/layout selection and login do not change connection metadata or settings")
        }
    }

    private func entry(_ address: String, group: String, connected: Bool = false) -> MonitoringEntry { MonitoringEntry(id: MonitoringTargetID(address: address, port: 22, username: "qa"), label: address, address: address, group: group, isConnected: connected) }
    private func host(_ label: String, address: String, group: String) -> TabbyNative.Host { var item = TabbyNative.Host(); item.name = label; item.address = address; item.username = "qa"; item.group = group; return item }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func activateAtPoint(_ button: NSButton, point: NSPoint) throws {
        let window = try XCTUnwrap(button.window)
        XCTAssertTrue(button.hitTest(button.convert(point, to: button.superview)) === button)
        let content = try XCTUnwrap(window.contentView)
        let hitTarget = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
        XCTAssertTrue(hitTarget === button, "The complete window hierarchy must route this point to the native action")
        // Synthetic mouse events do not change the hardware pressed state
        // AppKit tracking reads. Validate the real full-window hit path, then
        // activate that exact native control. Real clicks are verified in the
        // isolated running-app preview separately.
        try XCTUnwrap(hitTarget as? NSButton).performClick(nil)
    }
    private func enableAccessibility() -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(attribute) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
    }
    private func press(identifier: String, in root: NSView) throws {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any) -> NSObject? {
            guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.responds(to: NSSelectorFromString("accessibilityIdentifier")), node.value(forKey: "accessibilityIdentifier") as? String == identifier { return node }
            if node.responds(to: NSSelectorFromString("accessibilityChildren")) {
                for child in node.value(forKey: "accessibilityChildren") as? [Any] ?? [] { if let match = visit(child) { return match } }
            }
            if let view = node as? NSView { for child in view.subviews { if let match = visit(child) { return match } } }
            return nil
        }
        let node = try XCTUnwrap(visit(root), "Missing control: " + identifier)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
    }
    private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
