import XCTest
@testable import TabbyNative

final class FileWorkflowNavigationTests: XCTestCase {
    @MainActor func testSelectingCurrentHostKeepsPaneAndDoesNotReconnect() async throws {
        let fixture = try NavigationFixture(); defer { fixture.remove() }
        let store = AppStore(fileURL: fixture.root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "fixture.invalid"
        let session = TerminalSession(host: nil, store: store)
        var opens = 0
        var active = true
        let files = FileManagerModel(session: session, remoteOpener: { _ in
            opens += 1
            return FileEndpointLease(pane: FilePane(path: fixture.root.path, backend: LocalFiles()), isActive: { active })
        })
        defer { files.close() }
        await files.selectHost(host)
        let pane = files.remote
        files.showHostPicker()
        await files.selectHost(host)
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(files.remote === pane)
        XCTAssertFalse(files.showingHostPicker)
        active = false
        await files.selectHost(host)
        XCTAssertEqual(opens, 2)
    }

    @MainActor func testSceneLocalDefaultAppliesOnceAndRefreshKeepsUserDirectory() async throws {
        let fixture = try NavigationFixture(); defer { fixture.remove() }
        let store = AppStore(fileURL: fixture.root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); store.sessions = [session]; session.connected = true
        installScene(store: store, session: session, locations: [WorkSceneLocation(path: fixture.defaultDirectory.path)])
        let files = FileManagerModel(session: session); defer { files.close() }
        await files.open()
        XCTAssertEqual(files.local.path, fixture.defaultDirectory.path)
        XCTAssertNil(store.terminalFileRequest)
        _ = await files.local.navigate(fixture.explicitDirectory.path)
        await files.open()
        XCTAssertEqual(files.local.path, fixture.explicitDirectory.path)
    }

    @MainActor func testExplicitTerminalDirectoryRequestWinsOverSceneDefault() async throws {
        let fixture = try NavigationFixture(); defer { fixture.remove() }
        let store = AppStore(fileURL: fixture.root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); store.sessions = [session]; session.connected = true
        installScene(store: store, session: session, locations: [WorkSceneLocation(path: fixture.defaultDirectory.path)])
        let request = TerminalFileRequest(sessionID: session.id, host: nil, path: fixture.explicitDirectory.path, isSelection: false, generation: session.generation)
        store.terminalFileRequest = request
        let files = FileManagerModel(session: session); defer { files.close() }
        await files.open()
        XCTAssertEqual(files.local.path, fixture.explicitDirectory.path)
        XCTAssertEqual(store.handledTerminalFileRequestID, request.id)
        XCTAssertFalse(files.local.history.contains(fixture.defaultDirectory.path))
        store.terminalFileRequest = nil
        await files.open()
        XCTAssertEqual(files.local.path, fixture.explicitDirectory.path)
    }

    @MainActor func testSceneRemoteDefaultOnlyInitializesTheMatchingHostPane() async throws {
        let fixture = try NavigationFixture(); defer { fixture.remove() }
        let store = AppStore(fileURL: fixture.root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "fixture"; host.address = "fixture.invalid"; host.username = "test"
        store.workspace.hosts = [host]
        let session = TerminalSession(host: host, store: store); store.sessions = [session]; session.connected = true
        installScene(store: store, session: session, locations: [WorkSceneLocation(hostID: UUID(), path: "/wrong-host"), WorkSceneLocation(hostID: host.id, path: fixture.defaultDirectory.path)])
        let files = FileManagerModel(session: session, remoteOpener: { _ in
            FileEndpointLease(pane: FilePane(path: fixture.root.path, backend: LocalFiles()), authenticatedUsername: "test")
        })
        defer { files.close() }
        await files.open()
        XCTAssertEqual(files.remote?.path, fixture.defaultDirectory.path)
        XCTAssertNil(store.terminalFileRequest)
        _ = await files.remote?.navigate(fixture.explicitDirectory.path)
        await files.open()
        XCTAssertEqual(files.remote?.path, fixture.explicitDirectory.path)
    }

    @MainActor private func installScene(store: AppStore, session: TerminalSession, locations: [WorkSceneLocation]) {
        var definition = WorkScene(); definition.name = "Fixture"; definition.terminals = [WorkSceneTerminal(hostID: session.host?.id)]; definition.directories = locations
        let runtime = OpenWorkScene(definition: definition, sessionIDs: [session.id], store: store)
        runtime.mode = "files"; store.openScenes = [runtime]; store.activeSceneID = runtime.id; store.activeSession = session.id; store.section = "scene"
    }
}

private struct NavigationFixture {
    let root: URL
    var defaultDirectory: URL { root.appendingPathComponent("default") }
    var explicitDirectory: URL { root.appendingPathComponent("explicit") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("default"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("explicit"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
