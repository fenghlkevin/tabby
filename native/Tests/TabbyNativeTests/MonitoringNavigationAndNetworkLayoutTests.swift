import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class MonitoringNavigationAndNetworkLayoutTests: XCTestCase {
    func testEveryModuleWholeRectangleActivatesActualDetailContentAtNarrowAndWideWidths() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try await makeFixture(); defer { fixture.center.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        for width: CGFloat in [650, 1100] {
            fixture.center.select(fixture.entry.id)
            let hosting = NSHostingView(rootView: MonitoringVaultView(center: fixture.center).environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 900)); defer { window.close() }
            try await settle(hosting)
            let pages: [(MonitoringModule, String)] = [(.resources, "Usage"), (.processes, "sampled processes"), (.network, "Network interfaces"), (.gpu, "Driver CUDA support"), (.docker, "sampled containers")]
            for (module, expected) in pages {
                let button = try XCTUnwrap(find(MonitoringModuleNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "monitoring-module-" + module.rawValue })
                XCTAssertEqual(button.bounds.height, 38, accuracy: 0.5)
                let points = [NSPoint(x: 2, y: 2), NSPoint(x: button.bounds.width - 2, y: 2), NSPoint(x: 2, y: button.bounds.height - 2), NSPoint(x: button.bounds.width - 2, y: button.bounds.height - 2), NSPoint(x: 21, y: 19), NSPoint(x: 47, y: 19)]
                for point in points {
                    try activateAtPoint(button, point: point)
                    try await settle(hosting)
                    XCTAssertTrue(button.selected, "The hit native tab must become selected")
                    XCTAssertEqual(find(MonitoringModuleNativeButton.self, in: hosting).filter(\.selected).count, 1)
                    XCTAssertTrue(nodes(hosting).contains { $0.text.contains(expected) }, "\(module) must switch the actual detail body")
                }
                try captureAndAudit(hosting, name: "monitor-module-\(module.rawValue)-\(Int(width))")
            }
            XCTAssertTrue(fixture.store.sessions.isEmpty, "Module navigation must not initialize a terminal or SSH client")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        }
    }

    func testInterfaceRowsShareHeightAndKeepEveryAddressReadable() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try await makeFixture(); defer { fixture.center.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        var snapshot = fixture.snapshot
        snapshot.trafficHistory = nil
        snapshot.interfaces = [
            interface("bridge0", "DOWN", ["172.18.0.1/16"]),
            interface("docker0", "UP", ["172.17.0.1/16", "fe80::c882:b4ff:fe0b:a9d2/64"]),
            interface("eth0", "UP", ["172.26.148.202/20", "2001:db8:1234:5678:90ab:cdef:1234:5678/64", "fe80::f816:3eff:fec5:3f75/64"]),
            interface("lo", "UNKNOWN", ["127.0.0.1/8", "::1/128"]),
            interface("veth0", "DOWN", [])
        ]
        for width: CGFloat in [650, 1100] {
            let hosting = NSHostingView(rootView: ScrollView { MonitoringNetworkView(snapshot: snapshot, entry: fixture.entry).padding(22) }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 1500)); defer { window.close() }
            try await settle(hosting)
            let content = nodes(hosting)
            let cards = try snapshot.interfaces.map { interface in
                try XCTUnwrap(content.first { $0.identifier == "axon-interface-" + interface.name && $0.frame.width > 100 }, "Missing card frame for \(interface.name)")
            }
            for card in cards {
                let siblings = cards.filter { abs($0.frame.maxY - card.frame.maxY) < 1 }
                for sibling in siblings {
                    XCTAssertEqual(sibling.frame.height, card.frame.height, accuracy: 1, "Same-row card surfaces must have equal height")
                    XCTAssertEqual(sibling.frame.minY, card.frame.minY, accuracy: 1, "Same-row card bottom edges must align")
                }
            }
            XCTAssertTrue(cards.contains { card in cards.filter { abs($0.frame.maxY - card.frame.maxY) < 1 }.count > 1 }, "Adaptive layout should use multiple columns at \(width) points")
            for interface in snapshot.interfaces {
                let card = try XCTUnwrap(cards.first { $0.identifier == "axon-interface-" + interface.name })
                for address in interface.addresses {
                    let text = try XCTUnwrap(content.first { $0.role == .staticText && $0.text == address }, "Missing full address \(address)")
                    XCTAssertGreaterThan(text.frame.height, 0)
                    XCTAssertGreaterThanOrEqual(text.frame.minX, card.frame.minX - 1)
                    XCTAssertLessThanOrEqual(text.frame.maxX, card.frame.maxX + 1)
                    XCTAssertGreaterThanOrEqual(text.frame.minY, card.frame.minY - 1)
                    XCTAssertLessThanOrEqual(text.frame.maxY, card.frame.maxY + 1)
                }
            }
            XCTAssertFalse(content.contains { $0.role == .popUpButton }, "Every NIC remains simultaneously visible")
            try captureAndAudit(hosting, name: "monitor-interface-equal-rows-\(Int(width))")
        }
    }

    private struct Fixture {
        let directory: URL
        let store: AppStore
        let center: MonitoringCenter
        let entry: MonitoringEntry
        let snapshot: MonitoringSnapshot
    }
    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-navigation-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: native.appendingPathComponent("scripts/fixtures/monitoring-linux.txt"), encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_791_032_400)
        let snapshot = try MonitoringSampleParser.parse(raw: raw, previous: nil, timestamp: date)
        let id = MonitoringTargetID(address: "fixture.invalid", port: 22, username: "qa")
        let entry = MonitoringEntry(id: id, label: "Fixture host", address: id.address, group: "", isConnected: true)
        let center = MonitoringCenter(interval: .seconds(3600), parser: { _, _, _ in snapshot })
        center.configure(sources: [MonitoringSource(id: id, connectionToken: "navigation-fixture", label: entry.label, group: "", execute: { _, _ in raw })], entries: [entry], demand: .overview, foreground: true)
        for _ in 0..<100 where center.snapshots[id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(center.snapshots[id]); center.select(id)
        return Fixture(directory: directory, store: store, center: center, entry: entry, snapshot: snapshot)
    }
    private func interface(_ name: String, _ state: String, _ addresses: [String]) -> MonitoringInterface {
        MonitoringInterface(name: name, addresses: addresses, state: state, receivedBytes: 600, transmittedBytes: 700, receiveBytesPerSecond: 80, transmitBytesPerSecond: 90)
    }
    private func activateAtPoint(_ button: NSButton, point: NSPoint) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
        XCTAssertTrue(hit === button, "Window hierarchy must route text, icon and padding to the native button")
        // AppKit mouse tracking uses hardware pressed state. Test that the real
        // hit target receives its native action, without spoofing mouse events.
        try XCTUnwrap(hit as? NSButton).performClick(nil)
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) } }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }
    private func settle(_ view: NSView) async throws { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    private func enableAccessibility() -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(attribute) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
    }
    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var text: String { [read("accessibilityLabel") as? String, read("accessibilityTitle") as? String, read("accessibilityValue") as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        var identifier: String? { read("accessibilityIdentifier") as? String }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result = [Node](), seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    private func captureAndAudit(_ view: NSView, name: String) throws {
        let window = try XCTUnwrap(view.window)
        let viewport = window.convertToScreen(view.convert(view.bounds, to: nil))
        let leafRoles: Set<NSAccessibility.Role> = [.staticText, .button, .checkBox, .popUpButton]
        for node in nodes(view) where node.role.map(leafRoles.contains) == true {
            let frame = node.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(viewport) else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, "\(name): \(node.text) overflows left")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, "\(name): \(node.text) overflows right")
        }
        let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-navigation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        try nodes(view).map { "\($0.identifier ?? "")\t\($0.role?.rawValue ?? "")\t\($0.frame)\t\($0.text)" }.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
}
