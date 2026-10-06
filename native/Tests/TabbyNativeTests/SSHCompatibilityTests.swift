import XCTest
import Foundation
import Citadel
import NIO
import NIOSSH
@testable import TabbyNative

final class SSHCompatibilityTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["TABBY_OPENSSH_FIXTURE"] else { throw XCTSkip("Isolated OpenSSH fixture required") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }
    private func string(_ info: [String: Any], _ key: String) throws -> String { try XCTUnwrap(info[key] as? String) }
    private func connect(_ info: [String: Any], mode: String, auth: @escaping () throws -> SSHAuthenticationMethod) async throws -> SSHClient {
        SSHCertificates.registerRSA()
        let method = try auth()
        var settings = SSHClientSettings(host: "127.0.0.1", port: try XCTUnwrap(info["port" + mode] as? Int), authenticationMethod: { method }, hostKeyValidator: .trustedKeys([try NIOSSHPublicKey(openSSHPublicKey: string(info, "hostKey"))]))
        settings.connectTimeout = .seconds(5)
        return try await SSHClient.connect(to: settings)
    }
    func testRSAHostAndClientSHA512AndSHA256FallbackWithSFTP() async throws {
        let info = try fixture(), username = try string(info, "username"), key = try String(contentsOfFile: string(info, "rsaKey"), encoding: .utf8)
        for mode in ["512", "256"] {
            let client = try await connect(info, mode: mode) { try PrivateKeys.authentication(key, passphrase: "", username: username, chinese: false) }
            let result = try await client.executeCommand("printf AXON_RSA_OK")
            XCTAssertEqual(String(buffer: result), "AXON_RSA_OK")
            let sftp = try await client.openSFTP(); let entries = try await sftp.listDirectory(atPath: "/"); XCTAssertFalse(entries.isEmpty)
            try await client.close()
        }
    }
    func testEd25519AndRSAUserCertificatesAtBothSHA2Servers() async throws {
        let info = try fixture(), username = try string(info, "username"), ca = try string(info, "ca")
        for keyName in ["edKey", "rsaKey"] {
            let path = try string(info, keyName), key = try String(contentsOfFile: path, encoding: .utf8)
            for mode in ["512", "256"] {
                let client = try await connect(info, mode: mode) { try PrivateKeys.authentication(key, passphrase: "", username: username, chinese: false, certificatePath: path + "-cert.pub", authorityPath: ca) }
                let result = try await client.executeCommand("printf AXON_CERT_OK")
                XCTAssertEqual(String(buffer: result), "AXON_CERT_OK"); try await client.close()
            }
        }
    }
    func testCertificatesRejectUnknownCAWrongPrincipalAndMismatchedKey() throws {
        let info = try fixture(), path = try string(info, "edKey"), username = try string(info, "username"), ca = try string(info, "ca")
        SSHCertificates.registerRSA()
        XCTAssertThrowsError(try SSHCertificates.read(string(info, "expiredCertificate"), authorityPath: ca, username: username))
        XCTAssertThrowsError(try SSHCertificates.read(path + "-cert.pub", authorityPath: nil, username: username))
        XCTAssertThrowsError(try SSHCertificates.read(path + "-cert.pub", authorityPath: string(info, "wrongCA"), username: username))
        XCTAssertThrowsError(try SSHCertificates.read(path + "-cert.pub", authorityPath: ca, username: "wrong-user"))
        let other = try NIOSSHPublicKey(openSSHPublicKey: String(contentsOfFile: string(info, "rsaKey") + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertThrowsError(try SSHCertificates.read(path + "-cert.pub", authorityPath: ca, username: username, key: other))
    }
    func testServerCertificateRequiresTrustedCAMatchingHostAndValidSignature() async throws {
        let info = try fixture(), key = try String(contentsOfFile: string(info, "edKey"), encoding: .utf8), username = try string(info, "username")
        SSHCertificates.registerRSA()
        for caName in ["ca", "wrongCA"] {
            let auth = try PrivateKeys.authentication(key, passphrase: "", username: username, chinese: false)
            var settings = SSHClientSettings(host: "127.0.0.1", port: try XCTUnwrap(info["portcert"] as? Int), authenticationMethod: { auth }, hostKeyValidator: .custom(ValidatedCertificateOnly()))
            settings.trustedHostCAKeys = [try SSHCertificates.publicKey(string(info, caName))]
            do {
                let client = try await SSHClient.connect(to: settings)
                defer { Task { try? await client.close() } }
                XCTAssertEqual(caName, "ca", "Unknown host CA must be rejected")
                let output = try await client.executeCommand("printf HOST_CERT_OK")
                XCTAssertEqual(String(buffer: output), "HOST_CERT_OK")
            } catch { if caName == "ca" { throw error } }
        }
    }
    func testAgentRSAAuthenticationAndSelectedIdentityForwarding() async throws {
        let info = try fixture(), username = try string(info, "username")
        let root = URL(fileURLWithPath: "/private/tmp/af-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("a").path
        let agent = Process(); agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent"); agent.arguments = ["-D", "-a", socket]; agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run(); defer { agent.terminate(); agent.waitUntilExit() }
        for _ in 0..<50 { if FileManager.default.fileExists(atPath: socket) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let add = Process(); add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add"); add.arguments = [try string(info, "rsaKey"), try string(info, "edKey")]; add.environment = ProcessInfo.processInfo.environment.merging(["SSH_AUTH_SOCK": socket], uniquingKeysWith: { _, b in b }); add.standardOutput = FileHandle.nullDevice; add.standardError = FileHandle.nullDevice
        try add.run(); add.waitUntilExit(); XCTAssertEqual(add.terminationStatus, 0)
        let identities = try AgentWire.identities(path: socket), identity = try XCTUnwrap(identities.first { $0.algorithm == "ssh-rsa" })
        for mode in ["512", "256"] {
            let client = try await connect(info, mode: mode) { .custom(AgentAuthentication(username: username, path: socket, fingerprint: identity.fingerprint)) }
            client.enableAgentForwarding { channel in channel.pipeline.addHandler(AgentForwardingHandler(path: socket, identities: [identity])) }
            let result = try await client.executeCommand("ssh-add -L; code=$?; printf 'agent_exit=%s\\n' \"$code\"; true", mergeStreams: true)
            let output = String(buffer: result)
            XCTAssertTrue(output.contains("agent_exit=0"), output)
            XCTAssertTrue(output.contains(identity.blob.base64EncodedString())); XCTAssertFalse(output.contains("ssh-ed25519"))
            let knownHosts = root.appendingPathComponent("known_hosts")
            let port = try XCTUnwrap(info["port" + mode] as? Int)
            try ("[127.0.0.1]:\(port) " + string(info, "hostKey") + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)
            let nested = "ssh -F /dev/null -o BatchMode=yes -o IdentityFile=none -o CertificateFile=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=" + SnippetParameters.shellArgument(knownHosts.path) + " -o PubkeyAcceptedAlgorithms=rsa-sha2-" + mode + " -p \(port) " + SnippetParameters.shellArgument(username + "@127.0.0.1") + " 'printf FORWARDED_SIGN_OK'"
            let signed = try await client.executeCommand(nested)
            XCTAssertEqual(String(buffer: signed), "FORWARDED_SIGN_OK")
            try await client.close()
        }
        let policy = AgentForwardingPolicy(identities: [identity])
        XCTAssertThrowsError(try policy.request(Data([17]), path: socket))
        var unauthorized = AgentPacket(data: Data([13])); unauthorized.put(Data([1, 2, 3])); unauthorized.put(Data("sign".utf8)); unauthorized.put(UInt32(4))
        XCTAssertThrowsError(try policy.request(unauthorized.data, path: socket))
    }
}

private final class ValidatedCertificateOnly: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) { validationCompletePromise.fail(AgentWire.failure) }
    func validateHostCertificate(hostKey: NIOSSHPublicKey, certifiedKey: NIOSSHCertifiedPublicKey, validationCompletePromise: EventLoopPromise<Void>) { validationCompletePromise.succeed(()) }
}
