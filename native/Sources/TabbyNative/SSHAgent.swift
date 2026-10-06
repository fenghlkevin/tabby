import Foundation
import Darwin
import Citadel
import NIO
import NIOSSH
import Crypto

struct AgentIdentity: Identifiable {
    let blob: Data
    let comment: String
    let algorithm: String
    let publicBytes: Data
    var fingerprint: String { "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    var id: String { fingerprint }
}
struct AgentPacket {
    var data: Data
    var cursor = 0
    mutating func byte() throws -> UInt8 { guard cursor < data.count else { throw AgentWire.failure }; defer { cursor += 1 }; return data[cursor] }
    mutating func uint32() throws -> UInt32 { guard data.count - cursor >= 4 else { throw AgentWire.failure }; var value: UInt32 = 0; for _ in 0..<4 { value = value << 8 | UInt32(try byte()) }; return value }
    mutating func string() throws -> Data { let count = Int(try uint32()); guard count <= data.count - cursor else { throw AgentWire.failure }; defer { cursor += count }; return data.subdata(in: cursor..<cursor + count) }
    mutating func put(_ value: UInt32) { data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    mutating func put(_ value: Data) { put(UInt32(value.count)); data.append(value) }
}
enum AgentWire {
    static var failure: Error { AppFailure.message("Invalid SSH Agent response / SSH Agent 响应无效") }
    static func socketPath(_ host: Host? = nil) throws -> String {
        let path = host?.agentSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = path.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
        guard value.hasPrefix("/"), value.utf8.count < 104, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppFailure.message("SSH_AUTH_SOCK is unavailable. Choose a local agent socket in host settings. / 未找到 SSH_AUTH_SOCK，请在主机设置中指定本机 Agent Socket。")
        }
        return value
    }
    static func request(_ payload: Data, socketPath: String) throws -> Data {
        guard socketPath.hasPrefix("/"), socketPath.utf8.count < 104, payload.count <= 1024 * 1024 else { throw failure }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure }; defer { Darwin.close(fd) }
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var deadline = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS else { throw AppFailure.message("Cannot connect to SSH Agent / 无法连接本机 SSH Agent") }
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&event, 1, 4000) > 0 else { throw AppFailure.message("SSH Agent connection timed out / SSH Agent 连接超时") }
            var socketError: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { throw failure }
        }
        _ = fcntl(fd, F_SETFL, flags)
        var frame = AgentPacket(data: Data()); frame.put(UInt32(payload.count)); frame.data.append(payload)
        try frame.data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AppFailure.message("SSH Agent write failed or timed out / SSH Agent 写入失败或超时") }; sent += count
            }
        }
        func read(_ size: Int) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: size), received = 0
            try bytes.withUnsafeMutableBytes { raw in
                while received < size {
                    let count = Darwin.read(fd, raw.baseAddress!.advanced(by: received), size - received)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw AppFailure.message("SSH Agent read failed or timed out / SSH Agent 读取失败或超时") }; received += count
                }
            }; return Data(bytes)
        }
        var header = AgentPacket(data: try read(4)); let size = Int(try header.uint32())
        guard (1...1024 * 1024).contains(size) else { throw failure }; return try read(size)
    }
    static func identities(path: String) throws -> [AgentIdentity] { try decodeIdentities(request(Data([11]), socketPath: path)) }
    static func decodeIdentities(_ data: Data) throws -> [AgentIdentity] {
        var packet = AgentPacket(data: data); guard try packet.byte() == 12 else { throw failure }
        let count = try packet.uint32(); guard count <= 64 else { throw failure }
        var identities: [AgentIdentity] = []
        for _ in 0..<count {
            let blob = try packet.string(), comment = String(decoding: try packet.string(), as: UTF8.self)
            var key = AgentPacket(data: blob); let algorithm = String(decoding: try key.string(), as: UTF8.self)
            if algorithm == "ssh-rsa" {
                SSHCertificates.registerRSA()
                let exponent = try key.string(), modulus = try key.string()
                guard !exponent.isEmpty, modulus.count >= 256, modulus.count <= 1025, key.cursor == blob.count else { throw failure }
                identities.append(.init(blob: blob, comment: String(comment.prefix(200)), algorithm: algorithm, publicBytes: blob))
            } else if algorithm == "ssh-ed25519" {
                let publicBytes = try key.string(); guard publicBytes.count == 32, key.cursor == blob.count else { throw failure }
                identities.append(.init(blob: blob, comment: String(comment.prefix(200)), algorithm: algorithm, publicBytes: publicBytes))
            }
        }
        guard packet.cursor == data.count else { throw failure }; return identities
    }
    static func sign(_ data: Data, identity: AgentIdentity, path: String, sha256: Bool = false) throws -> Data {
        var packet = AgentPacket(data: Data([13])); packet.put(identity.blob); packet.put(data); packet.put(identity.algorithm == "ssh-rsa" ? UInt32(sha256 ? 2 : 4) : UInt32(0))
        var reply = AgentPacket(data: try request(packet.data, socketPath: path))
        guard try reply.byte() == 14 else { throw AppFailure.message("SSH Agent declined signing. Unlock or approve the key in your agent. / SSH Agent 拒绝签名，请解锁或在 Agent 中批准使用密钥。") }
        var signature = AgentPacket(data: try reply.string())
        let algorithm = String(decoding: try signature.string(), as: UTF8.self)
        guard algorithm == (identity.algorithm == "ssh-rsa" ? (sha256 ? "rsa-sha2-256" : "rsa-sha2-512") : "ssh-ed25519") else { throw failure }
        let value = try signature.string()
        guard signature.cursor == signature.data.count, reply.cursor == reply.data.count else { throw failure }
        if identity.algorithm == "ssh-rsa" {
            let key = try AgentRSAPrivate.publicKey(identity)
            let signature: NIOSSHSignatureProtocol = sha256 ? Insecure.RSA.SHA256Signature(rawRepresentation: value) : Insecure.RSA.Signature(rawRepresentation: value)
            guard key.isValidSignature(signature, for: data) else { throw failure }
        } else {
            guard value.count == 64, try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicBytes).isValidSignature(value, for: data) else { throw failure }
        }
        return value
    }
}
struct AgentEdSignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "ssh-ed25519"
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation) }
    static func read(from buffer: inout ByteBuffer) throws -> Self { guard let length: UInt32 = buffer.readInteger(), length == 64, let bytes = buffer.readBytes(length: 64) else { throw AgentWire.failure }; return .init(rawRepresentation: Data(bytes)) }
}
struct AgentEdPublic: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ssh-ed25519"
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation) }
    static func read(from buffer: inout ByteBuffer) throws -> Self { guard let count: UInt32 = buffer.readInteger(), count == 32, let bytes = buffer.readBytes(length: 32) else { throw AgentWire.failure }; return .init(rawRepresentation: Data(bytes)) }
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation) else { return false }; return key.isValidSignature(signature.rawRepresentation, for: data)
    }
}
struct AgentEdPrivate: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "ssh-ed25519"
    let identity: AgentIdentity
    let path: String
    var publicKey: NIOSSHPublicKeyProtocol { AgentEdPublic(rawRepresentation: identity.publicBytes) }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol { AgentEdSignature(rawRepresentation: try AgentWire.sign(Data(data), identity: identity, path: path)) }
}
struct AgentRSAPrivate: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "ssh-rsa"
    let identity: AgentIdentity
    let path: String
    let sha256: Bool
    let parsedPublicKey: Insecure.RSA.PublicKey
    init(identity: AgentIdentity, path: String, sha256: Bool) throws { self.identity = identity; self.path = path; self.sha256 = sha256; parsedPublicKey = try Self.publicKey(identity) }
    static func publicKey(_ identity: AgentIdentity) throws -> Insecure.RSA.PublicKey {
        var buffer = ByteBuffer(bytes: identity.blob)
        guard let count: UInt32 = buffer.readInteger(), buffer.readBytes(length: Int(count)) == Array("ssh-rsa".utf8) else { throw AgentWire.failure }
        return try Insecure.RSA.PublicKey.read(from: &buffer)
    }
    var publicKey: NIOSSHPublicKeyProtocol { parsedPublicKey }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let value = try AgentWire.sign(Data(data), identity: identity, path: path, sha256: sha256)
        return sha256 ? Insecure.RSA.SHA256Signature(rawRepresentation: value) : Insecure.RSA.Signature(rawRepresentation: value)
    }
}
final class AgentAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let path: String
    let fingerprint: String?
    let certificatePath: String?
    let authorityPath: String?
    private var keys: [(AgentIdentity, Bool)]?
    init(username: String, path: String, fingerprint: String?, certificatePath: String? = nil, authorityPath: String? = nil) {
        self.username = username; self.path = path; self.fingerprint = fingerprint; self.certificatePath = certificatePath; self.authorityPath = authorityPath
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey) else { nextChallengePromise.fail(AgentWire.failure); return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if self.keys == nil {
                    self.keys = try AgentWire.identities(path: self.path).filter { self.fingerprint == nil || self.fingerprint == $0.fingerprint }.flatMap { key in key.algorithm == "ssh-rsa" ? [(key, false), (key, true)] : [(key, false)] }
                }
                guard let (identity, sha256) = self.keys?.first else { throw AppFailure.message("No accepted identity in SSH Agent / SSH Agent 中没有可用身份") }
                self.keys?.removeFirst()
                let key = identity.algorithm == "ssh-rsa" ? NIOSSHPrivateKey(custom: try AgentRSAPrivate(identity: identity, path: self.path, sha256: sha256)) : NIOSSHPrivateKey(custom: AgentEdPrivate(identity: identity, path: self.path))
                let certificate = try SSHCertificates.read(self.certificatePath, authorityPath: self.authorityPath, username: self.username, key: key.publicKey)
                let algorithm = identity.algorithm == "ssh-rsa" ? (sha256 ? "rsa-sha2-256" : "rsa-sha2-512") + (certificate == nil ? "" : "-cert-v01@openssh.com") : nil
                nextChallengePromise.succeed(.init(username: self.username, serviceName: "", offer: .privateKey(.init(privateKey: key, algorithm: algorithm, certificate: certificate))))
            } catch { nextChallengePromise.fail(error) }
        }
    }
}
