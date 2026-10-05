import AppKit
import XCTest
import SwiftTerm
@testable import TabbyNative

final class RecentTargetsTests: XCTestCase {
    @MainActor func testRecentTypeLabelsDistinguishProtocolsAndLocalFiles() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json"))
        XCTAssertEqual(store.recentTypeTitle(RecentTarget(kind: .ssh)), "SSH")
        XCTAssertEqual(store.recentTypeTitle(RecentTarget(kind: .sftp)), "SFTP")
        XCTAssertFalse(store.recentTypeTitle(RecentTarget(kind: .localFiles)).contains("SFTP"))
        XCTAssertFalse(store.recentSubtitle(RecentTarget(kind: .localFiles)).contains("SFTP"))
    }
    func testFileRecentsCannotEvictSSHHistory() {
        let workspace = Workspace()
        let now = Date()
        let ssh = RecentTarget(kind: .ssh, username: "root", address: "ssh.example.com", port: 22, lastOpened: now.addingTimeInterval(-100))
        let files = (0..<8).map { RecentTarget(kind: .sftp, username: "root", address: "file\($0).example.com", port: 22, lastOpened: now.addingTimeInterval(-Double($0))) }
        let pruned = RecentTargets.pruned(files + [ssh], workspace: workspace, now: now)
        XCTAssertTrue(pruned.contains { $0.id == ssh.id })
        XCTAssertEqual(pruned.filter { $0.kind.isFiles }.count, 5)
    }
    private func quick(_ address: String, username: String = "root") -> TabbyNative.Host {
        var host = TabbyNative.Host(); host.address = address; host.name = address; host.username = username
        return host
    }
    func testSevenDayBoundaryDeduplicationAndIndependentTypeLimits() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000), workspace = Workspace()
        let fresh = RecentTarget(kind: .ssh, username: "root", address: "EXAMPLE.INVALID", port: 22, lastOpened: now)
        var duplicate = fresh; duplicate.address = "example.invalid"; duplicate.lastOpened = now.addingTimeInterval(-10)
        let boundary = RecentTarget(kind: .localFiles, lastOpened: now.addingTimeInterval(-RecentTargets.maximumAge))
        let expired = RecentTarget(kind: .localTerminal, lastOpened: now.addingTimeInterval(-RecentTargets.maximumAge - 0.001))
        let future = RecentTarget(kind: .sftp, username: "root", address: "future.invalid", port: 22, lastOpened: now.addingTimeInterval(1))
        let filtered = RecentTargets.pruned([expired, duplicate, boundary, future, fresh], workspace: workspace, now: now)
        XCTAssertEqual(filtered.map(\.id), [fresh.id, boundary.id])
        XCTAssertEqual(filtered.first?.lastOpened, now)
        let many = (0..<8).map { RecentTarget(kind: $0.isMultiple(of: 2) ? .ssh : .sftp, username: "root", address: "host\($0).invalid", port: 22, lastOpened: now.addingTimeInterval(Double(-$0))) }
        XCTAssertEqual(RecentTargets.pruned(Array(many.reversed()), workspace: workspace, now: now).map(\.id), many.map(\.id))
        XCTAssertNotEqual(RecentTarget(kind: .localTerminal).id, RecentTarget(kind: .localFiles).id)
        XCTAssertNotEqual(fresh.id, RecentTarget(kind: .sftp, username: "root", address: "example.invalid", port: 22).id)
    }
    func testQuickIdentityReferenceUsesLatestUsernameAndNeverSerializesKeyMaterial() throws {
        var workspace = Workspace()
        var identity = VaultCredential(); identity.username = "first-user"; identity.auth = "key"; identity.keyPath = "/private/key.pem"; identity.keySource = "text"
        workspace.credentials = [identity]
        var host = quick("example.invalid"); host.credentialID = identity.id; host.auth = "key"; host.keyPath = "/private/other.pem"; host.keySource = "text"
        let target = try XCTUnwrap(RecentTargets.make(kind: .ssh, host: host, workspace: workspace))
        XCTAssertEqual(target.credentialID, identity.id)
        XCTAssertNil(target.username)
        let encoded = try JSONEncoder().encode(target)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(Set(json.keys).isSubset(of: ["kind", "hostID", "credentialID", "username", "address", "port", "lastOpened"]))
        let string = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["keyPath", "keySource", "auth", "password", "/private/"] { XCTAssertFalse(string.contains(forbidden), forbidden) }
        workspace.credentials[0].username = "new-user"
        let resolved = try XCTUnwrap(RecentTargets.resolvedHost(target, workspace: workspace))
        XCTAssertEqual(resolved.username, "new-user")
        XCTAssertEqual(resolved.credentialID, identity.id)
        XCTAssertEqual(RecentTargets.make(kind: .ssh, host: resolved, workspace: workspace)?.id, target.id)
        workspace.credentials = []
        XCTAssertNil(RecentTargets.resolvedHost(target, workspace: workspace))
        XCTAssertTrue(RecentTargets.pruned([target], workspace: workspace).isEmpty)
    }
    @MainActor func testOldWorkspaceAndRestartPersistencePruneAndRemoveHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspace.json")
        try Data("{\"hosts\":[]}".utf8).write(to: file)
        let store = AppStore(fileURL: file)
        XCTAssertTrue(store.recentTargets.isEmpty)
        let now = Date()
        for index in 0..<7 { store.recordRecentSuccess(quick("host\(index).invalid"), kind: .ssh, now: now.addingTimeInterval(Double(-7 + index))) }
        XCTAssertEqual(store.recentTargets.count, 5)
        let reopened = AppStore(fileURL: file)
        XCTAssertEqual(reopened.recentTargets, store.recentTargets)
        let newest = try XCTUnwrap(reopened.recentTargets.first)
        reopened.removeRecent(newest)
        XCTAssertEqual(AppStore(fileURL: file).recentTargets.count, 4)
        reopened.clearRecent()
        XCTAssertTrue(AppStore(fileURL: file).recentTargets.isEmpty)
        reopened.workspace.recentTargets = [RecentTarget(kind: .localFiles, lastOpened: Date().addingTimeInterval(-RecentTargets.maximumAge - 1))]
        reopened.pruneRecentTargets()
        XCTAssertTrue(AppStore(fileURL: file).workspace.recentTargets.isEmpty)
    }
    @MainActor func testSavedHostChangesResolveLatestAndDeletionCannotResurrectFromLateSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = quick("original.invalid"); host.name = "Original"
        store.workspace.hosts = [host]
        store.recordRecentSuccess(host, kind: .sftp)
        let target = try XCTUnwrap(store.recentTargets.first)
        XCTAssertEqual(target.hostID, host.id)
        XCTAssertNil(target.address)
        store.workspace.hosts[0].name = "Updated"; store.workspace.hosts[0].address = "updated.invalid"; store.workspace.hosts[0].port = 2200
        XCTAssertEqual(store.recentTitle(target), "Updated")
        XCTAssertEqual(RecentTargets.resolvedHost(target, workspace: store.workspace)?.address, "updated.invalid")
        XCTAssertEqual(RecentTargets.resolvedHost(target, workspace: store.workspace)?.port, 2200)
        try store.deleteHost(host.id)
        XCTAssertTrue(store.recentTargets.isEmpty)
        XCTAssertFalse(store.openRecent(target))
        store.recordRecentSuccess(host, kind: .sftp) // SFTP-only completion: no TerminalSession exists.
        XCTAssertTrue(store.recentTargets.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
    }
    @MainActor func testRecentReuseRequiresCurrentEndpointAndRestartsDisconnectedSessions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var identity = VaultCredential(); identity.username = "old-user"
        var host = quick("example.invalid"); host.credentialID = identity.id
        store.workspace.credentials = [identity]; store.workspace.hosts = [host]
        store.connect(host)
        let original = try XCTUnwrap(store.sessions.first)
        original.connected = true
        store.recordRecentSuccess(host, kind: .ssh)
        let target = try XCTUnwrap(store.recentTargets.first)
        store.openLauncher()
        XCTAssertTrue(store.openRecent(target))
        XCTAssertEqual(store.activeSession, original.id)
        XCTAssertEqual(store.sessions.count, 1)
        store.workspace.credentials[0].username = "new-user"
        XCTAssertTrue(store.openRecent(target))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNotEqual(store.activeSession, original.id)
        let updatedIdentity = try XCTUnwrap(store.sessions.last)
        XCTAssertEqual(updatedIdentity.authenticatedUsername, "new-user")
        updatedIdentity.connected = true
        store.workspace.hosts[0].address = "changed.invalid"; store.workspace.hosts[0].port = 2222
        XCTAssertTrue(store.openRecent(target))
        XCTAssertEqual(store.sessions.count, 3)
        let current = try XCTUnwrap(store.sessions.last)
        XCTAssertEqual(current.host?.address, "changed.invalid")
        XCTAssertEqual(current.host?.port, 2222)
        current.terminal = TerminalView(frame: .zero); current.connected = false
        XCTAssertTrue(store.openRecent(target))
        XCTAssertEqual(store.sessions.count, 4) // A finished terminal must be reopened, not merely focused.
        for session in Array(store.sessions) { store.close(session.id) }
        XCTAssertTrue(store.openRecent(target))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.host?.address, "changed.invalid")
        store.recordRecentSuccess(kind: .localTerminal)
        let localTarget = try XCTUnwrap(store.recentTargets.first { $0.kind == .localTerminal })
        store.connect(); let local = try XCTUnwrap(store.sessions.last); local.connected = true
        XCTAssertTrue(store.openRecent(localTarget)); XCTAssertEqual(store.activeSession, local.id)
        local.terminal = TerminalView(frame: .zero); local.connected = false
        XCTAssertTrue(store.openRecent(localTarget)); XCTAssertNotEqual(store.activeSession, local.id)
    }
    @MainActor func testFailedClicksAndFailedHistoryWritesDoNotCreatePersistentRecent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspace.json")
        let store = AppStore(fileURL: file)
        let host = quick("example.invalid")
        store.connectQuick(host)
        XCTAssertTrue(store.recentTargets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in throw AppFailure.message("Fixture failure") })
        await model.selectHost(host)
        XCTAssertTrue(store.recentTargets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        model.close()
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let blocked = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        blocked.recordRecentSuccess(kind: .localFiles)
        XCTAssertTrue(blocked.workspace.recentTargets.isEmpty)
        XCTAssertNotNil(blocked.error)
        let corrupt = root.appendingPathComponent("corrupt.json")
        let original = Data("invalid workspace".utf8); try original.write(to: corrupt)
        let corruptStore = AppStore(fileURL: corrupt)
        corruptStore.recordRecentSuccess(kind: .localTerminal)
        XCTAssertTrue(corruptStore.workspace.recentTargets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: corrupt), original)
    }
    @MainActor func testSFTPRecentRequestReusesPaneAndIsConsumedWithoutCreatingTerminals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let host = quick("example.invalid"); store.workspace.hosts = [host]
        store.recordRecentSuccess(host, kind: .sftp)
        let target = try XCTUnwrap(store.recentTargets.first)
        var opened = 0
        let session = TerminalSession(host: nil, store: store)
        let model = FileManagerModel(session: session, remoteOpener: { _ in
            opened += 1
            return FileEndpointLease(pane: FilePane(path: "/remote", backend: EmptyEndpoint()))
        })
        defer { model.close() }
        model.local = FilePane(path: root.path, backend: LocalFiles())
        XCTAssertTrue(store.openRecent(target)); XCTAssertTrue(store.sessions.isEmpty)
        let firstHandled = await model.openRecentRequestIfNeeded(); XCTAssertTrue(firstHandled)
        let pane = try XCTUnwrap(model.remote)
        await pane.navigate("/remote/kept")
        XCTAssertTrue(store.openRecent(target))
        let handled = await model.openRecentRequestIfNeeded(); XCTAssertTrue(handled)
        XCTAssertTrue(model.remote === pane)
        XCTAssertEqual(model.remote?.path, "/remote/kept")
        XCTAssertEqual(opened, 1)
        model.close()
        let fresh = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            opened += 1; return FileEndpointLease(pane: FilePane(path: "/remote", backend: EmptyEndpoint()))
        })
        defer { fresh.close() }
        fresh.local = FilePane(path: root.path, backend: LocalFiles())
        await fresh.open()
        XCTAssertNil(fresh.remote) // Returning later to SFTP cannot replay a consumed click.
        XCTAssertEqual(opened, 1)
        await fresh.selectLocal(path: root.path)
        let local = try XCTUnwrap(store.recentTargets.first { $0.kind == .localFiles })
        XCTAssertTrue(store.openRecent(local))
        await fresh.openRecentRequestIfNeeded()
        XCTAssertTrue(fresh.rightIsLocal)
        XCTAssertEqual(fresh.remote?.path, root.path)
        XCTAssertTrue(store.sessions.isEmpty)
    }
    @MainActor func testBusyRecentRequestDoesNotReplayAfterOperationCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let host = quick("example.invalid"); store.workspace.hosts = [host]
        store.recordRecentSuccess(host, kind: .sftp)
        let target = try XCTUnwrap(store.recentTargets.first)
        var opened = 0
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            opened += 1
            return FileEndpointLease(pane: FilePane(path: "/remote", backend: EmptyEndpoint()))
        })
        defer { model.close() }
        await model.selectLocal(path: root.path)
        let local = try XCTUnwrap(model.remote)
        local.busy = true
        XCTAssertTrue(store.openRecent(target))
        let consumed = await model.openRecentRequestIfNeeded()
        XCTAssertTrue(consumed)
        XCTAssertEqual(opened, 0)
        local.busy = false
        await model.open()
        XCTAssertTrue(model.remote === local)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertEqual(opened, 0)
    }
    @MainActor func testLoopbackSuccessfulSSHAndSFTPHooksRecordSavedIdentities() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = quick("127.0.0.1", username: "test"); host.port = info["port"] as! Int
        host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.hosts = [host]; store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        let session = TerminalSession(host: host, store: store)
        defer { session.disconnect() }
        _ = session.makeView()
        for _ in 0..<200 { if session.connected { break }; try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(session.connected, session.status)
        XCTAssertTrue(store.recentTargets.contains { $0.kind == .ssh && $0.hostID == host.id })
        let files = FileManagerModel(session: session)
        defer { files.close() }
        await files.selectHost(host)
        XCTAssertNotNil(files.remote, files.status)
        XCTAssertTrue(store.recentTargets.contains { $0.kind == .sftp && $0.hostID == host.id })
        let restarted = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(Set(restarted.recentTargets.map(\.kind)), [.ssh, .sftp])
    }
    @MainActor func testRecentCannotReuseDifferentSavedProfileIdentityRouteOrIndependentKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var identityA = VaultCredential(); identityA.username = "root"
        var identityB = VaultCredential(); identityB.username = "root"
        let base = quick("example.invalid")
        var otherProfile = base; otherProfile.id = UUID()
        var sharedA = base; sharedA.credentialID = identityA.id
        var sharedB = sharedA; sharedB.credentialID = identityB.id
        var otherRoute = base; otherRoute.jumpHostID = UUID()
        var key = base; key.auth = "key"; key.keyPath = "/private/first.pem"
        var otherKey = key; otherKey.keyPath = "/private/second.pem"
        var textKey = key; textKey.keySource = "text"
        let cases = [(base, otherProfile), (base, sharedA), (sharedA, sharedB), (base, otherRoute), (base, key), (key, otherKey), (key, textKey)]
        for (index, pair) in cases.enumerated() {
            let (original, requested) = pair
            let store = AppStore(fileURL: root.appendingPathComponent("case\(index).json"))
            store.workspace.hosts = [original]; store.workspace.credentials = [identityA, identityB]
            store.connect(original)
            let first = try XCTUnwrap(store.sessions.first); first.connected = true
            if original.id == requested.id { store.workspace.hosts = [requested] }
            else { store.workspace.hosts.append(requested) }
            store.recordRecentSuccess(requested, kind: .ssh)
            let target = try XCTUnwrap(store.recentTargets.first)
            XCTAssertTrue(store.openRecent(target), "case \(index)")
            XCTAssertEqual(store.sessions.count, 2, "case \(index)")
            XCTAssertNotEqual(store.activeSession, first.id, "case \(index)")
            XCTAssertEqual(store.sessions.last?.host, requested)
            for session in Array(store.sessions) { store.close(session.id) }
        }
    }
    @MainActor func testQuickTargetsReuseTheSameSharedIdentityReferenceAcrossEphemeralHostIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var identity = VaultCredential(); identity.username = "root"; identity.auth = "key"; identity.keySource = "text"
        store.workspace.credentials = [identity]
        var original = quick("example.invalid"); original.credentialID = identity.id
        store.connect(original)
        let session = try XCTUnwrap(store.sessions.first); session.connected = true
        defer { session.connected = false; store.close(session.id) }
        store.recordRecentSuccess(original, kind: .ssh)
        let ssh = try XCTUnwrap(store.recentTargets.first)
        let newlyResolved = try XCTUnwrap(RecentTargets.resolvedHost(ssh, workspace: store.workspace))
        XCTAssertNotEqual(newlyResolved.id, original.id)
        XCTAssertEqual(newlyResolved.credentialID, original.credentialID)
        XCTAssertTrue(store.openRecent(ssh))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.activeSession, session.id)
        var opened = 0
        let files = FileManagerModel(session: session, remoteOpener: { _ in
            opened += 1; return FileEndpointLease(pane: FilePane(path: "/remote", backend: EmptyEndpoint()))
        })
        defer { files.close() }
        await files.selectHost(original)
        let pane = try XCTUnwrap(files.remote)
        let sftp = try XCTUnwrap(store.recentTargets.first { $0.kind == .sftp })
        XCTAssertTrue(store.openRecent(sftp))
        await files.openRecentRequestIfNeeded()
        XCTAssertTrue(files.remote === pane)
        XCTAssertEqual(opened, 1)
    }
    @MainActor func testSFTPRecentReopensWhenSavedProfileIdentityRouteOrKeyChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var identityA = VaultCredential(); identityA.username = "root"
        var identityB = VaultCredential(); identityB.username = "root"
        store.workspace.credentials = [identityA, identityB]
        var original = quick("example.invalid"); original.auth = "key"; original.keyPath = "/private/first.pem"
        store.workspace.hosts = [original]
        var opened: [TabbyNative.Host] = []
        let files = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { host in
            opened.append(host); return FileEndpointLease(pane: FilePane(path: "/remote", backend: EmptyEndpoint()))
        })
        defer { files.close() }
        await files.selectHost(original)
        var requested = original
        for change in 0..<5 {
            let previous = try XCTUnwrap(files.remote)
            switch change {
            case 0: requested.keyPath = "/private/second.pem"
            case 1: requested.credentialID = identityA.id
            case 2: requested.credentialID = identityB.id
            case 3: requested.jumpHostID = UUID()
            default: requested.id = UUID()
            }
            if change == 4 { store.workspace.hosts.append(requested) }
            else { store.workspace.hosts[0] = requested }
            store.recordRecentSuccess(requested, kind: .sftp)
            let target = try XCTUnwrap(store.recentTargets.first)
            XCTAssertTrue(store.openRecent(target))
            await files.openRecentRequestIfNeeded()
            XCTAssertFalse(files.remote === previous, "change \(change)")
            XCTAssertEqual(files.rightHost, requested)
            XCTAssertEqual(opened.count, change + 2)
        }
        let current = try XCTUnwrap(files.remote)
        let unchanged = try XCTUnwrap(store.recentTargets.first)
        XCTAssertTrue(store.openRecent(unchanged))
        await files.openRecentRequestIfNeeded()
        XCTAssertTrue(files.remote === current)
        XCTAssertEqual(opened.count, 6)
    }
    private actor EmptyEndpoint: FileEndpoint {
        func list(_ path: String) -> [FileEntry] { [] }
        func stat(_ path: String) throws -> FileEntry { throw FileMissing(path) }
        func mkdir(_ path: String) {}
        func rename(_ from: String, _ to: String) {}
        func delete(_ entry: FileEntry) {}
        func chmod(_ path: String, _ mode: UInt32) {}
        func read(_ path: String, offset: UInt64, count: Int) -> Data { Data() }
        func write(_ path: String, offset: UInt64, bytes: Data) {}
    }
}
