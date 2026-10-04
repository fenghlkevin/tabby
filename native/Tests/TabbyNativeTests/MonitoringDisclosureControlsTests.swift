import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class MonitoringDisclosureControlsTests: XCTestCase {
    func testSystemMountWholeRowHitPathNativeActionAndAXToggleActualCardsAt650And1100() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for width: CGFloat in [650, 1100] {
            let state = HostState()
            let hosting = NSHostingView(rootView: StorageHarness(snapshot: fixture.snapshot, state: state)
                .environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, width: width); defer { window.close() }
            try await settle(hosting)

            let button = try disclosure(in: hosting)
            XCTAssertEqual(button.bounds.height, 32, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(button.bounds.width, width - 70, "The header must fill the padded storage section")
            XCTAssertLessThanOrEqual(button.bounds.width, width - 44 + 1)
            XCTAssertTrue(button.target === button)
            XCTAssertNotNil(button.action)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)

            // Every region must traverse the actual window hierarchy and toggle
            // the real cards in both directions, rather than a test-only flag.
            let points = rowPoints(button)
            for (region, point) in points {
                try activateWindowHit(button, point: point, region: region)
                try await settle(hosting)
                try assertState(expanded: true, in: window, native: button, snapshot: fixture.snapshot)
                try activateWindowHit(button, point: point, region: region)
                try await settle(hosting)
                try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)
            }

            // Dispatch the installed native selector and target separately from
            // performClick, then press the same explicit AXButton in the AX tree.
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            try await settle(hosting)
            try assertState(expanded: true, in: window, native: button, snapshot: fixture.snapshot)
            XCTAssertTrue(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)
            XCTAssertTrue(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: true, in: window, native: button, snapshot: fixture.snapshot)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            try await settle(hosting)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)

            // The representable must honor SwiftUI's effective disabled state.
            // Native selector dispatch also remains guarded against activation.
            state.enabled = false
            try await settle(hosting)
            XCTAssertFalse(button.isEnabled)
            XCTAssertFalse(button.isAccessibilityEnabled())
            button.performClick(nil)
            try await settle(hosting)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            XCTAssertFalse(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)

            state.enabled = true
            try await settle(hosting)
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: true, in: window, native: button, snapshot: fixture.snapshot)
            state.enabled = false
            try await settle(hosting)
            XCTAssertFalse(button.isEnabled)
            XCTAssertFalse(button.isAccessibilityEnabled())
            button.performClick(nil)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            XCTAssertFalse(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: true, in: window, native: button, snapshot: fixture.snapshot)
            state.enabled = true
            try await settle(hosting)
            XCTAssertTrue(try axButton(in: window).press())
            try await settle(hosting)
            try assertState(expanded: false, in: window, native: button, snapshot: fixture.snapshot)
            XCTAssertTrue(fixture.store.sessions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path), "Disclosure interaction must not save the workspace")
        }
    }

    private final class HostState: ObservableObject {
        @Published var enabled = true
    }
    private struct StorageHarness: View {
        let snapshot: MonitoringSnapshot
        @ObservedObject var state: HostState
        var body: some View {
            ScrollView { MonitoringStorageView(snapshot: snapshot).padding(22) }
                .background(Palette.background).foregroundStyle(Palette.text).disabled(!state.enabled)
        }
    }
    private func makeFixture() throws -> (directory: URL, store: AppStore, snapshot: MonitoringSnapshot) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-disclosure-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: native.appendingPathComponent("scripts/fixtures/monitoring-linux.txt"), encoding: .utf8)
        var snapshot = try MonitoringSampleParser.parse(raw: raw, previous: nil, timestamp: Date(timeIntervalSince1970: 1_791_032_400))
        snapshot.disks = [disk("/", "ext4"), disk("/run/user/0", "tmpfs"), disk("/opt/docker/rootfs/overlayfs/disclosure-fixture", "overlay")]
        snapshot.diskIO = []
        return (directory, store, snapshot)
    }
    private func disk(_ path: String, _ filesystem: String) -> MonitoringDisk {
        MonitoringDisk(device: "/dev/disclosure-fixture", mountpoint: path, filesystem: filesystem,
                       totalBytes: 100_000, usedBytes: 40_000, availableBytes: 60_000, usedPercent: 40)
    }
    private func disclosure(in root: NSView) throws -> MonitoringDisclosureNativeButton {
        try XCTUnwrap(find(MonitoringDisclosureNativeButton.self, in: root).first { $0.identifier?.rawValue == "axon-system-mounts" })
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
    private func rowPoints(_ button: NSButton) -> [(String, NSPoint)] {
        [
            ("chevron", NSPoint(x: 16, y: 16)),
            ("label", NSPoint(x: 44, y: 16)),
            ("blank space", NSPoint(x: button.bounds.width - 30, y: 16)),
            ("top left corner", NSPoint(x: 0.25, y: 0.25)),
            ("top right corner", NSPoint(x: button.bounds.width - 0.25, y: 0.25)),
            ("bottom left corner", NSPoint(x: 0.25, y: button.bounds.height - 0.25)),
            ("bottom right corner", NSPoint(x: button.bounds.width - 0.25, y: button.bounds.height - 0.25))
        ]
    }
    private func activateWindowHit(_ button: NSButton, point: NSPoint, region: String) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)), region)
        XCTAssertTrue(hit === button, "The full window must route the \(region) to the native disclosure button")
        // AppKit's mouse tracking reads hardware pressed state. Activate the
        // exact real-window hit control through its native target/action path.
        try XCTUnwrap(hit as? NSButton).performClick(nil)
    }
    private func assertState(expanded: Bool, in window: NSWindow, native: MonitoringDisclosureNativeButton,
                             snapshot: MonitoringSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let elements = axNodes(window)
        let header = try axButton(in: window)
        XCTAssertTrue(header.element === native, "The AX tree must contain the explicit native button", file: file, line: line)
        XCTAssertEqual(header.role, .button, file: file, line: line)
        XCTAssertEqual(header.text, "System and container mounts (2)", file: file, line: line)
        XCTAssertTrue((header.read("accessibilityChildren") as? [Any] ?? []).isEmpty, "Header drawing must not create extra AX children", file: file, line: line)
        XCTAssertEqual(header.read("isAccessibilityExpanded") as? Bool, expanded, file: file, line: line)
        XCTAssertEqual(header.read("accessibilityValue") as? String, expanded ? "Expanded" : "Collapsed", file: file, line: line)
        XCTAssertEqual(header.read("isAccessibilityEnabled") as? Bool, native.isEnabled, file: file, line: line)
        XCTAssertEqual(native.expanded, expanded, file: file, line: line)
        XCTAssertEqual(native.isAccessibilityEnabled(), native.isEnabled, file: file, line: line)
        XCTAssertTrue(elements.contains { $0.role == .staticText && $0.text == "/" }, "Data volumes stay visible", file: file, line: line)
        for disk in MonitoringStoragePresentation.volumes(snapshot.disks, system: true) {
            XCTAssertEqual(elements.contains { $0.role == .staticText && $0.text == disk.mountpoint }, expanded,
                           "Actual card for \(disk.mountpoint) must follow expansion", file: file, line: line)
        }
        XCTAssertTrue(elements.contains { $0.text == "Disk I/O" }, "The following storage section stays available", file: file, line: line)
    }
    private struct AXNode {
        let element: NSObject
        func read(_ key: String) -> Any? { element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil }
        var identifier: String? { read("accessibilityIdentifier") as? String }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var text: String { [read("accessibilityLabel") as? String, read("accessibilityTitle") as? String, read("accessibilityValue") as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard element.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector)
        }
    }
    private func axButton(in window: NSWindow) throws -> AXNode {
        let matches = axNodes(window).filter { $0.identifier == "axon-system-mounts" && $0.role == .button }
        XCTAssertEqual(matches.count, 1, "The real AX hierarchy must expose exactly one disclosure button")
        return try XCTUnwrap(matches.first)
    }
    private func axNodes(_ root: NSObject) -> [AXNode] {
        var result: [AXNode] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = AXNode(element: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        // No NSView subview fallback: this checks the exported AX hierarchy.
        visit(root, depth: 0); return result
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key); NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, width: CGFloat) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
}
