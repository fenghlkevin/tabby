import XCTest
@testable import TabbyNative

@MainActor final class WorkspaceTransferTests: XCTestCase {
    private func host(_ name: String, address: String = "example.invalid") -> TabbyNative.Host {
        var host = TabbyNative.Host(); host.name = name; host.address = address; host.username = "test"
        return host
    }
    func testPreviewDoesNotMutateAndDeduplicatesEffectiveIdentityAndRemapsJump() throws {
        var original = Workspace()
        let shared = VaultCredential(name: "login", username: "tester")
        var existing = host("Existing", address: "Jump.Example.Invalid"); existing.username = "ignored"; existing.credentialID = shared.id
        original.credentials = [shared]; original.hosts = [existing]
        var duplicate = host("Duplicate", address: "jump.example.invalid"); duplicate.username = "tester"
        var imported = host("Production", address: "target.invalid"); imported.jumpHostID = duplicate.id
        let review = try WorkspaceTransfer.review(HostImportDocument(hosts: [duplicate, imported]), workspace: original)
        XCTAssertEqual(review.added, 1); XCTAssertEqual(review.skipped, 1)
        XCTAssertEqual(original.hosts.count, 1)
        XCTAssertEqual(review.workspace.hosts.last?.jumpHostID, existing.id)
        XCTAssertNotEqual(review.workspace.hosts.last?.id, imported.id)
    }
    func testDuplicateEndpointInsideDocumentSkipsSecretAndRemapsJump() throws {
        let first = host("First")
        var second = host("Second"); second.port = first.port
        var target = host("Target", address: "target.invalid"); target.jumpHostID = second.id
        let document = HostImportDocument(hosts: [first, second, target], secrets: [second.id: Secrets.Value(secret: "discarded")])
        let review = try WorkspaceTransfer.review(document, workspace: Workspace())
        XCTAssertEqual(review.added, 2); XCTAssertEqual(review.skipped, 1); XCTAssertTrue(review.secrets.isEmpty)
        XCTAssertEqual(review.workspace.hosts.last?.jumpHostID, review.workspace.hosts.first?.id)
    }
    func testFailedImportLeavesOriginalWorkspaceAndDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker"); try Data("unchanged".utf8).write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        store.workspace.hosts = [host("Original")]
        let incoming = host("New", address: "new.invalid")
        XCTAssertThrowsError(try store.importHosts(HostImportDocument(hosts: [incoming])))
        XCTAssertEqual(store.workspace.hosts.map(\.name), ["Original"])
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "unchanged")
    }
    func testImportThenReimportPersistsOneHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let document = try HostTransfer.parse(Data("hostname,label,username,port\nlocalhost,Fixture,qa,2222\n".utf8), format: .csv)
        XCTAssertEqual(try store.importHosts(document).added, 1)
        XCTAssertEqual(try store.importHosts(document).skipped, 1)
        XCTAssertEqual(AppStore(fileURL: store.fileURL).workspace.hosts.count, 1)
    }
    func testRestoreRequiresClosedSessionsBeforeChangingDiskOrKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.hosts = [host("Original")]
        let session = TerminalSession(host: nil, store: store); store.sessions = [session]
        var replacement = Workspace(); replacement.hosts = [host("Restored", address: "restored.invalid")]
        XCTAssertThrowsError(try store.restoreArchive(WorkspaceArchive(workspace: replacement)))
        XCTAssertEqual(store.workspace.hosts.map(\.name), ["Original"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    func testMetadataOnlyBackupRejectsIncludingSecretsWithoutPassword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        XCTAssertThrowsError(try store.archiveData(password: nil, includeSecrets: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    func testCloudSettingsAreNotInWorkspaceBackup() throws {
        let config = CloudConnectionSettings(s3: S3BackupConfiguration(endpoint: "https://storage.invalid", bucket: "test", accessKeyID: "sampleAK"))
        let metadata = try JSONEncoder().encode(config)
        XCTAssertTrue(String(decoding: metadata, as: UTF8.self).contains("sampleAK"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("secretAccessKey"))
        let archive = try WorkspaceArchiveCodec.encode(workspace: Workspace(), password: nil)
        XCTAssertFalse(String(decoding: archive, as: UTF8.self).contains("sampleAK"))
    }
}
