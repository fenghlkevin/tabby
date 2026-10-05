import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class WorkSceneTests: XCTestCase {
    func testLegacyWorkspaceAndLegacyArchiveRemainReadable() throws {
        let legacy = try JSONDecoder().decode(Workspace.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.workScenes.isEmpty)
        let data = try WorkspaceArchiveCodec.encode(workspace: Workspace(), password: nil, secrets: [:])
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var workspace = try XCTUnwrap(raw["workspace"] as? [String: Any]); workspace.removeValue(forKey: "workScenes"); raw["workspace"] = workspace
        let old = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertTrue(try WorkspaceArchiveCodec.decode(old, password: nil).workspace.workScenes.isEmpty)
    }
    func testSceneAndForwardingReferencesSurviveArchive() throws {
        var workspace = Workspace()
        var host = TabbyNative.Host(); host.name = "Fixture"; host.address = "fixture.invalid"
        var rule = PortForwardRule(); rule.name = "SOCKS"; rule.kind = "dynamic"; rule.hostID = host.id; rule.bindPort = 1080
        let scene = WorkScene(name: "排障", terminals: [WorkSceneTerminal(hostID: host.id, directory: "/opt/app's data")], split: false, directories: [WorkSceneLocation(hostID: host.id, path: "/var/log")], logFiles: [WorkSceneLocation(hostID: host.id, path: "/var/log/app.log")], forwardIDs: [rule.id], startForwards: true)
        workspace.hosts = [host]; workspace.forwards = [rule]; workspace.workScenes = [scene]
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace, password: nil, secrets: [:])
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(data, password: nil).workspace.workScenes, [scene])
    }
    func testSceneValidationRejectsUnsafePathsAndStaleReferences() throws {
        var scene = WorkScene(name: "Fixture", terminals: [WorkSceneTerminal()])
        scene.terminals[0].directory = "/tmp/one\nwhoami"
        XCTAssertThrowsError(try scene.validated(workspace: Workspace()))
        scene.terminals[0].directory = "/tmp/one ' two"
        XCTAssertNoThrow(try scene.validated(workspace: Workspace()))
        scene.terminals[0].hostID = UUID()
        XCTAssertThrowsError(try scene.validated(workspace: Workspace()))
    }
    func testSceneSaveFailureRollsBackWholeWorkspace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: base); defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(fileURL: base.appendingPathComponent("workspace.json"))
        store.workspace.preferences.scrollback = -3
        XCTAssertThrowsError(try store.saveScene(WorkScene(name: "Fixture", terminals: [WorkSceneTerminal()])))
        XCTAssertTrue(store.workspace.workScenes.isEmpty)
        XCTAssertEqual(store.workspace.preferences.scrollback, -3)
    }
    func testOpeningAndClosingScenePreservesOtherSessionsAndOwnsOneTab() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(fileURL: base.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false
        let unrelated = TerminalSession(host: nil, store: store)
        store.sessions = [unrelated]
        let definition = WorkScene(name: "Local QA", terminals: [WorkSceneTerminal(), WorkSceneTerminal()], split: true)
        let opened = try store.openScene(definition)
        defer { store.closeScene(opened.id); unrelated.disconnect() }
        XCTAssertEqual(store.openScenes.count, 1)
        XCTAssertEqual(store.standaloneSessions.map(\.id), [unrelated.id])
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertEqual(try store.openScene(definition).id, opened.id)
        XCTAssertEqual(store.sessions.count, 3, "Reopening a live scene selects its existing workspace")
        XCTAssertEqual(store.section, "scene")
        store.showFileSection(); XCTAssertEqual(opened.mode, "files"); XCTAssertEqual(store.section, "scene")
        store.showTerminalSection(); XCTAssertEqual(opened.mode, "terminal")
        store.closeScene(opened.id)
        XCTAssertEqual(store.sessions.map(\.id), [unrelated.id])
        XCTAssertTrue(store.openScenes.isEmpty)
    }
    func testInitialDirectoryIsEnteredWithSpacesAndQuotes() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("axon scene ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(fileURL: base.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false
        let definition = WorkScene(name: "Directory", terminals: [WorkSceneTerminal(directory: base.path)])
        let opened = try store.openScene(definition); defer { store.closeScene(opened.id) }
        for _ in 0..<100 { if store.sceneTasks[opened.id] == nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let proof = base.appendingPathComponent("cwd.txt")
        let command = "pwd > " + SnippetParameters.shellArgument(proof.path) + "\n"
        let session = try XCTUnwrap(store.sessions.first { opened.sessionIDs.contains($0.id) })
        let bytes = Array(command.utf8); session.terminal?.send(data: bytes[...])
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: proof.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), base.path)
    }

    func testStandaloneCloseOthersMenuPreservesLiveSceneSessions() async throws {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false
        let kept = TerminalSession(host: nil, store: store), other = TerminalSession(host: nil, store: store)
        store.sessions = [kept, other]
        _ = kept.makeView(); _ = other.makeView()
        let scene = try store.openScene(WorkScene(name: "Protected scene", terminals: [WorkSceneTerminal(), WorkSceneTerminal()], split: true))
        defer { store.closeScene(scene.id); store.sessions.forEach { $0.disconnect() } }
        let sceneSessions = store.sessions.filter { scene.sessionIDs.contains($0.id) }
        let split = store.splitPartners
        XCTAssertEqual(sceneSessions.count, 2); XCTAssertTrue(sceneSessions.allSatisfy(\.connected))
        store.activeSession = kept.id; store.section = "terminal"
        let hosting = NSHostingView(rootView: SessionTab(session: kept, showTools: {}).environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 34), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        func nativeTab(_ view: NSView) -> NativeSessionTabView? {
            if let native = view as? NativeSessionTabView { return native }
            return view.subviews.compactMap(nativeTab).first
        }
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if nativeTab(hosting) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let tab = try XCTUnwrap(nativeTab(hosting))
        let closeOthers = try XCTUnwrap(tab.makeMenu().items.first { $0.tag == SessionTabAction.closeOthers.rawValue })
        XCTAssertTrue(app.sendAction(try XCTUnwrap(closeOthers.action), to: closeOthers.target, from: closeOthers))
        XCTAssertFalse(store.sessions.contains { $0.id == other.id }); XCTAssertFalse(other.connected)
        XCTAssertTrue(kept.connected)
        XCTAssertEqual(store.standaloneSessions.map(\.id), [kept.id])
        XCTAssertEqual(store.openScenes.map(\.id), [scene.id]); XCTAssertEqual(scene.sessionIDs, sceneSessions.map(\.id))
        XCTAssertTrue(sceneSessions.allSatisfy(\.connected)); XCTAssertEqual(store.splitPartners, split)
        XCTAssertEqual(store.activeSession, kept.id); XCTAssertEqual(store.section, "terminal")
    }
}
