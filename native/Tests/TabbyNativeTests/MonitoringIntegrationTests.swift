import XCTest
import SwiftUI
import AppKit
import Citadel
import NIO
@testable import TabbyNative

final class MonitoringIntegrationTests: XCTestCase {
    func testVisibilityPolicyRequiresForegroundVisibleWindow() {
        XCTAssertTrue(MonitoringVisibility.permitsSampling(applicationActive: true, applicationHidden: false, windowVisible: true, windowMiniaturized: false, windowOccluded: false))
        for index in 0..<5 {
            XCTAssertFalse(MonitoringVisibility.permitsSampling(applicationActive: index != 0, applicationHidden: index == 1, windowVisible: index != 2, windowMiniaturized: index == 3, windowOccluded: index == 4))
        }
    }
    @MainActor func testHostStatusNavigationDoesNotConnectOrChangePreferences() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "monitor.invalid"; host.name = "Monitoring fixture"; host.username = "tester"
        store.workspace.hosts = [host]
        let preferences = store.workspace.preferences
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        store.showMonitoring(host)
        XCTAssertEqual(store.section, "monitoring")
        XCTAssertEqual(store.monitoring.selectedTargetID?.address, host.address)
        XCTAssertEqual(store.monitoring.selectedTargetID?.username, "tester")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.workspace.preferences, preferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        store.showMonitoring()
        XCTAssertNil(store.monitoring.selectedTargetID)
    }
    @MainActor func testMonitoringNavigationPreservesExistingTerminalAndVaultSelection() {
        let store = AppStore(fileURL: URL(fileURLWithPath: "/private/tmp/axon-monitor-unused-" + UUID().uuidString))
        store.connect()
        let session = store.sessions[0]
        let active = store.activeSession
        store.showMonitoring()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.sessions[0] === session)
        XCTAssertEqual(store.activeSession, active)
        XCTAssertEqual(store.section, "monitoring")
        XCTAssertNil(session.task)
        store.monitoring.stop()
    }
    @MainActor func testMonitoringExecAndPausePreserveAuthenticatedTerminal() async throws {
        guard let infoPath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"],
              ProcessInfo.processInfo.environment["TABBY_TEST_MONITOR_SAMPLE"] != nil else {
            throw XCTSkip("Loopback monitoring fixture required")
        }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: infoPath))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Linux monitoring fixture"; host.address = "127.0.0.1"
        host.port = info["port"] as! Int; host.username = "test"; host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.hosts = [host]
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        store.connect(host)
        let session = try XCTUnwrap(store.sessions.first)
        defer { store.monitoring.stop(); session.disconnect() }
        _ = session.makeView()
        for _ in 0..<200 {
            if session.connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.connected, session.status)
        let client = try XCTUnwrap(session.client)
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertNotNil(session.writer)
        let originalTerminal = try XCTUnwrap(session.terminal)
        store.section = "monitoring"
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        let id = try XCTUnwrap(store.monitoring.targetID(for: session))
        for _ in 0..<200 {
            if store.monitoring.snapshots[id] != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let snapshot = try XCTUnwrap(store.monitoring.snapshots[id])
        XCTAssertTrue(snapshot.isSupported)
        XCTAssertNotNil(snapshot.memory)
        XCTAssertFalse(snapshot.processes.isEmpty)
        XCTAssertTrue(session.connected)
        XCTAssertTrue(session.client === client)
        XCTAssertNotNil(session.writer)
        XCTAssertTrue(session.terminal === originalTerminal)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        store.section = "hosts"
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        XCTAssertEqual(store.monitoring.states[id], .paused)
        let channelResult = try await client.executeCommand("printf MONITOR_PARENT_OK")
        XCTAssertEqual(String(buffer: channelResult), "MONITOR_PARENT_OK")
        XCTAssertTrue(session.connected)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        // A cancelled read-only exec must close its own channel, preserving the PTY.
        let exec = Task { try await MonitoringSSHExecutor.execute(client: client, command: "sleep 2; printf CANCELLED", maximumBytes: 1024) }
        try await Task.sleep(for: .milliseconds(100))
        exec.cancel()
        do { _ = try await exec.value; XCTFail("Cancelled exec must not produce a sample") } catch { }
        XCTAssertTrue(client.isConnected)
        XCTAssertTrue(session.connected)
        let afterCancel = try await client.executeCommand("printf AFTER_CANCEL_OK")
        XCTAssertEqual(String(buffer: afterCancel), "AFTER_CANCEL_OK")
        // Bypass synthetic responses to exercise the actual collector shell on
        // this macOS fixture host and verify its explicit unsupported result.
        let actualCommand = MonitoringCommand.script.replacingOccurrences(of: "printf 'AXON_MONITOR_V1\\n'", with: "printf 'AXON_MONITOR_%s\\n' V1")
        XCTAssertFalse(actualCommand.contains("AXON_MONITOR_V1"))
        let actualOutput = try await MonitoringSSHExecutor.execute(client: client, command: actualCommand, maximumBytes: MonitoringCommand.maximumResponseBytes)
        let actualSample = try MonitoringSampleParser.parse(raw: actualOutput, previous: nil, timestamp: Date())
        XCTAssertEqual(actualSample.os, "Darwin")
        XCTAssertFalse(actualSample.isSupported)
        XCTAssertTrue(client.isConnected)
    }
}
