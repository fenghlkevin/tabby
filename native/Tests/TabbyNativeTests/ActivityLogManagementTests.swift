import XCTest
@testable import TabbyNative

@MainActor final class ActivityLogManagementTests: XCTestCase {
    private func encoded(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(workspace)
    }

    func testClearPersistsAllEventsAndPreservesOtherWorkspaceData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Saved host"; host.address = "fixture.invalid"
        var rule = PortForwardRule(); rule.name = "Saved rule"; rule.hostID = host.id
        var credential = VaultCredential(); credential.name = "Saved identity"
        var snippet = CommandSnippet(); snippet.name = "Saved command"; snippet.body = "ls"
        store.workspace.hosts = [host]
        store.workspace.forwards = [rule]
        store.workspace.credentials = [credential]
        store.workspace.snippets = [snippet]
        store.workspace.groups = ["Saved group"]
        store.workspace.tags = ["Saved tag"]
        store.workspace.bookmarks = ["local": ["/tmp"]]
        store.workspace.trustedKeys = ["fixture.invalid:22": "ssh-ed25519 fixture"]
        store.workspace.logs = [
            ActivityLog(category: "ssh", event: "connected", host: "first.invalid", failed: false),
            ActivityLog(category: "forward", event: "failed", host: "second.invalid", failed: true),
        ]
        XCTAssertTrue(store.save())
        var expected = store.workspace
        expected.logs.removeAll()

        XCTAssertTrue(store.clearActivityLogs())

        XCTAssertEqual(try encoded(store.workspace), try encoded(expected))
        XCTAssertEqual(try encoded(AppStore(fileURL: store.fileURL).workspace), try encoded(expected))
    }

    func testEmptyHistoryIsANoOpWithoutWritingWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        XCTAssertTrue(store.clearActivityLogs())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testFailedSaveRestoresHistoryAndSaveNormalizationChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        let originalBytes = Data("original".utf8)
        try originalBytes.write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        store.workspace.logs = [ActivityLog(category: "ssh", event: "connected", host: "fixture.invalid", failed: false)]
        store.workspace.preferences.scrollback = 1_500_000
        store.workspace.recentTargets = [RecentTarget(kind: .localTerminal, lastOpened: Date(timeIntervalSince1970: 0))]
        let before = try encoded(store.workspace)

        XCTAssertFalse(store.clearActivityLogs())

        XCTAssertEqual(try encoded(store.workspace), before)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: blocker), originalBytes)
    }

    func testUnreadableWorkspaceCannotBeOverwrittenByClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        let original = Data("unreadable original".utf8)
        try original.write(to: url)
        let store = AppStore(fileURL: url)
        store.workspace.logs = [ActivityLog(category: "ssh", event: "connected", host: "fixture.invalid", failed: false)]
        let before = try encoded(store.workspace)

        XCTAssertFalse(store.clearActivityLogs())

        XCTAssertEqual(try encoded(store.workspace), before)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNewEventsContinueRecordingAfterClearAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.record("ssh", "old event", host: "old.invalid")
        XCTAssertTrue(store.clearActivityLogs())

        let restarted = AppStore(fileURL: store.fileURL)
        restarted.record("forward", "new event", host: "new.invalid")

        let logs = AppStore(fileURL: store.fileURL).workspace.logs
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.event, "new event")
        XCTAssertEqual(logs.first?.category, "forward")
        XCTAssertEqual(logs.first?.host, "new.invalid")
    }
}
