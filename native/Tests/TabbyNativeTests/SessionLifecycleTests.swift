import XCTest
import AppKit
import SwiftTerm
import Citadel
import NIO
@testable import TabbyNative

final class SessionLifecycleTests: XCTestCase {
    @MainActor func testCloseSelectsSurvivingSplitThenAdjacentTabAndReturnsLastTerminalToHosts() {
        let store = temporaryStore()
        let a = TerminalSession(host: nil, store: store), b = TerminalSession(host: nil, store: store)
        let c = TerminalSession(host: nil, store: store), d = TerminalSession(host: nil, store: store)
        store.sessions = [a, b, c, d]; store.activeSession = c.id; store.section = "terminal"
        store.splitPartners = [a.id: c.id, c.id: a.id]
        store.close(c.id)
        XCTAssertEqual(store.sessions.map(\.id), [a.id, b.id, d.id])
        XCTAssertEqual(store.activeSession, a.id, "The other split must remain focused even when another tab is adjacent")
        XCTAssertTrue(store.splitPartners.isEmpty)
        store.close(d.id)
        XCTAssertEqual(store.activeSession, a.id, "Closing a background tab must preserve focus")
        store.close(a.id)
        XCTAssertEqual(store.activeSession, b.id)
        store.close(b.id)
        XCTAssertTrue(store.sessions.isEmpty); XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.section, "hosts")
        store.close(b.id)
        XCTAssertEqual(store.section, "hosts")
    }

    @MainActor func testFailureRemainsVisibleAndObsoleteCompletionsCannotCloseReplacementAttempt() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var host = TabbyNative.Host(); host.name = "Lifecycle fixture"; host.address = "127.0.0.1"
        let session = TerminalSession(host: host, store: store)
        let terminal = TerminalView(frame: .zero); session.terminal = terminal
        store.sessions = [session]; store.activeSession = session.id; store.section = "terminal"
        let oldAttempt = session.generation
        session.connectionEnded(request: oldAttempt, error: AppFailure.message("Network fixture failure"))
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertEqual(store.activeSession, session.id)
        XCTAssertEqual(session.status, "Network fixture failure"); XCTAssertFalse(session.connected)
        XCTAssertEqual(store.section, "terminal")
        try await Task.sleep(for: .milliseconds(20))
        let failureText = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(failureText.contains("Network fixture failure"))
        session.connected = true; session.status = "Replacement attempt"
        session.connectionEnded(request: oldAttempt)
        session.connectionEnded(request: oldAttempt, error: CancellationError())
        session.connectionEnded(request: oldAttempt, error: AppFailure.message("Stale failure"))
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertTrue(session.connected); XCTAssertEqual(session.status, "Replacement attempt")
        session.connectionEnded(request: session.generation)
        XCTAssertTrue(store.sessions.isEmpty); XCTAssertFalse(session.connected)
        XCTAssertEqual(store.section, "hosts")
    }

    @MainActor func testLocalShellExitClosesOnlyItsPaneAndIgnoresForeignOrCancelledCallbacks() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false
        store.connect()
        let survivor = try XCTUnwrap(store.sessions.first)
        store.split()
        let exiting = try XCTUnwrap(store.sessions.last)
        let view = try XCTUnwrap(exiting.makeView() as? LocalProcessTerminalView)
        defer { store.sessions.forEach { $0.disconnect() } }
        XCTAssertTrue(view.process.running)
        exiting.processTerminated(source: TerminalView(frame: .zero), exitCode: 0)
        XCTAssertEqual(store.sessions.count, 2, "A different terminal view must not end this process")
        view.process.send(data: Array("exit\n".utf8)[...])
        try await waitUntil { !store.sessions.contains { $0.id == exiting.id } }
        XCTAssertEqual(store.sessions.map(\.id), [survivor.id]); XCTAssertEqual(store.activeSession, survivor.id)
        XCTAssertTrue(store.splitPartners.isEmpty); XCTAssertEqual(store.section, "terminal")
        XCTAssertFalse(exiting.connected); XCTAssertFalse(view.process.running)
        exiting.processTerminated(source: view, exitCode: 0)
        XCTAssertEqual(store.sessions.map(\.id), [survivor.id], "Late termination after cleanup must be harmless")
        let survivorView = try XCTUnwrap(survivor.makeView() as? LocalProcessTerminalView)
        survivorView.process.send(data: Array("exit\n".utf8)[...])
        try await waitUntil { store.sessions.isEmpty }
        XCTAssertNil(store.activeSession); XCTAssertEqual(store.section, "hosts")
    }

    @MainActor func testLocalNonzeroExitAndLaunchFailureKeepDiagnosticTab() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false
        store.connect()
        let failed = try XCTUnwrap(store.sessions.first)
        let view = try XCTUnwrap(failed.makeView() as? LocalProcessTerminalView)
        view.process.send(data: Array("exit 3\n".utf8)[...])
        try await waitUntil { !failed.connected }
        XCTAssertEqual(store.sessions.map(\.id), [failed.id]); XCTAssertTrue(failed.status.contains("3"))
        XCTAssertEqual(store.section, "terminal")
        store.close(failed.id)
        store.workspace.preferences.localShell = root.appendingPathComponent("missing-shell").path
        store.connect()
        let unlaunchable = try XCTUnwrap(store.sessions.first)
        _ = unlaunchable.makeView()
        defer { store.close(unlaunchable.id) }
        try await waitUntil { !unlaunchable.connected }
        XCTAssertEqual(store.sessions.map(\.id), [unlaunchable.id])
        XCTAssertTrue(unlaunchable.status.contains("127"), unlaunchable.status)
    }

    @MainActor func testCancellingRealAuthenticationRemovesNewTabWithoutCancellationText() async throws {
        _ = NSApplication.shared
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var host = TabbyNative.Host(); host.name = "Authentication cancel fixture"; host.address = "127.0.0.1"
        store.workspace.preferences.language = "en-US"
        store.connect(host)
        let session = try XCTUnwrap(store.sessions.first)
        var cancelled = false
        let cancel = Timer(timeInterval: 0.02, repeats: true) { timer in
            guard let window = NSApp.modalWindow, window.title == "Connection authentication" else { return }
            cancelled = true; timer.invalidate(); window.performClose(nil)
        }
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
            XCTFail("Connection authentication cancellation did not finish")
            store.close(session.id)
        }
        RunLoop.main.add(cancel, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { cancel.invalidate(); watchdog.invalidate(); session.disconnect() }
        let terminal = session.makeView()
        try await waitUntil { store.sessions.isEmpty }
        XCTAssertTrue(cancelled); XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(store.section, "hosts"); XCTAssertNil(store.activeSession); XCTAssertNil(session.task)
        let output = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertFalse(output.contains("CancellationError")); XCTAssertFalse(output.contains("cancelled"))
        XCTAssertNil(store.error)
    }

    @MainActor func testLoopbackRemoteExitClosesTabAndReleasesMonitoringDemand() async throws {
        _ = NSApplication.shared
        let (store, session, root) = try loopbackSession()
        defer { store.monitoring.stop(); session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = session.makeView()
        try await waitUntil { session.connected }
        let client = try XCTUnwrap(session.client)
        store.monitoring.configure(store: store, terminalStatusVisible: true, foreground: true)
        let target = try XCTUnwrap(store.monitoring.targetID(for: session))
        try await XCTUnwrap(session.writer).write(ByteBuffer(string: "exit\n"))
        try await waitUntil { store.sessions.isEmpty }
        XCTAssertNil(store.activeSession); XCTAssertEqual(store.section, "hosts")
        XCTAssertFalse(session.connected); XCTAssertNil(session.client); XCTAssertNil(session.writer); XCTAssertNil(session.task)
        XCTAssertEqual(store.monitoring.states[target], .disconnected)
        try await waitUntil { !client.isConnected }
    }

    @MainActor func testLoopbackReconnectionSurvivesOldPTYCompletionAndUnexpectedDropKeepsError() async throws {
        _ = NSApplication.shared
        let (store, session, root) = try loopbackSession()
        defer { session.disconnect(); try? FileManager.default.removeItem(at: root) }
        _ = session.makeView()
        try await waitUntil { session.connected }
        let oldClient = try XCTUnwrap(session.client)
        session.reconnect()
        try await waitUntil { session.connected && session.client !== oldClient }
        // The cancelled old PTY task has time to deliver its completion.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertTrue(session.connected)
        let newClient = try XCTUnwrap(session.client)
        let response = try await newClient.executeCommand("printf SESSION_RECONNECTED")
        XCTAssertEqual(String(buffer: response), "SESSION_RECONNECTED")
        try await newClient.close()
        try await waitUntil { !session.connected }
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertEqual(store.activeSession, session.id)
        XCTAssertEqual(store.section, "terminal"); XCTAssertFalse(session.status.isEmpty)
        XCTAssertNotEqual(session.status, "Disconnected"); XCTAssertFalse(session.status.contains("CancellationError"))
        XCTAssertNil(session.client); XCTAssertNil(session.writer)
    }

    @MainActor private func temporaryStore() -> AppStore {
        AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("axon-lifecycle-" + UUID().uuidString).appendingPathComponent("workspace.json"))
    }
    @MainActor private func loopbackSession() throws -> (AppStore, TerminalSession, URL) {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Lifecycle loopback"; host.address = "127.0.0.1"
        host.port = info["port"] as! Int; host.username = "test"; host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.preferences.language = "en-US"
        store.workspace.hosts = [host]
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        store.connect(host)
        return (store, try XCTUnwrap(store.sessions.first), root)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Session lifecycle transition timed out")
    }
}
