import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH

enum SSHCertificates {
    static func read(_ path: String?, authorityPath: String?, username: String, key: NIOSSHPublicKey? = nil) throws -> NIOSSHCertifiedPublicKey? {
        guard let path, !path.isEmpty else { return nil }
        guard let authorityPath, !authorityPath.isEmpty else { throw AppFailure.message("Choose the trusted CA public key / 请选择受信 CA 公钥") }
        guard let certificate = NIOSSHCertifiedPublicKey(try publicKey(path)) else { throw AppFailure.message("Choose an OpenSSH user certificate / 请选择 OpenSSH 用户证书") }
        if let key, String(openSSHPublicKey: certificate.key) != String(openSSHPublicKey: key) { throw AppFailure.message("Certificate does not match the private key / 证书与私钥不匹配") }
        _ = try certificate.validate(principal: username, type: .user, allowedAuthoritySigningKeys: [try publicKey(authorityPath)], acceptableCriticalOptions: ["force-command", "source-address"])
        return certificate
    }
    static func publicKey(_ path: String) throws -> NIOSSHPublicKey {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AgentWire.failure }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        let data = try handle.read(upToCount: 128 * 1024 + 1) ?? Data()
        guard data.count <= 128 * 1024, let text = String(data: data, encoding: .utf8) else { throw AgentWire.failure }
        return try NIOSSHPublicKey(openSSHPublicKey: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func registerRSA() {
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.SHA256Signature.self)
    }
}

final class CertificateKeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: NIOSSHPrivateKey
    let rsa: Insecure.RSA.PrivateKey?
    let certificate: NIOSSHCertifiedPublicKey?
    private var attempts = 0
    init(username: String, key: NIOSSHPrivateKey, rsa: Insecure.RSA.PrivateKey? = nil, certificate: NIOSSHCertifiedPublicKey?) {
        self.username = username; self.key = key; self.rsa = rsa; self.certificate = certificate
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), attempts < (rsa == nil ? 1 : 2) else { nextChallengePromise.fail(AgentWire.failure); return }
        rsa?.useSHA256 = attempts == 1
        let algorithm = rsa.map { _ in (attempts == 0 ? "rsa-sha2-512" : "rsa-sha2-256") + (certificate == nil ? "" : "-cert-v01@openssh.com") }
        attempts += 1
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key, algorithm: algorithm, certificate: certificate))))
    }
}
