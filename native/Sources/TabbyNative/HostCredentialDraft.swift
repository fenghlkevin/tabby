import Foundation

/// Keeps an unsaved independent login intact while the editor previews shared
/// identities. Secrets stay in memory and are never copied into Workspace.
struct IndependentHostCredentialDraft {
    let username: String
    let auth: String
    let keyPath: String
    let keySource: String?
    let secret: String
    let privateKey: String

    init(host: Host, secret: String, privateKey: String) {
        username = host.username; auth = host.auth
        keyPath = host.keyPath; keySource = host.keySource
        self.secret = secret; self.privateKey = privateKey
    }

    func apply(to host: inout Host) {
        host.username = username; host.auth = auth
        host.keyPath = keyPath; host.keySource = keySource
    }
}
