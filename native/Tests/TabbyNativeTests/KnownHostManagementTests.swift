import XCTest
@testable import TabbyNative

@MainActor final class KnownHostManagementTests: XCTestCase {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfkNV4OS33ImTXvorZr72q4v5XhVEQKfvqsxOEJ/XaR"

    private func encoded(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(workspace)
    }

    func testFingerprintHashesDecodedBlobAndIgnoresCommentAndWhitespace() throws {
        let identity = try XCTUnwrap(KnownHostIdentity(openSSHPublicKey: key))
        XCTAssertEqual(identity.algorithm, "ssh-ed25519")
        XCTAssertEqual(identity.fingerprint, "SHA256:BFlAu0a4IRDePBZATpvzbeWrjzjd9h2/tKqd//EWd1Q")
        XCTAssertEqual(KnownHostIdentity(openSSHPublicKey: key + " fixture@example.invalid"), identity)
        XCTAssertEqual(KnownHostIdentity(openSSHPublicKey: "\n " + key.replacingOccurrences(of: " ", with: "\t") + " \n"), identity)
    }

    func testMalformedRecordsNeverProduceAnEmptyOrMislabelledFingerprint() {
        for record in ["", "ssh-ed25519", "ssh-ed25519 !!!", "ssh-ed25519 ====", "ssh-ed25519 aGVsbG8=",
                       "ssh-ed25519 AAAAAA==", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5", // header only
                       "ssh-rsa " + String(key.split(separator: " ")[1])] {
            XCTAssertNil(KnownHostIdentity(openSSHPublicKey: record), record)
        }
    }

    func testRemovingOneTrustRecordPersistsWithoutChangingHostsCredentialsOrSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Saved host"; host.address = "fixture.invalid"
        var credential = VaultCredential(); credential.name = "Saved identity"
        host.credentialID = credential.id
        var snippet = CommandSnippet(); snippet.name = "Saved command"; snippet.body = "ls"
        var forward = PortForwardRule(); forward.hostID = host.id
        store.workspace.hosts = [host]
        store.workspace.credentials = [credential]
        store.workspace.snippets = [snippet]
        store.workspace.forwards = [forward]
        store.workspace.groups = ["Saved group"]
        store.workspace.tags = ["Saved tag"]
        store.workspace.logs = [ActivityLog(category: "ssh", event: "connected", host: host.address, failed: false)]
        store.workspace.bookmarks = ["local": ["/tmp"]]
        store.workspace.trustedKeys = ["fixture.invalid:22": key, "another.invalid:2222": key]
        let session = TerminalSession(host: host, store: store)
        store.sessions = [session]
        store.activeSession = session.id
        XCTAssertTrue(store.save())
        var expected = store.workspace
        expected.trustedKeys.removeValue(forKey: "fixture.invalid:22")

        XCTAssertTrue(store.removeKnownHost("fixture.invalid:22"))

        XCTAssertEqual(try encoded(store.workspace), try encoded(expected))
        XCTAssertEqual(try encoded(AppStore(fileURL: store.fileURL).workspace), try encoded(expected))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.sessions.first === session)
        XCTAssertEqual(store.activeSession, session.id)
    }

    func testMissingRecordIsANoOpWithoutWritingWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        XCTAssertTrue(store.removeKnownHost("missing.invalid:22"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testFailedSaveRestoresTrustAndEntireWorkspaceNormalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        let original = Data("original".utf8)
        try original.write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        store.workspace.trustedKeys = ["fixture.invalid:22": key]
        store.workspace.preferences.scrollback = 1_500_000
        store.workspace.recentTargets = [RecentTarget(kind: .localTerminal, lastOpened: Date(timeIntervalSince1970: 0))]
        let before = try encoded(store.workspace)

        XCTAssertFalse(store.removeKnownHost("fixture.invalid:22"))

        XCTAssertEqual(try encoded(store.workspace), before)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    func testUnreadableWorkspaceCannotBeOverwrittenByTrustRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspace.json")
        let original = Data("unreadable original".utf8)
        try original.write(to: file)
        let store = AppStore(fileURL: file)
        store.workspace.trustedKeys = ["fixture.invalid:22": key]
        let before = try encoded(store.workspace)

        XCTAssertFalse(store.removeKnownHost("fixture.invalid:22"))

        XCTAssertEqual(try encoded(store.workspace), before)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
