import XCTest
@testable import TabbyNative
import Citadel
import Crypto

final class PrivateKeyTests: XCTestCase {
    private func generateKey(at root: URL, type: String = "ed25519", passphrase: String = "") throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(UUID().uuidString)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", type, "-a", "4", "-N", passphrase, "-f", path.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppFailure.message("Fixture key generation failed") }
        return try String(contentsOf: path, encoding: .utf8)
    }

    func testPastedPrivateKeyFormatsAndEncryptedPassphrase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ed25519 = try generateKey(at: root)
        let pasted = " \n" + ed25519.replacingOccurrences(of: "\n", with: "\r\n") + "\t "
        XCTAssertNoThrow(try PrivateKeys.authentication(pasted, passphrase: "", username: "test", chinese: false))
        let rsa = try generateKey(at: root, type: "rsa")
        XCTAssertNoThrow(try PrivateKeys.authentication(rsa, passphrase: "", username: "test", chinese: false))
        let encrypted = try generateKey(at: root, passphrase: "fixture-passphrase")
        XCTAssertNoThrow(try PrivateKeys.authentication(encrypted, passphrase: "fixture-passphrase", username: "test", chinese: false))
        XCTAssertThrowsError(try PrivateKeys.authentication(encrypted, passphrase: "wrong", username: "test", chinese: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("口令"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-passphrase"))
            XCTAssertFalse(error.localizedDescription.contains("BEGIN OPENSSH"))
        }
        XCTAssertThrowsError(try PrivateKeys.authentication("ssh-ed25519 public-only", passphrase: "", username: "test", chinese: false))
        XCTAssertThrowsError(try PrivateKeys.authentication("", passphrase: "", username: "test", chinese: false))
    }

    @MainActor func testTextCredentialPersistsInKeychainWithoutWorkspaceKeyMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var credential = VaultCredential(); credential.name = "fixture"; credential.auth = "key"; credential.keySource = "text"
        defer { try? Secrets.saveCredential(Secrets.Value(), id: credential.id) }
        let text = try generateKey(at: root, passphrase: "fixture-passphrase")
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        try store.saveCredential(credential, secret: "fixture-passphrase", privateKey: text)
        let expected = Data(PrivateKeys.normalize(text).utf8)
        XCTAssertTrue(SHA256.hash(data: Data(try Secrets.readPrivateKey(credential.id).utf8)) == SHA256.hash(data: expected), "Keychain must preserve key bytes")
        XCTAssertEqual(try Secrets.readChecked(credential.id), "fixture-passphrase")
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.workspace.credentials, [credential])
        try loaded.saveCredential(credential, secret: "fixture-passphrase") // Unrelated edits preserve saved text.
        for url in [store.fileURL, store.fileURL.appendingPathExtension("backup")] {
            let json = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(json.contains("BEGIN OPENSSH")); XCTAssertFalse(json.contains("fixture-passphrase"))
        }
        XCTAssertThrowsError(try loaded.saveCredential(credential, secret: "changed", privateKey: "invalid"))
        XCTAssertEqual(try Secrets.readChecked(credential.id), "fixture-passphrase")
        XCTAssertTrue(SHA256.hash(data: Data(try Secrets.readPrivateKey(credential.id).utf8)) == SHA256.hash(data: expected), "Invalid input must preserve saved key")
        credential.keySource = "file"; credential.keyPath = "/fixture/key"
        try loaded.saveCredential(credential, secret: "fixture-passphrase", privateKey: text)
        XCTAssertTrue(try Secrets.readPrivateKey(credential.id).isEmpty)
        XCTAssertEqual(try Secrets.readChecked(credential.id), "fixture-passphrase")
    }

    @MainActor func testTextKeysSurviveDuplicationAndSharedIdentityRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var credential = VaultCredential(); credential.name = "fixture"; credential.auth = "key"; credential.keySource = "text"
        let text = try generateKey(at: root)
        defer {
            try? Secrets.saveCredential(Secrets.Value(), id: credential.id)
            for host in store.workspace.hosts { try? Secrets.saveCredential(Secrets.Value(), id: host.id) }
        }
        try store.saveCredential(credential, secret: "", privateKey: text)
        var linked = TabbyNative.Host(); linked.address = "example.invalid"; linked.credentialID = credential.id
        try store.upsert(linked, secret: "ignored", privateKey: "ignored")
        XCTAssertTrue(try Secrets.readChecked(linked.id).isEmpty)
        try store.removeCredential(credential.id)
        let independent = try XCTUnwrap(store.workspace.hosts.first)
        XCTAssertNil(independent.credentialID); XCTAssertEqual(independent.keySource, "text")
        XCTAssertTrue(try Secrets.readPrivateKey(credential.id).isEmpty)
        XCTAssertFalse(try Secrets.readPrivateKey(independent.id).isEmpty)
        try store.duplicateHost(independent)
        let copy = try XCTUnwrap(store.workspace.hosts.last)
        XCTAssertNotEqual(copy.id, independent.id)
        XCTAssertTrue(SHA256.hash(data: Data(try Secrets.readPrivateKey(copy.id).utf8)) == SHA256.hash(data: Data(try Secrets.readPrivateKey(independent.id).utf8)), "Copies must retain private keys")
        try store.deleteHost(copy.id)
        XCTAssertTrue(try Secrets.readPrivateKey(copy.id).isEmpty)
        var passwordHost = independent; passwordHost.auth = "password"
        try store.upsert(passwordHost, secret: "fixture-password")
        XCTAssertTrue(try Secrets.readPrivateKey(independent.id).isEmpty)
        XCTAssertEqual(try Secrets.readChecked(independent.id), "fixture-password")
    }

    @MainActor func testFailedWorkspaceSaveRollsBackKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try generateKey(at: root)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let store = AppStore(fileURL: blocked.appendingPathComponent("workspace.json"))
        var credential = VaultCredential(); credential.name = "fixture"; credential.auth = "key"; credential.keySource = "text"
        defer { try? Secrets.saveCredential(Secrets.Value(), id: credential.id) }
        try Secrets.save("existing-secret", id: credential.id)
        XCTAssertThrowsError(try store.saveCredential(credential, secret: "new-secret", privateKey: text))
        XCTAssertEqual(try Secrets.readChecked(credential.id), "existing-secret")
        XCTAssertTrue(try Secrets.readPrivateKey(credential.id).isEmpty)
        XCTAssertTrue(store.workspace.credentials.isEmpty)
    }

    func testLegacyFileKeyMetadataDecodesWithoutKeySource() throws {
        var host = TabbyNative.Host(); host.auth = "key"; host.keyPath = "/fixture/key"
        var credential = VaultCredential(); credential.auth = "key"; credential.keyPath = "/fixture/shared-key"
        let hostData = try JSONEncoder().encode(host); let credentialData = try JSONEncoder().encode(credential)
        XCTAssertFalse(String(decoding: hostData, as: UTF8.self).contains("keySource"))
        XCTAssertNil(try JSONDecoder().decode(TabbyNative.Host.self, from: hostData).keySource)
        XCTAssertNil(try JSONDecoder().decode(VaultCredential.self, from: credentialData).keySource)
    }

    @MainActor func testPastedPrivateKeySSHAndSFTP() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyFile = root.appendingPathComponent("encrypted-key")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: info["clientKey"] as! String), to: keyFile)
        let encrypt = Process(); encrypt.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        encrypt.arguments = ["-q", "-p", "-a", "4", "-P", "", "-N", "fixture-passphrase", "-f", keyFile.path]
        encrypt.standardOutput = Pipe(); encrypt.standardError = Pipe(); try encrypt.run(); encrypt.waitUntilExit()
        XCTAssertEqual(encrypt.terminationStatus, 0)
        var credential = VaultCredential(); credential.name = "fixture"; credential.username = "test"; credential.auth = "key"; credential.keySource = "text"
        var host = TabbyNative.Host(); host.address = "127.0.0.1"; host.port = info["port"] as! Int; host.credentialID = credential.id
        defer { try? Secrets.saveCredential(Secrets.Value(), id: credential.id); try? Secrets.saveCredential(Secrets.Value(), id: host.id) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        try store.saveCredential(credential, secret: "fixture-passphrase", privateKey: String(contentsOf: keyFile, encoding: .utf8))
        try store.upsert(host, secret: "ignored")
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String; store.save()
        // Prove text keys do not depend on the source file, and survive app reload.
        try FileManager.default.removeItem(at: keyFile)
        let loaded = AppStore(fileURL: store.fileURL)
        let session = TerminalSession(host: host, store: loaded)
        let client = try await SSHClient.connect(to: session.settings(for: host))
        do {
            let output = try await client.executeCommand("printf pasted-key-ok")
            XCTAssertEqual(output.getString(at: 0, length: output.readableBytes), "pasted-key-ok")
            let sftp = try await client.openSFTP()
            let entries = try await sftp.listDirectory(atPath: ".")
            XCTAssertTrue(entries.flatMap(\.components).contains { $0.filename == "client-key" })
            try await sftp.close(); try await client.close()
        } catch { try? await client.close(); throw error }
        try loaded.removeCredential(credential.id)
        host = try XCTUnwrap(loaded.workspace.hosts.first)
        let independent = try await SSHClient.connect(to: session.settings(for: host))
        try await independent.close()
    }
}
