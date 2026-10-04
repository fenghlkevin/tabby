import XCTest
import AppKit
import SwiftUI
import SwiftTerm
import Citadel
@testable import TabbyNative

@MainActor final class MonitoringBackgroundConnectionTests: XCTestCase {
    func testBackgroundConnectStartsAndSamplesWithoutSelectingTheNewTerminal() async throws {
        _ = NSApplication.shared
        let (store, host, root) = try fixture()
        defer { cleanup(store, root: root) }
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        store.section = "monitoring"; store.group = "Vault selection"; store.search = "Vault search"
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        store.monitoring.select(target)
        let preferences = store.workspace.preferences
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertNotNil(session.terminal, "Background login must start without presenting a terminal view")
        XCTAssertNotNil(session.task)
        XCTAssertNil(store.activeSession)
        assertMonitoringSelection(store, target: target)
        // These clicks occur before the connection Task has received a turn.
        // Reuse must cover this gap as well as the later authentication phase.
        for _ in 0..<10 { XCTAssertTrue(store.openMonitoringTerminal(target, activate: false)) }
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        try await waitUntil("background SSH and read-only sample") {
            session.connected && store.monitoring.snapshots[target] != nil
        }
        XCTAssertTrue(session.client?.isConnected == true, session.status)
        XCTAssertNotNil(session.writer)
        let snapshot = try XCTUnwrap(store.monitoring.snapshots[target])
        XCTAssertTrue(snapshot.isSupported); XCTAssertNotNil(snapshot.memory); XCTAssertFalse(snapshot.processes.isEmpty)
        assertMonitoringSelection(store, target: target)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.workspace.hosts, [host]); XCTAssertEqual(store.workspace.preferences, preferences)
        let client = try XCTUnwrap(session.client), terminal = try XCTUnwrap(session.terminal)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        XCTAssertEqual(store.sessions.count, 1); XCTAssertNil(store.activeSession)
        XCTAssertTrue(store.openMonitoringTerminal(target), "An explicit open-terminal action retains its foreground behavior")
        XCTAssertEqual(store.section, "terminal"); XCTAssertEqual(store.activeSession, session.id)
        XCTAssertEqual(store.sessions.count, 1); XCTAssertTrue(session.client === client); XCTAssertTrue(session.terminal === terminal)
    }

    func testBackgroundConnectionPreservesExistingFocusAndReusesAuthenticatedIdentityAfterMetadataEdits() async throws {
        _ = NSApplication.shared
        let (store, host, root) = try fixture()
        defer { cleanup(store, root: root) }
        let existing = TerminalSession(host: nil, store: store)
        let surface = TerminalView(frame: .zero); existing.terminal = surface
        store.sessions = [existing]; store.activeSession = existing.id
        store.section = "monitoring"; store.group = "Vault selection"; store.search = "Vault search"
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        let remote = try XCTUnwrap(store.sessions.last)
        XCTAssertNotEqual(remote.id, existing.id)
        XCTAssertEqual(store.activeSession, existing.id); XCTAssertTrue(existing.terminal === surface)
        try await waitUntil("background SSH beside another selected tab") { remote.connected }
        let client = try XCTUnwrap(remote.client)
        store.workspace.hosts[0].port = host.port == 1 ? 2 : 1
        store.workspace.hosts[0].username = "edited-login"
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false), "The live card keeps its authenticated endpoint")
        XCTAssertEqual(store.sessions.map(\.id), [existing.id, remote.id])
        XCTAssertTrue(remote.client === client); XCTAssertEqual(store.activeSession, existing.id)
        XCTAssertEqual(store.section, "monitoring"); XCTAssertEqual(store.group, "Vault selection"); XCTAssertEqual(store.search, "Vault search")
        let wrongLogin = MonitoringTargetID(address: target.address, port: target.port, username: "unrelated-login")
        XCTAssertFalse(store.openMonitoringTerminal(wrongLogin, activate: false), "Display IP alone must not select an unrelated identity")
        XCTAssertEqual(store.sessions.count, 2); XCTAssertEqual(store.activeSession, existing.id)
        let wrongRoute = MonitoringTargetID(address: target.address, port: target.port, username: target.username,
                                            route: [MonitoringRouteHop(address: "127.0.0.1", port: target.port, username: "gateway")])
        XCTAssertFalse(store.openMonitoringTerminal(wrongRoute, activate: false))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.openMonitoringTerminal(target))
        XCTAssertEqual(store.activeSession, remote.id); XCTAssertEqual(store.section, "terminal")
        XCTAssertTrue(remote.client === client); XCTAssertTrue(existing.terminal === surface)
    }

    func testBackgroundStartReusesPendingForegroundTabButRejectsStaleMetadata() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-pending-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        defer { cleanup(store, root: root) }
        var host = TabbyNative.Host(); host.name = "Pending identity"; host.address = "127.0.0.1"
        host.username = "test"; host.auth = "key"; host.keyPath = root.appendingPathComponent("unused-key").path
        store.workspace.hosts = [host]
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        XCTAssertTrue(store.openMonitoringTerminal(target))
        let pending = try XCTUnwrap(store.sessions.first)
        XCTAssertNil(pending.terminal); XCTAssertNil(pending.task)
        store.section = "monitoring"
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        XCTAssertEqual(store.sessions.map(\.id), [pending.id]); XCTAssertNotNil(pending.terminal); XCTAssertNotNil(pending.task)
        XCTAssertEqual(store.activeSession, pending.id); XCTAssertEqual(store.section, "monitoring")
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        XCTAssertEqual(store.sessions.count, 1, "An initialized view before Task execution is still pending")
        // Cancel synchronously before yielding: no key access or network is needed
        // to exercise the immutable identity versus edited saved metadata guard.
        pending.disconnect()
        store.workspace.hosts[0].username = "edited-login"; store.workspace.hosts[0].port = 2200
        XCTAssertFalse(store.openMonitoringTerminal(target, activate: false))
        XCTAssertEqual(store.sessions.count, 1)
        let updated = MonitoringTerminalAction.savedTargetID(for: store.workspace.hosts[0], workspace: store.workspace)
        XCTAssertTrue(store.openMonitoringTerminal(updated))
        XCTAssertEqual(store.sessions.count, 2); XCTAssertEqual(store.sessions.last?.authenticatedUsername, "edited-login")
        XCTAssertEqual(store.sessions.last?.authenticatedPort, 2200)
        XCTAssertNil(store.sessions.last?.terminal, "Foreground initialization remains lazy")
    }

    func testFailedBackgroundConnectionCanRetryWithoutReusingTheFailedTaskOrChangingSelection() throws {
        _ = NSApplication.shared
        let (store, host, root) = synchronousFixture()
        defer { cleanup(store, root: root) }
        let existing = TerminalSession(host: nil, store: store)
        let surface = TerminalView(frame: .zero); existing.terminal = surface
        store.sessions = [existing]; store.activeSession = existing.id
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: false)
        store.monitoring.select(target)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        let failed = try XCTUnwrap(store.sessions.last)
        XCTAssertNotNil(failed.task); XCTAssertFalse(failed.connectionInProgress); XCTAssertNil(failed.client)
        let request = failed.generation
        // Deliver a synthetic failure before yielding to the scheduled Task.
        // Neither attempt reads a key nor contacts the fixture endpoint.
        failed.connectionEnded(request: request, error: AppFailure.message("Synthetic authentication failure"))
        XCTAssertNil(failed.task); XCTAssertNil(failed.client); XCTAssertNil(failed.writer); XCTAssertFalse(failed.connected)
        XCTAssertEqual(failed.status, "Synthetic authentication failure")
        XCTAssertEqual(store.sessions.map(\.id), [existing.id, failed.id], "Retain the failed tab for its diagnostic")
        XCTAssertEqual(store.activeSession, existing.id); XCTAssertTrue(existing.terminal === surface)
        assertMonitoringSelection(store, target: target)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        let retry = try XCTUnwrap(store.sessions.last)
        XCTAssertNotEqual(retry.id, failed.id); XCTAssertEqual(retry.host, host)
        XCTAssertNotNil(retry.task); XCTAssertNotNil(retry.terminal)
        XCTAssertNil(retry.client); XCTAssertFalse(retry.connectionInProgress)
        XCTAssertEqual(store.activeSession, existing.id); assertMonitoringSelection(store, target: target)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        XCTAssertEqual(store.sessions.map(\.id), [existing.id, failed.id, retry.id], "Repeated retry clicks reuse only the fresh pending attempt")
    }

    func testCancellingBackgroundConnectionRemovesOnlyItsTabAndKeepsMonitoringSelection() throws {
        _ = NSApplication.shared
        let (store, host, root) = synchronousFixture()
        defer { cleanup(store, root: root) }
        let existing = TerminalSession(host: nil, store: store)
        let surface = TerminalView(frame: .zero); existing.terminal = surface
        store.sessions = [existing]; store.activeSession = existing.id
        let target = MonitoringTerminalAction.savedTargetID(for: host, workspace: store.workspace)
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: false)
        store.monitoring.select(target)
        XCTAssertTrue(store.openMonitoringTerminal(target, activate: false))
        let cancelled = try XCTUnwrap(store.sessions.last)
        let request = cancelled.generation
        XCTAssertNotNil(cancelled.task); XCTAssertFalse(cancelled.connectionInProgress); XCTAssertNil(cancelled.client)
        // Synchronous cancellation exercises normal lifecycle cleanup without
        // presenting authentication or yielding to any connection work.
        cancelled.connectionEnded(request: request, error: CancellationError())
        XCTAssertEqual(store.sessions.map(\.id), [existing.id])
        XCTAssertEqual(store.activeSession, existing.id); XCTAssertTrue(existing.terminal === surface)
        XCTAssertNil(cancelled.task); XCTAssertNil(cancelled.client); XCTAssertNil(cancelled.writer); XCTAssertFalse(cancelled.connected)
        XCTAssertNil(store.error); assertMonitoringSelection(store, target: target)
        cancelled.connectionEnded(request: request, error: CancellationError())
        XCTAssertEqual(store.sessions.map(\.id), [existing.id], "Late completion from the cancelled generation is harmless")
        XCTAssertEqual(store.activeSession, existing.id); assertMonitoringSelection(store, target: target)
    }

    func testMainViewCardConnectionPreservesGroupSearchAndOtherTabThenListOpensItExplicitly() async throws {
        _ = NSApplication.shared
        let (store, host, root) = try fixture()
        defer { cleanup(store, root: root) }
        let existing = TerminalSession(host: nil, store: store); existing.terminal = TerminalView(frame: .zero)
        store.sessions = [existing]; store.activeSession = existing.id
        store.section = "monitoring"
        let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light).tint(Palette.accent))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        let group = try XCTUnwrap(find(MonitoringGroupNativeButton.self, in: hosting).first { $0.title == host.group })
        group.performClick(nil); try await settle(hosting)
        let search = try XCTUnwrap(find(NSTextField.self, in: hosting).first { $0.placeholderString == "Search hosts, addresses or groups" })
        search.stringValue = "Background"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await settle(hosting)
        let connect = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
        XCTAssertTrue(connect.prominent)
        connect.performClick(nil)
        connect.performClick(nil)
        XCTAssertEqual(store.sessions.count, 2); XCTAssertEqual(store.activeSession, existing.id); XCTAssertEqual(store.section, "monitoring")
        let remote = try XCTUnwrap(store.sessions.last)
        try await waitUntil("MainView background SSH") { remote.connected }
        try await settle(hosting)
        XCTAssertEqual(store.section, "monitoring"); XCTAssertEqual(store.activeSession, existing.id)
        XCTAssertTrue(find(MonitoringGroupNativeButton.self, in: hosting).isEmpty, "Appending a tab must not recreate the monitor and reset its selected group")
        XCTAssertEqual(find(NSTextField.self, in: hosting).first { $0.placeholderString == search.placeholderString }?.stringValue, "Background")
        XCTAssertNil(store.monitoring.selectedTargetID, "Connect is independent of selecting details")
        try capture(hosting, name: "monitor-background-card-preserved")
        let picker = try XCTUnwrap(find(NSSegmentedControl.self, in: hosting).first { $0.identifier?.rawValue == "monitoring-layout-picker" })
        picker.selectedSegment = 1; picker.sendAction(picker.action, to: picker.target)
        try await settle(hosting)
        let openTerminal = try XCTUnwrap(find(MonitoringTerminalNativeButton.self, in: hosting).first)
        XCTAssertFalse(openTerminal.prominent)
        XCTAssertEqual(store.sessions.count, 2)
        let client = try XCTUnwrap(remote.client)
        try capture(hosting, name: "monitor-background-list-open-terminal")
        openTerminal.performClick(nil)
        XCTAssertEqual(store.section, "terminal"); XCTAssertEqual(store.activeSession, remote.id)
        XCTAssertEqual(store.sessions.count, 2); XCTAssertTrue(remote.client === client)
    }

    private func synchronousFixture() -> (AppStore, TabbyNative.Host, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-background-boundary-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Background boundary fixture"; host.address = "127.0.0.1"
        host.username = "test"; host.auth = "key"; host.keyPath = root.appendingPathComponent("unused-key").path
        store.workspace.preferences.language = "en-US"; store.workspace.hosts = [host]
        store.section = "monitoring"; store.group = "Vault selection"; store.search = "Vault search"
        return (store, host, root)
    }
    private func fixture() throws -> (AppStore, TabbyNative.Host, URL) {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"],
              ProcessInfo.processInfo.environment["TABBY_TEST_MONITOR_SAMPLE"] != nil else { throw XCTSkip("Loopback monitoring fixture required") }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-background-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Background monitoring fixture"; host.address = "127.0.0.1"; host.group = "QA group"
        host.port = try XCTUnwrap(info["port"] as? Int); host.username = "test"; host.auth = "key"
        host.keyPath = try XCTUnwrap(info["clientKey"] as? String)
        store.workspace.preferences.language = "en-US"; store.workspace.hosts = [host]; store.workspace.groups = [host.group]
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = try XCTUnwrap(info["hostKey"] as? String)
        return (store, host, root)
    }
    private func assertMonitoringSelection(_ store: AppStore, target: MonitoringTargetID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.section, "monitoring", file: file, line: line)
        XCTAssertEqual(store.group, "Vault selection", file: file, line: line)
        XCTAssertEqual(store.search, "Vault search", file: file, line: line)
        XCTAssertEqual(store.monitoring.selectedTargetID, target, file: file, line: line)
    }
    private func cleanup(_ store: AppStore, root: URL) {
        store.monitoring.stop(); for session in store.sessions { session.disconnect() }
        try? FileManager.default.removeItem(at: root)
    }
    private func waitUntil(_ reason: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("Timed out waiting for " + reason)
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
