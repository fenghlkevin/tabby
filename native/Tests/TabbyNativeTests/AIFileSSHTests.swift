import XCTest
import Foundation
@testable import Citadel
import NIOSSH
import NIO
@testable import TabbyNative

/// Entire server is confined to this test's temporary directory.
private actor AIFileFixture: SFTPDelegate {
    let root: URL
    init(root: URL) { self.root = root }
    func path(_ remote: String) throws -> String {
        guard remote.hasPrefix("/"), !remote.split(separator: "/").contains("..") else { throw AppFailure.message("Fixture path invalid") }
        return root.appendingPathComponent(String(remote.dropFirst())).path
    }
    static func attributes(_ path: String) throws -> SFTPFileAttributes {
        let entry = try LocalFileMetadata.stat(path)
        var value = SFTPFileAttributes(size: entry.size, accessModificationTime: .init(accessTime: entry.modified, modificationTime: entry.modified))
        value.permissions = entry.permissions | (entry.directory ? 0o040000 : entry.symlink ? 0o120000 : 0o100000)
        return value
    }
    func fileAttributes(atPath remote: String, context: SSHContext) async throws -> SFTPFileAttributes { try Self.attributes(path(remote)) }
    func openFile(_ remote: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
        let file = try path(remote)
        if flags.contains(.create), !FileManager.default.fileExists(atPath: file) { guard FileManager.default.createFile(atPath: file, contents: Data()) else { throw AppFailure.message("Fixture create failed") } }
        let handle = flags.contains(.write) ? try FileHandle(forUpdating: URL(fileURLWithPath: file)) : try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        if flags.contains(.truncate) { try handle.truncate(atOffset: 0) }
        return Handle(path: file, file: handle)
    }
    func removeFile(_ remote: String, context: SSHContext) async throws -> SFTPStatusCode { try FileManager.default.removeItem(atPath: path(remote)); return .ok }
    func createDirectory(_ remote: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode { try FileManager.default.createDirectory(atPath: path(remote), withIntermediateDirectories: false); return .ok }
    func removeDirectory(_ remote: String, context: SSHContext) async throws -> SFTPStatusCode { try FileManager.default.removeItem(atPath: path(remote)); return .ok }
    func realPath(for remote: String, context: SSHContext) async throws -> [SFTPPathComponent] { [SFTPPathComponent(filename: remote, longname: remote, attributes: try Self.attributes(path(remote)))] }
    func openDirectory(atPath remote: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        let entries = try LocalFileMetadata.list(path(remote)).map { entry in SFTPPathComponent(filename: entry.name, longname: entry.name, attributes: try Self.attributes(entry.path)) }
        return Directory(entries: entries)
    }
    func setFileAttributes(to attributes: SFTPFileAttributes, atPath remote: String, context: SSHContext) async throws -> SFTPStatusCode { if let mode = attributes.permissions { try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: path(remote)) }; return .ok }
    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { throw AppFailure.message("Fixture symlinks disabled") }
    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw AppFailure.message("Fixture symlinks disabled") }
    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode { try FileManager.default.moveItem(atPath: path(oldPath), toPath: path(newPath)); return .ok }
    private actor Directory: SFTPDirectoryHandle {
        var entries: [SFTPPathComponent]
        init(entries: [SFTPPathComponent]) { self.entries = entries }
        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] { defer { entries = [] }; return entries.isEmpty ? [] : [SFTPFileListing(path: entries)] }
    }
    private actor Handle: SFTPFileHandle {
        let path: String
        let file: FileHandle
        init(path: String, file: FileHandle) { self.path = path; self.file = file }
        func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer { try file.seek(toOffset: offset); return ByteBuffer(bytes: try file.read(upToCount: Int(length)) ?? Data()) }
        func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode { try file.seek(toOffset: offset); try file.write(contentsOf: Data(data.readableBytesView)); return .ok }
        func close() async throws -> SFTPStatusCode { try file.close(); return .ok }
        func readFileAttributes() async throws -> SFTPFileAttributes { try AIFileFixture.attributes(path) }
        func setFileAttributes(to attributes: SFTPFileAttributes) async throws { if let mode = attributes.permissions { try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: path) } }
    }
}

@MainActor final class AIFileSSHTests: XCTestCase {
    func testRemoteConfigDiffConflictBackupAndConnectionReuse() async throws {
        final class Auth: NIOSSHServerUserAuthenticationDelegate {
            var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
            func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
                if case .password(let password) = request.request, request.username == "owned-fixture", password.password == "owned-password" { responsePromise.succeed(.success) } else { responsePromise.succeed(.failure) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-ai-sftp-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("service.conf"); try Data("upstream=broken\n".utf8).write(to: file)
        let server = try await SSHServer.host(host: "127.0.0.1", port: 0, hostKeys: [NIOSSHPrivateKey(p521Key: .init())], authenticationDelegate: Auth()); server.enableSFTP(withDelegate: AIFileFixture(root: root))
        let client = try await SSHClient.connect(host: "127.0.0.1", port: try XCTUnwrap(server.channel.localAddress?.port), authenticationMethod: .passwordBased(username: "owned-fixture", password: "owned-password"), hostKeyValidator: .acceptAnything(), reconnect: .never)
        let backend = RemoteFiles(try await client.openSFTP())
        defer { Task { try? await backend.close(); try? await client.close(); try? await server.close() } }
        let proposal = try await AIFileProposal(backend: backend, path: "/service.conf", find: "upstream=broken", replacement: "upstream=ready")
        let result = try await proposal.apply(); XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(result.output.contains("Backup: /service.conf.backup-")); XCTAssertTrue(client.isConnected)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "upstream=ready\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(String(proposal.edit.backupPath.dropFirst())), encoding: .utf8), "upstream=broken\n")
        let conflict = try await AIFileProposal(backend: backend, path: "/service.conf", find: "upstream=ready", replacement: "upstream=another")
        try Data("user-change\n".utf8).write(to: file)
        do { _ = try await conflict.apply(); XCTFail("Remote conflict must prevent write") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-change\n")
        try await backend.close(); let reopened = RemoteFiles(try await client.openSFTP()); let data = try await reopened.read("/service.conf", offset: 0, count: 100); XCTAssertEqual(data, Data("user-change\n".utf8)); try await reopened.close(); XCTAssertTrue(client.isConnected)
    }
}
