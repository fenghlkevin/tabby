import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

/// Exercises the actual SwiftUI accessibility tree and native scroll geometry.
/// The executor returns repository fixtures; it never opens SSH, reads secrets,
/// starts a terminal process, or loads the user's workspace. PNGs are artifacts
/// for visual review, not pixel-golden assertions. Set AXON_UI_CAPTURE_DIR to
/// choose their destination (otherwise /tmp/axon-monitor-layout is used).
@MainActor final class MonitoringLayoutTests: XCTestCase {
    func testVaultOverviewAndEveryDetailModuleFitNarrowAndWideWindows() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let fixture = try await makeFixture()
        defer { fixture.center.stop(); try? FileManager.default.removeItem(at: fixture.directory) }

        for width: CGFloat in [650, 1100] {
            fixture.center.select(nil)
            let hosting = NSHostingView(rootView: MonitoringVaultView(center: fixture.center)
                .environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 900))
            defer { window.close() }
            try await settle(hosting)

            try assertText("Monitoring", in: hosting)
            let group = try XCTUnwrap(nativeViews(MonitoringGroupNativeButton.self, in: hosting).first { $0.title == "Synthetic QA" })
            group.performClick(nil)
            try await settle(hosting)
            let offlineLabel = "Monitoring details for Offline fixture"
            let onlineLabel = "Monitoring details for Connected fixture"
            try assertText(offlineLabel, in: hosting)
            try assertText(onlineLabel, in: hosting)
            try auditAndCapture(hosting, named: "monitor-overview-\(Int(width))")

            // A saved, disconnected card must reveal the explanation rather
            // than inventing a connection or showing the connected host's data.
            try press(offlineLabel, in: hosting)
            try await settle(hosting)
            XCTAssertEqual(fixture.center.selectedTargetID, fixture.offlineID)
            try assertText("SSH is not connected", in: hosting)
            XCTAssertEqual(fixture.store.sessions.count, 1)
            XCTAssertNil(fixture.store.sessions.first?.client)
            try press("Monitoring overview", in: hosting)
            try await settle(hosting)
            try press(onlineLabel, in: hosting)
            try await settle(hosting)
            XCTAssertEqual(fixture.center.selectedTargetID, fixture.connectedID)

            let pages: [(button: String?, required: String, file: String)] = [
                (nil, "Usage", "resources"),
                ("Processes", "sampled processes", "processes"),
                ("Network & IP", "Network interface", "network"),
                ("GPU", "Driver CUDA support", "gpu"),
                ("Docker", "sampled containers", "docker"),
            ]
            for page in pages {
                if let button = page.button { try press(button, in: hosting); try await settle(hosting) }
                try assertText(page.required, in: hosting)
                try auditAndCapture(hosting, named: "monitor-\(page.file)-\(Int(width))")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path),
                           "Browsing monitoring must not persist or create connections")
        }
    }

    func testTerminalStatusAt320PointsKeepsMetricsAndPausedRefreshWithinBounds() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let fixture = try await makeFixture()
        defer { fixture.center.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let session = try XCTUnwrap(fixture.store.sessions.first)
        let hosting = NSHostingView(rootView: MonitoringTerminalPanel(center: fixture.center, sessionID: session.id)
            .padding(14).background(Color(hex: "#1e1f29")).foregroundStyle(Color(hex: "#E7E9F0"))
            .environmentObject(fixture.store).preferredColorScheme(.dark))
        let window = show(hosting, size: NSSize(width: 320, height: 900))
        defer { window.close() }
        try await settle(hosting)
        try assertText("Host status", in: hosting)
        try assertText("CPU", in: hosting)
        try assertText("Memory", in: hosting)
        try assertText("View details", in: hosting)
        try auditAndCapture(hosting, named: "monitor-terminal-320")

        fixture.center.stop()
        try await settle(hosting)
        try assertText("Sampling paused", in: hosting)
        try assertText("Last successful sample", in: hosting)
        let refresh = try button("Refresh status", in: hosting)
        XCTAssertFalse(refresh.enabled, "Paused monitoring must not present a working refresh action")
        try auditAndCapture(hosting, named: "monitor-terminal-paused-320")
        try press("View details", in: hosting)
        XCTAssertEqual(fixture.store.section, "monitoring")
        XCTAssertEqual(fixture.center.selectedTargetID, fixture.connectedID)
        XCTAssertNil(session.client)
    }

    private struct Fixture {
        let directory: URL
        let store: AppStore
        let center: MonitoringCenter
        let connectedID: MonitoringTargetID
        let offlineID: MonitoringTargetID
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-ui-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        var host = TabbyNative.Host(); host.name = "Connected fixture"; host.address = "monitor-fixture.invalid"; host.username = "qa"
        var offline = TabbyNative.Host(); offline.name = "Offline fixture"; offline.address = "offline-fixture.invalid"; offline.username = "qa"
        store.workspace.hosts = [host, offline]
        let session = TerminalSession(host: host, store: store)
        // Metadata only: do not call makeView/reconnect, which would start SSH.
        session.connected = true
        store.sessions = [session]; store.activeSession = session.id
        let id = MonitoringTargetID(address: host.address, port: host.port, username: host.username)
        let offlineID = MonitoringTargetID(address: offline.address, port: offline.port, username: offline.username)
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = native.appendingPathComponent("scripts/fixtures")
        let first = try String(contentsOf: fixtures.appendingPathComponent("monitoring-linux-16cores.txt"), encoding: .utf8)
        let next = try String(contentsOf: fixtures.appendingPathComponent("monitoring-linux-16cores-next.txt"), encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_791_032_400)
        let baseline = try MonitoringSampleParser.parse(raw: first, previous: nil, timestamp: date.addingTimeInterval(-5))
        let center = MonitoringCenter(interval: .seconds(3600), parser: { raw, _, _ in
            try MonitoringSampleParser.parse(raw: raw, previous: baseline, timestamp: date)
        })
        let source = MonitoringSource(id: id, connectionToken: "layout-fixture", hostID: host.id,
                                      label: host.name, group: "Synthetic QA", execute: { command, maximum in
            guard command == MonitoringCommand.script, next.utf8.count <= maximum else {
                throw AppFailure.message("Unexpected fixture collection request")
            }
            return next
        })
        center.configure(sources: [source], entries: [
            MonitoringEntry(id: offlineID, label: offline.name, address: offline.address, group: "Synthetic QA", isConnected: false),
        ], demand: .overview, foreground: true)
        for _ in 0..<100 where center.snapshots[id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(center.snapshots[id], "The injected fixture should be collected without any SSH client")
        XCTAssertEqual(center.entries.count, 2)
        XCTAssertNil(session.client)
        return Fixture(directory: directory, store: store, center: center, connectedID: id, offlineID: offlineID)
    }

    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        return window
    }

    private func enableAccessibility() -> () -> Void {
        // Public AppKit accessibility attribute APIs initialize SwiftUI's lazy
        // AX tree in this test process. Only set an attribute the application
        // reports; restore its previous value when the test ends. These legacy
        // APIs remain public, though newer protocol getters are preferred for
        // reading elements after the tree has been initialized.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(enhanced) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
    }

    private func settle(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private func nativeViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { nativeViews(type, in: $0) }
    }

    private struct Node {
        // SwiftUI's virtual accessibility nodes implement the Objective-C
        // accessibility selectors without declaring NSAccessibilityProtocol
        // conformance. A protocol cast silently drops that entire subtree.
        let element: NSObject
        func read(_ key: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(key)) else { return nil }
            return element.value(forKey: key)
        }
        var label: String? { read("accessibilityLabel") as? String }
        var title: String? { read("accessibilityTitle") as? String }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var enabled: Bool {
            guard element.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
            return element.value(forKey: "accessibilityEnabled") as? Bool ?? false
        }
        var text: String {
            [label, title, read("accessibilityValue") as? String]
                .compactMap { $0 }.joined(separator: " · ")
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard element.responds(to: selector) else { return false }
            // NSObject.perform assumes an object return; NSAccessibility's
            // official press selector returns BOOL, so call its typed IMP.
            typealias PerformPress = @convention(c) (AnyObject, Selector) -> Bool
            let implementation = unsafeBitCast(element.method(for: selector), to: PerformPress.self)
            return implementation(element, selector)
        }
    }

    private func nodes(in root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 50, let element = object as? NSObject else { return }
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            let node = Node(element: element)
            result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            // Native scroll/search views may be ignored containers; reach their
            // SwiftUI descendants without depending on private class names.
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return result
    }

    private func assertText(_ text: String, in root: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let available = nodes(in: root).map(\.text).filter { !$0.isEmpty }
        guard available.contains(where: { $0.localizedCaseInsensitiveContains(text) }) else {
            XCTFail("Missing accessible content '\(text)'. Found: \(available.joined(separator: " | "))", file: file, line: line)
            throw AppFailure.message("Missing monitoring content: " + text)
        }
    }

    private func button(_ title: String, in root: NSView) throws -> Node {
        try XCTUnwrap(nodes(in: root).first { node in
            node.role == .button && [node.label, node.title].compactMap { $0 }.contains(title)
        }, "Missing accessible button '\(title)'")
    }

    private func press(_ title: String, in root: NSView) throws {
        let found = try button(title, in: root)
        guard found.press() else {
            XCTFail("Button '\(title)' rejected accessibility activation")
            throw AppFailure.message("Monitoring button rejected activation: " + title)
        }
    }

    private func auditAndCapture(_ hosting: NSView, named name: String) throws {
        let window = try XCTUnwrap(hosting.window)
        let viewport = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        let content = nodes(in: hosting)
        let leaves: Set<NSAccessibility.Role> = [.staticText, .button, .textField, .popUpButton]
        var visibleCount = 0
        for node in content where node.role.map(leaves.contains) == true {
            let frame = node.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(viewport) else { continue }
            visibleCount += 1
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, "\(name): '\(node.text)' overflows left")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, "\(name): '\(node.text)' overflows right")
        }
        XCTAssertGreaterThan(visibleCount, 5, "Layout audit needs actual visible content, not an empty hosting view")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        for scroll in scrollViews(hosting) {
            if let document = scroll.documentView {
                XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                         "\(name): scroll document creates horizontal overflow")
            }
        }
        let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        let report = content.map { "\(NSStringFromClass(type(of: $0.element)))\t\($0.role?.rawValue ?? "?")\t\($0.frame)\t\($0.text)" }.joined(separator: "\n")
        try report.write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
}
