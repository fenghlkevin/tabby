import XCTest
import AppKit
@testable import TabbyNative

final class GroupIntegrationTests: XCTestCase {
    @MainActor func testSFTPRecentClickReopensWhenGroupPortOrJumpRouteChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var group = HostGroup(); group.name = "Base"; group.username = "test"; group.port = 2222
        var host = TabbyNative.Host(); host.address = "server.invalid"; host.group = group.name; host.groupInheritance = .all
        var jump = TabbyNative.Host(); jump.address = "jump.invalid"; jump.username = "test"
        store.workspace.hosts = [host, jump]; store.workspace.groupDefaults = [group]
        var opened = 0
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            opened += 1
            return FileEndpointLease(pane: FilePane(path: root.path, backend: LocalFiles()), authenticatedUsername: "test")
        })
        defer { model.close() }
        await model.selectHost(host)
        XCTAssertEqual(opened, 1)
        let recent = try XCTUnwrap(store.recentTargets.first)
        XCTAssertTrue(store.openRecent(recent))
        let handled1 = await model.openRecentRequestIfNeeded(); XCTAssertTrue(handled1)
        XCTAssertEqual(opened, 1, "Unchanged effective base should reuse the current pane")
        store.workspace.groupDefaults[0].port = 2223
        XCTAssertTrue(store.openRecent(recent))
        let handled2 = await model.openRecentRequestIfNeeded(); XCTAssertTrue(handled2)
        XCTAssertEqual(opened, 2, "Changing an inherited port must not reuse the old connection")
        store.workspace.groupDefaults[0].jumpHostID = jump.id
        XCTAssertTrue(store.openRecent(recent))
        let handled3 = await model.openRecentRequestIfNeeded(); XCTAssertTrue(handled3)
        XCTAssertEqual(opened, 3)
        store.workspace.hosts[1].port = 2200
        XCTAssertTrue(store.openRecent(recent))
        let handled4 = await model.openRecentRequestIfNeeded(); XCTAssertTrue(handled4)
        XCTAssertEqual(opened, 4, "Changing a jump endpoint must not reuse its old route")
    }

    @MainActor func testCatalogSearchAndMonitoringResolveInheritedUsernamePortAndRoute() {
        var group = HostGroup(); group.name = "Production"; group.username = "base-user"; group.port = 2222
        var jumpGroup = HostGroup(); jumpGroup.name = "Gateways"; jumpGroup.username = "gateway-user"; jumpGroup.port = 2200
        var jump = TabbyNative.Host(); jump.name = "Gateway"; jump.address = "gateway.invalid"; jump.group = jumpGroup.name; jump.groupInheritance = .all
        group.jumpHostID = jump.id
        var host = TabbyNative.Host(); host.name = "Server"; host.address = "server.invalid"; host.group = group.name; host.groupInheritance = .all
        host.username = "unused-override"
        var workspace = Workspace(); workspace.hosts = [host, jump]; workspace.groupDefaults = [group, jumpGroup]
        XCTAssertEqual(HostLibraryCatalog(hosts: workspace.hosts, query: "base-user", workspace: workspace).visibleHosts.map(\.id), [host.id])
        XCTAssertTrue(HostLibraryCatalog(hosts: workspace.hosts, query: "unused-override", workspace: workspace).visibleHosts.isEmpty)
        XCTAssertEqual(LauncherCatalog(hosts: workspace.hosts, groups: [group.name], query: "base-user", selectedGroup: group.name, workspace: workspace).visibleHosts.map(\.id), [host.id])
        XCTAssertEqual(MonitoringCenter.savedRoute(for: host, workspace: workspace), [MonitoringRouteHop(address: jump.address, port: 2200, username: "gateway-user")])
    }

    @MainActor func testLoopbackSSHAndStandaloneSFTPUseGroupBaseAndJumpWithoutRepeatedHostCredentials() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var jump = TabbyNative.Host(); jump.name = "Gateway"; jump.address = "127.0.0.1"; jump.port = info["port"] as! Int
        jump.username = "test"; jump.auth = "key"; jump.keyPath = info["clientKey"] as! String
        var group = HostGroup(); group.name = "Inherited"; group.username = "test"; group.port = jump.port
        group.auth = "key"; group.keyPath = jump.keyPath; group.jumpHostID = jump.id
        var host = TabbyNative.Host(); host.name = "Group server"; host.address = "127.0.0.1"; host.group = group.name; host.groupInheritance = .all
        host.port = 1; host.username = "must-not-be-used"
        store.workspace.hosts = [host, jump]; store.workspace.groupDefaults = [group]
        store.workspace.trustedKeys["127.0.0.1:\(jump.port)"] = info["hostKey"] as? String
        store.connect(host)
        let session = try XCTUnwrap(store.sessions.first)
        defer { session.disconnect() }
        _ = session.makeView()
        for _ in 0..<200 {
            if session.connected || session.task == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.connected, session.status)
        XCTAssertEqual(session.authenticatedUsername, "test")
        XCTAssertEqual(session.authenticatedPort, jump.port)
        XCTAssertEqual(session.authenticatedRoute, [MonitoringRouteHop(address: jump.address, port: jump.port, username: "test")])
        XCTAssertEqual(store.monitoring.targetID(for: session)?.port, jump.port)
        XCTAssertEqual(store.resolvedHost(host).port, jump.port)
        session.disconnect()
        store.sessions = []; store.activeSession = nil
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        defer { model.close() }
        await model.selectHost(host)
        XCTAssertTrue(model.remote?.backend is RemoteFiles, model.status)
        XCTAssertEqual(model.session.settingsUsername(for: host), "test")
        XCTAssertTrue(model.remote?.entries.contains { $0.name == "client-key" } == true)
        XCTAssertTrue(store.sessions.isEmpty, "Standalone SFTP must not add a terminal tab")
        XCTAssertEqual(store.workspace.hosts.first?.port, 1, "Connecting must not flatten inherited settings into host overrides")
        XCTAssertEqual(store.workspace.hosts.first?.username, "must-not-be-used")
    }
}
