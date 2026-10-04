import XCTest
@testable import TabbyNative
import Citadel
import NIOSSH
import NIO
import Crypto

final class CoreTests: XCTestCase {
    func testPathValidation() throws {
        XCTAssertEqual(try remoteJoin("/", "file.txt"), "/file.txt")
        XCTAssertEqual(try remoteJoin("/var/log", "a b.log"), "/var/log/a b.log")
        for name in ["", ".", "..", "../escape", "a/b", "a\0b"] { XCTAssertThrowsError(try remoteJoin("/safe", name)) }
    }
    @MainActor func testDefaultsAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        XCTAssertEqual(store.workspace.preferences.fontSize, 19)
        XCTAssertFalse(store.workspace.preferences.analytics)
        XCTAssertFalse(store.workspace.preferences.globalHotkey)
        XCTAssertFalse(store.workspace.preferences.restoreTabs)
        var host = TabbyNative.Host(); host.name = "fixture"; host.address = "localhost"
        store.workspace.hosts = [host]; store.save()
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.workspace.hosts, [host])
        loaded.workspace.preferences.language = "zh-CN"; loaded.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("backup").path))
    }
    @MainActor func testSFTPEntryKeepsFilesWorkspaceAndReusesConnectedHost() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "fixture"; host.address = "example.invalid"
        store.openFiles(host)
        XCTAssertEqual(store.section, "sftp")
        XCTAssertEqual(store.sessions.count, 1)
        let remote = store.sessions[0]; remote.connected = true
        store.connect() // A different tab is active when the user selects the SSH host.
        store.openFiles(host)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.activeSession, remote.id)
        XCTAssertEqual(store.section, "sftp")
        XCTAssertEqual(store.workspace.preferences.fontName, "Menlo")
        XCTAssertEqual(store.workspace.preferences.foreground, "#00CC74")
    }
    @MainActor func testSFTPEntryConnectsAndListsLoopbackServer() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "fixture"; host.address = "127.0.0.1"; host.port = info["port"] as! Int
        host.username = "test"; host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        store.openFiles(host)
        let session = try XCTUnwrap(store.sessions.first)
        defer { session.disconnect() }
        _ = session.makeView()
        for _ in 0..<200 {
            if session.connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(session.connected, session.status)
        let files = FileManagerModel(session: session)
        defer { files.close() }
        await files.open()
        let remote = try XCTUnwrap(files.remote, files.status)
        XCTAssertTrue(remote.entries.contains { $0.name == "client-key" })
        store.section = "hosts"
        store.openFiles(host)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.activeSession, session.id)
        XCTAssertEqual(store.section, "sftp")
    }
    @MainActor func testImportDeduplicatesAndExcludesLocalProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tabby.yaml")
        try """
        profiles:
          - name: example
            type: ssh
            options:
              host: example.invalid
              port: 2222
              user: tester
          - name: local
            type: local
        """.write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        try store.importTabby(file); try store.importTabby(file)
        XCTAssertEqual(store.workspace.hosts.count, 1)
        XCTAssertEqual(store.workspace.hosts[0].port, 2222)
    }
    @MainActor func testLocalRecursiveTransferAndZeroByteFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); let dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 700000).write(to: source.appendingPathComponent("big.bin"))
        try Data().write(to: source.appendingPathComponent("empty"))
        let local = LocalFiles(); let entry = try await local.stat(source.path)
        let queue = TransferQueue()
        let job = TransferJob(entry: entry, destination: dest.path, source: local, target: local, direction: "test")
        try await queue.transfer(entry, to: dest.path, job: job)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("big.bin")), Data(repeating: 42, count: 700000))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("empty")).count, 0)
        XCTAssertEqual(job.completed, 700000)
    }
    @MainActor func testCancelledTransferPreservesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input"); try Data([1, 2]).write(to: file)
        let backend = LocalFiles(); let entry = try await backend.stat(file.path)
        let queue = TransferQueue(); let job = TransferJob(entry: entry, destination: root.appendingPathComponent("output").path, source: backend, target: backend, direction: "test")
        job.cancelled = true
        do { try await queue.transfer(entry, to: job.destination, job: job); XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destination))
    }
    @MainActor func testPaneHiddenFilesAndNavigationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".secret")); try Data().write(to: root.appendingPathComponent("visible"))
        let pane = FilePane(path: root.path, backend: LocalFiles()); await pane.navigate(root.path)
        XCTAssertEqual(pane.visible.map(\.name), ["visible"])
        pane.showHidden = true; XCTAssertEqual(pane.visible.count, 2)
        await pane.navigate(root.appendingPathComponent("missing").path)
        XCTAssertEqual(pane.path, root.path); XCTAssertNotNil(pane.error)
    }
    @MainActor func testRefreshingDirectoryPreservesValidSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt"); let second = root.appendingPathComponent("second.txt")
        try Data([1]).write(to: first); try Data([2]).write(to: second)
        let pane = FilePane(path: root.path, backend: LocalFiles()); await pane.navigate(root.path)
        pane.selected = [first.path, second.path]
        await pane.navigate(root.path, record: false)
        XCTAssertEqual(pane.selected, [first.path, second.path])
        try FileManager.default.removeItem(at: first)
        await pane.navigate(root.path, record: false)
        XCTAssertEqual(pane.selected, [second.path])
        await pane.navigate(folder.path)
        XCTAssertTrue(pane.selected.isEmpty)
    }
    @MainActor func testRealSSHAndSFTP() async throws {
        guard let infoPath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Set TABBY_TEST_SERVER for loopback integration") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: infoPath))) as! [String: Any]
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
        let key = try NIOSSHPublicKey(openSSHPublicKey: info["hostKey"] as! String)
        var settings = SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .trustedKeys([key]))
        settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
        let client = try await SSHClient.connect(to: settings)
        do {
            let output = try await client.executeCommand("printf SSH_OK")
            XCTAssertEqual(String(buffer: output), "SSH_OK")
            let sftp = try await client.openSFTP(); let remote = RemoteFiles(sftp)
            let directory = "/integration-" + UUID().uuidString
            try await remote.mkdir(directory)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("unicode-中文.bin")
            let bytes = Data(repeating: 79, count: 800000); try bytes.write(to: source)
            let local = LocalFiles(); let queue = TransferQueue(); let entry = try await local.stat(source.path)
            let destination = try remoteJoin(directory, entry.name)
            let upload = TransferJob(entry: entry, destination: destination, source: local, target: remote, direction: "upload")
            try await queue.transfer(entry, to: destination, job: upload)
            let listing = try await remote.list(directory); XCTAssertEqual(listing.count, 1); XCTAssertEqual(listing[0].size, UInt64(bytes.count))
            let downloaded = root.appendingPathComponent("downloaded")
            let download = TransferJob(entry: listing[0], destination: downloaded.path, source: remote, target: local, direction: "download")
            try await queue.transfer(listing[0], to: downloaded.path, job: download)
            XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
            let renamed = directory + "/renamed"
            try await remote.rename(destination, renamed); try await remote.chmod(renamed, 0o640)
            let attributes = try await remote.stat(renamed); XCTAssertEqual(attributes.permissions, 0o640)
            try await remote.delete(try await remote.stat(directory))
            try await sftp.close(); try await client.close()
        } catch { try? await client.close(); throw error }
    }
    @MainActor func testPublicKeyPTYAndResize() async throws {
        guard let infoPath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: infoPath))) as! [String: Any]
        let key = try NIOSSHPublicKey(openSSHPublicKey: info["hostKey"] as! String)
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: String(contentsOfFile: info["clientKey"] as! String))
        let client = try await SSHClient.connect(to: SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .ed25519(username: "test", privateKey: privateKey) }, hostKeyValidator: .trustedKeys([key])))
        do {
            var received = ""
            do { try await client.withPTY(.init(wantReply: true, term: "xterm-256color", terminalCharacterWidth: 80, terminalRowHeight: 24, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { output, input in
                try await input.changeSize(cols: 120, rows: 40, pixelWidth: 0, pixelHeight: 0)
                try await input.write(ByteBuffer(string: "printf PTY_OK\nexit\n"))
                for try await event in output {
                    switch event { case .stdout(let bytes), .stderr(let bytes): received += String(buffer: bytes) }
                }
            }
            } catch ChannelError.alreadyClosed { /* Citadel closes an already-ended PTY channel. */ }
            XCTAssertTrue(received.contains("PTY_OK"))
            let jump = try await client.jump(to: SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .ed25519(username: "test", privateKey: privateKey) }, hostKeyValidator: .trustedKeys([key])))
            let jumpOutput = try await jump.executeCommand("printf JUMP_OK")
            XCTAssertEqual(String(buffer: jumpOutput), "JUMP_OK")
            let jumpSFTP = try await jump.openSFTP()
            let jumpDirectory = "/jump-" + UUID().uuidString
            try await jumpSFTP.createDirectory(atPath: jumpDirectory)
            try await jumpSFTP.rmdir(at: jumpDirectory)
            try await jumpSFTP.close(); try await jump.close()
            try await client.close()
        } catch { try? await client.close(); throw error }
    }
    @MainActor func testChangedHostKeyRejected() async throws {
        guard let infoPath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: infoPath))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let endpoint = "127.0.0.1:\(info["port"] as! Int)"
        store.workspace.trustedKeys[endpoint] = "different-server-key"
        let settings = SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .custom(HostKeyCheck(endpoint: endpoint, store: store)))
        do { let client = try await SSHClient.connect(to: settings); try? await client.close(); XCTFail("Changed host key must reject connection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Host key changed"), error.localizedDescription) }
    }

    @MainActor func testCancelDuringTransferCleansTemporaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin"); let destination = root.appendingPathComponent("destination.bin")
        try Data(repeating: 99, count: 16 * 1024 * 1024).write(to: source)
        let backend = LocalFiles(); let entry = try await backend.stat(source.path)
        let queue = TransferQueue(); let job = TransferJob(entry: entry, destination: destination.path, source: backend, target: backend, direction: "test")
        let operation = Task { try await queue.transfer(entry, to: destination.path, job: job) }
        while job.completed == 0 { await Task.yield() }
        job.cancelled = true
        do { try await operation.value; XCTFail("Expected mid-transfer cancellation") } catch is CancellationError {} catch { throw error }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
    }
    @MainActor func testCorruptWorkspaceIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json"); let original = Data("broken configuration".utf8)
        try original.write(to: url)
        let store = AppStore(fileURL: url); store.save()
        XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertNotNil(store.error)
    }
    @MainActor func testSplitSessionLifecycle() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.connect(); let first = try XCTUnwrap(store.activeSession)
        store.split(); let second = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(store.splitPartners[first], second); XCTAssertEqual(store.splitPartners[second], first)
        store.close(second); XCTAssertTrue(store.splitPartners.isEmpty); XCTAssertEqual(store.activeSession, first)
        store.close(first); XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor func testVaultGroupsAndSharedIdentityPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let store = AppStore(fileURL: url)
        var identity = VaultCredential(); identity.name = "Test identity"
        defer { try? Secrets.save("", id: identity.id) }
        try store.saveCredential(identity, secret: "fixture-secret")
        var host = TabbyNative.Host(); host.name = "fixture"; host.address = "example.invalid"; host.group = "Old"; host.credentialID = identity.id
        try store.upsert(host, secret: "must-not-overwrite-shared")
        XCTAssertEqual(try Secrets.readChecked(identity.id), "fixture-secret")
        try store.renameGroup("Old", to: "New")
        XCTAssertEqual(store.workspace.hosts.first?.group, "New")
        try store.duplicateHost(host)
        XCTAssertEqual(store.workspace.hosts.count, 2)
        let loaded = AppStore(fileURL: url)
        XCTAssertEqual(loaded.workspace.credentials, [identity])
        XCTAssertEqual(loaded.workspace.hosts.first?.credentialID, identity.id)
        store.dissolveGroup("New")
        XCTAssertEqual(store.workspace.hosts.count, 2)
        XCTAssertEqual(store.workspace.hosts.first?.group, "")
        try store.removeCredential(identity.id)
        XCTAssertTrue(store.workspace.credentials.isEmpty)
        for entry in store.workspace.hosts {
            XCTAssertNil(entry.credentialID)
            XCTAssertEqual(try Secrets.readChecked(entry.id), "fixture-secret")
            try Secrets.save("", id: entry.id)
        }
    }

    func testCredentialPersistsAndUpdatesByHostID() throws {
        let id = UUID()
        defer { try? Secrets.save("", id: id) }
        XCTAssertEqual(try Secrets.readChecked(id), "")
        try Secrets.save("test-only-first", id: id)
        XCTAssertEqual(try Secrets.readChecked(id), "test-only-first")
        try Secrets.save("test-only-updated", id: id)
        XCTAssertEqual(try Secrets.readChecked(id), "test-only-updated")
        XCTAssertEqual(try Secrets.readChecked(UUID()), "")
        try Secrets.save("", id: id)
        XCTAssertEqual(try Secrets.readChecked(id), "")
    }

    @MainActor func testLoadingPreservesOriginalThemeAndWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        var workspace = Workspace(); var host = TabbyNative.Host(); host.name = "existing"; host.address = "example.invalid"; workspace.hosts = [host]
        workspace.preferences.foreground = "#00CC74"; workspace.preferences.background = "#1e1f29"; workspace.preferences.fontSize = 24
        let original = try JSONEncoder().encode(workspace); try original.write(to: url)
        let store = AppStore(fileURL: url)
        XCTAssertEqual(store.workspace.preferences.foreground, Palette.terminalForeground)
        XCTAssertEqual(store.workspace.preferences.background, Palette.terminalBackground)
        XCTAssertEqual(store.workspace.preferences.fontSize, 24)
        XCTAssertEqual(store.workspace.hosts, [host])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testGroupsPersistAndLegacyDocumentsStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json"); let store = AppStore(fileURL: url)
        try store.addGroup("Production"); XCTAssertThrowsError(try store.addGroup("Production")); XCTAssertThrowsError(try store.addGroup(" "))
        XCTAssertEqual(AppStore(fileURL: url).groups, ["Production"])
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "groups"); try JSONSerialization.data(withJSONObject: json).write(to: url)
        let legacy = AppStore(fileURL: url); XCTAssertNil(legacy.error); XCTAssertTrue(legacy.groups.isEmpty)
    }
    func testQuickSSHInputRejectsCommandOptions() throws {
        XCTAssertEqual(parseQuickHost("ssh root@example.invalid -p 2222")?.port, 2222)
        XCTAssertEqual(parseQuickHost("tester@example.invalid")?.username, "tester")
        for command in ["ssh root@example.invalid -p 99999", "ssh root@example.invalid -o ProxyCommand=anything", "ssh root@", "search words", "user@host/path"] { XCTAssertNil(parseQuickHost(command)) }
    }

}
