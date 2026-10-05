import Foundation
import Crypto

/// OpenSSH fingerprints hash the decoded key blob, never the displayed base64
/// text or comment. An unreadable record must not appear to have a valid hash.
struct KnownHostIdentity: Equatable {
    let algorithm: String
    let fingerprint: String

    init?(openSSHPublicKey: String) {
        let parts = openSSHPublicKey.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty else { return nil }
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // The first SSH string is the algorithm. Require its complete header
        // and nonempty key material, and reject mismatched displayed labels.
        guard length > 0, Int(length) < bytes.count - 4,
              let algorithm = String(bytes: bytes[4..<(4 + Int(length))], encoding: .utf8),
              algorithm == String(parts[0]) else { return nil }
        self.algorithm = algorithm
        fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

extension AppStore {
    /// Forgetting a server identity leaves saved hosts, credentials, and live
    /// connections alone. The next SSH handshake asks to verify it again.
    @discardableResult func removeKnownHost(_ endpoint: String) -> Bool {
        guard workspace.trustedKeys[endpoint] != nil else { return true }
        let previous = workspace
        workspace.trustedKeys.removeValue(forKey: endpoint)
        if save() { return true }
        // save() can also normalize preferences and recent targets.
        workspace = previous
        return false
    }
}
