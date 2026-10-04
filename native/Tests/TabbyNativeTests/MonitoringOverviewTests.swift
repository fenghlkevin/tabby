import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class MonitoringOverviewTests: XCTestCase {
    func testDirectLoginUsesSavedGroupSharedIdentityAndCompleteJumpRoute() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var identity = VaultCredential(); identity.name = "Group key"; identity.username = "deploy"; identity.auth = "key"; identity.keySource = "text"
        var gateway = TabbyNative.Host(); gateway.address = "gateway.invalid"; gateway.username = "gateway"; gateway.port = 2200
        var group = HostGroup(); group.name = "Production"; group.port = 2222; group.credentialID = identity.id; group.jumpHostID = gateway.id
        var host = TabbyNative.Host(); host.name = "Application server"; host.address = "server.invalid"; host.group = group.name; host.groupInheritance = .all
        host.username = "unused"; host.port = 1
        store.workspace.credentials = [identity]; store.workspace.groupDefaults = [group]; store.workspace.hosts = [host, gateway]
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        XCTAssertEqual(target.username, "deploy"); XCTAssertEqual(target.port, 2222)
        XCTAssertEqual(target.route, [MonitoringRouteHop(address: gateway.address, port: 2200, username: "gateway")])
        XCTAssertTrue(store.openMonitoringTerminal(target))
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.host, host, "Preserve the raw profile and its group secret owner")
        XCTAssertEqual(session.authenticatedUsername, "deploy"); XCTAssertEqual(session.authenticatedPort, 2222)
        XCTAssertEqual(GroupDefaults.secretID(for: try XCTUnwrap(session.host), workspace: store.workspace), identity.id)
        XCTAssertEqual(store.activeSession, session.id); XCTAssertEqual(store.section, "terminal")
        XCTAssertNil(session.client); XCTAssertNil(session.terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "No metadata flattening or new credential persistence")
        XCTAssertTrue(store.openMonitoringTerminal(target))
        XCTAssertEqual(store.sessions.count, 1, "Repeated explicit clicks reuse the same pending terminal")
    }

    func testDifferentLoginOrJumpRouteCannotReusePendingTerminal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var gateway = TabbyNative.Host(); gateway.address = "jump.invalid"; gateway.username = "gateway"
        var first = TabbyNative.Host(); first.address = "same.invalid"; first.username = "first"
        var second = first; second.id = UUID(); second.username = "second"
        var routed = second; routed.id = UUID(); routed.jumpHostID = gateway.id
        store.workspace.hosts = [first, second, routed, gateway]
        for host in [first, second, routed] {
            XCTAssertTrue(store.openMonitoringTerminal(MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)))
            XCTAssertEqual(store.sessions.last?.host?.id, host.id)
        }
        XCTAssertEqual(store.sessions.count, 3)
        let unavailable = MonitoringTargetID(address: second.address, port: 23, username: second.username)
        XCTAssertFalse(store.openMonitoringTerminal(unavailable))
        XCTAssertEqual(store.sessions.count, 3, "A display address cannot fabricate a new credential profile")
    }

    func testFailedQuickKeySessionReconnectsWithItsOriginalAuthenticationSource() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "quick.invalid"; host.username = "qa"; host.auth = "key"; host.keySource = "text"
        let failed = TerminalSession(host: host, store: store); failed.terminal = TerminalView(frame: .zero)
        store.sessions = [failed]
        let target = try XCTUnwrap(store.monitoring.targetID(for: failed))
        XCTAssertTrue(store.openMonitoringTerminal(target))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.last?.host, host)
        XCTAssertEqual(store.sessions.last?.host?.auth, "key")
        XCTAssertEqual(store.sessions.last?.host?.keySource, "text")
        XCTAssertNotEqual(store.activeSession, failed.id)
        XCTAssertNil(store.sessions.last?.client)
    }

    func testLoopbackLiveTerminalIsReusedAfterSavedSettingsChangeAndStaleClientIsReconnected() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "127.0.0.1"; host.username = "test"; host.port = info["port"] as! Int
        host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.hosts = [host]; store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        XCTAssertTrue(store.openMonitoringTerminal(target))
        let session = try XCTUnwrap(store.sessions.first)
        defer { for item in store.sessions { item.disconnect() }; store.monitoring.stop() }
        _ = session.makeView()
        for _ in 0..<200 where !session.connected { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(session.connected, session.status)
        XCTAssertTrue(session.client?.isConnected == true)
        let client = try XCTUnwrap(session.client)
        store.workspace.hosts[0].port = host.port == 1 ? 2 : 1
        store.section = "monitoring"; store.activeSession = nil
        XCTAssertTrue(store.openMonitoringTerminal(target))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.activeSession, session.id)
        XCTAssertTrue(session.client === client, "Focus the authenticated endpoint from the monitor card, not edited vault metadata")

        store.workspace.hosts[0] = host
        session.disconnect(); session.connected = true
        XCTAssertTrue(store.openMonitoringTerminal(target))
        XCTAssertEqual(store.sessions.count, 2, "A stale connected flag without a live SSH client is not reusable")
        XCTAssertEqual(store.sessions.last?.host?.id, host.id)
        XCTAssertNil(store.sessions.last?.terminal)
    }

    func testNativeOverviewAndDetailLoginButtonsAreSeparateAndListLayoutCanSwitch() async throws {
        _ = NSApplication.shared
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        var host = TabbyNative.Host(); host.name = "Monitoring login fixture"; host.address = "127.0.0.1"; host.username = "test"
        host.port = try XCTUnwrap(info["port"] as? Int); host.auth = "key"; host.keyPath = try XCTUnwrap(info["clientKey"] as? String)
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = try XCTUnwrap(info["hostKey"] as? String)
        store.workspace.hosts = [host]; store.section = "monitoring"
        let center = store.monitoring; center.configure(store: store, terminalStatusVisible: false, foreground: false)
        defer { center.stop(); for session in store.sessions { session.disconnect() } }
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        try await withWindow(MonitoringVaultView(center: center).environmentObject(store).preferredColorScheme(.light), size: NSSize(width: 650, height: 700)) { hosting in
            XCTAssertTrue(store.sessions.isEmpty)
            let picker = try XCTUnwrap(find(NSSegmentedControl.self, in: hosting).first)
            XCTAssertEqual(picker.selectedSegment, 0)
            let cardButton = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            try assertButtonGeometry(cardButton, in: hosting)
            try capture(hosting, name: "monitor-login-card")
            cardButton.performClick(nil)
            XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.sessions.first?.host?.id, host.id)
            XCTAssertNil(store.activeSession); XCTAssertEqual(store.section, "monitoring")
            XCTAssertNil(center.selectedTargetID, "The sibling login action must not also open monitoring details")
            let session = try XCTUnwrap(store.sessions.first)
            XCTAssertNotNil(session.terminal); XCTAssertNotNil(session.task)
            for _ in 0..<300 where !session.connected { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(session.connected, session.status)
            XCTAssertEqual(store.section, "monitoring"); XCTAssertNil(store.activeSession)

            picker.selectedSegment = 1; picker.sendAction(picker.action, to: picker.target)
            try await settle(hosting)
            XCTAssertEqual(picker.selectedSegment, 1)
            XCTAssertEqual(picker.accessibilityValue() as? String, "List view")
            let rowButton = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            try assertButtonGeometry(rowButton, in: hosting)
            try capture(hosting, name: "monitor-login-list")
            XCTAssertFalse(rowButton.prominent, "A live row exposes an explicit open-terminal action")
            rowButton.performClick(nil)
            XCTAssertEqual(store.sessions.count, 1, "Open terminal reuses the authenticated connection")
            XCTAssertEqual(store.activeSession, session.id); XCTAssertEqual(store.section, "terminal")

            store.section = "monitoring"; store.close(session.id)
            center.select(target); try await settle(hosting)
            XCTAssertEqual(center.selectedTargetID, target)
            XCTAssertTrue(store.sessions.isEmpty, "Selecting details must not connect")
            let detailButton = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            try assertButtonGeometry(detailButton, in: hosting)
            try capture(hosting, name: "monitor-detail-login")
            detailButton.performClick(nil)
            XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.sessions.first?.host?.id, host.id)
            XCTAssertNil(store.activeSession); XCTAssertEqual(store.section, "monitoring")
            XCTAssertEqual(center.selectedTargetID, target)
            let detailSession = try XCTUnwrap(store.sessions.first)
            XCTAssertNotNil(detailSession.terminal); XCTAssertNotNil(detailSession.task)
            for _ in 0..<300 where !detailSession.connected { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(detailSession.connected, detailSession.status)
            try await settle(hosting)
            let openTerminal = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
            XCTAssertFalse(openTerminal.prominent)
            openTerminal.performClick(nil)
            XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.activeSession, detailSession.id)
            XCTAssertEqual(store.section, "terminal"); XCTAssertEqual(center.selectedTargetID, target)
        }
    }

    func testConnectedAndDisconnectedCardsKeepIdenticalHeightWithLongNames() async throws {
        _ = NSApplication.shared
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = native.appendingPathComponent("scripts/fixtures")
        let date = Date(timeIntervalSince1970: 1_791_032_400)
        let baseline = try MonitoringSampleParser.parse(raw: String(contentsOf: fixtures.appendingPathComponent("monitoring-linux-16cores.txt"), encoding: .utf8), previous: nil, timestamp: date.addingTimeInterval(-5))
        let snapshot = try MonitoringSampleParser.parse(raw: String(contentsOf: fixtures.appendingPathComponent("monitoring-linux-16cores-next.txt"), encoding: .utf8), previous: baseline, timestamp: date)
        let id = MonitoringTargetID(address: "long-label.invalid", port: 22, username: "qa")
        let online = MonitoringEntry(id: id, label: "A very long server label that must wrap and stay within its own card", address: id.address, group: "Production", isConnected: true)
        let offline = MonitoringEntry(id: MonitoringTargetID(address: "offline.invalid", port: 22, username: "qa"), label: "Offline", address: "offline.invalid", group: "Production", isConnected: false)
        let geometry = CardGeometryRecorder()
        let content = HStack(alignment: .top, spacing: 14) {
            MonitoringHostCard(entry: online, snapshot: snapshot, state: "Collecting", select: {}, connect: {}, canConnect: true)
                .background(GeometryReader { proxy in Color.clear.preference(key: CardGeometryPreference.self, value: ["online": proxy.size]) })
            MonitoringHostCard(entry: offline, snapshot: nil, state: "Not connected", select: {}, connect: {}, canConnect: true)
                .background(GeometryReader { proxy in Color.clear.preference(key: CardGeometryPreference.self, value: ["offline": proxy.size]) })
        }.padding(14).onPreferenceChange(CardGeometryPreference.self) { geometry.sizes = $0 }
            .environmentObject(store).preferredColorScheme(.light)
        try await withWindow(content, size: NSSize(width: 650, height: MonitoringHostCard.height + 28)) { hosting in
            let controls = find(MonitoringTerminalNativeButton.self, in: hosting)
            XCTAssertEqual(controls.count, 2)
            let frames = controls.map { $0.convert($0.bounds, to: hosting) }
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1, "Connected metrics cannot stretch the card/footer")
            for button in controls { try assertButtonGeometry(button, in: hosting) }
            // sizingOptions=[] intentionally disables NSHostingView's intrinsic
            // fittingSize. Measure the rendered SwiftUI cards themselves.
            for name in ["online", "offline"] {
                let size = try XCTUnwrap(geometry.sizes[name])
                XCTAssertEqual(size.height, MonitoringHostCard.height, accuracy: 1)
                XCTAssertGreaterThan(size.width, 280)
            }
            XCTAssertEqual(hosting.bounds.height, MonitoringHostCard.height + 28, accuracy: 1)
            try capture(hosting, name: "monitor-equal-card-height")
        }
    }

    private final class CardGeometryRecorder { var sizes: [String: CGSize] = [:] }
    private struct CardGeometryPreference: PreferenceKey {
        static var defaultValue: [String: CGSize] { [:] }
        static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-overview-" + UUID().uuidString) }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func assertButtonGeometry(_ button: MonitoringTerminalNativeButton, in hosting: NSView) throws {
        let rect = button.convert(button.bounds, to: hosting)
        XCTAssertEqual(rect.width, MonitoringTerminalNativeButton.width, accuracy: 1); XCTAssertEqual(rect.height, MonitoringTerminalNativeButton.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, hosting.bounds.width + 1)
        for corner in [NSPoint(x: 1, y: 1), NSPoint(x: button.bounds.width - 1, y: button.bounds.height - 1)] {
            XCTAssertTrue(button.hitTest(button.convert(corner, to: button.superview)) === button, "Button corners must belong to its own action region")
        }
    }
    private func withWindow<Content: View>(_ content: Content, size: NSSize, action: (NSHostingView<Content>) async throws -> Void) async throws {
        let hosting = NSHostingView(rootView: content); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await settle(hosting); try await action(hosting)
    }
    private func settle(_ hosting: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded() }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
