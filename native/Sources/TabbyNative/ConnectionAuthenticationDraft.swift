import Foundation
import Citadel

/// A connection draft keeps every secret out of Workspace, including when the
/// user switches identities before deciding whether to remember the result.
struct ConnectionAuthenticationDraft {
    let originalHost: Host
    var host: Host
    var secret: String
    var privateKey: String
    var remember = false
    private var independent: IndependentHostCredentialDraft?
    private var sharedSnapshot: ConnectionAuthenticationSharedSnapshot?

    init(host: Host, material: Secrets.Value) {
        originalHost = host
        self.host = host
        secret = material.secret
        privateKey = material.privateKey
        if host.credentialID != nil { sharedSnapshot = .init(host: host, material: material) }
        if host.credentialID == nil {
            independent = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKey)
        }
    }

    mutating func selectCredential(_ id: UUID?, workspace: Workspace, chinese: Bool,
                                   read: (UUID) throws -> Secrets.Value = Secrets.readCredential) throws {
        guard id != host.credentialID else { return }
        var next = host
        var nextMaterial = Secrets.Value()
        if let id {
            next.credentialID = id
            next = try ConnectionValidation.host(next, workspace: workspace, chinese: chinese)
            nextMaterial = try read(id)
        } else {
            next.credentialID = nil
            if let independent { independent.apply(to: &next); nextMaterial = .init(secret: independent.secret, privateKey: independent.privateKey) }
            else {
                // Detaching an identity starts a separate, empty secret draft.
                next.auth = "password"; next.keySource = "text"; next.keyPath = ""
            }
        }
        // A failed Keychain read leaves the previous identity and unsaved input intact.
        if host.credentialID == nil {
            independent = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKey)
        }
        host = next; secret = nextMaterial.secret; privateKey = nextMaterial.privateKey
        sharedSnapshot = id == nil ? nil : .init(host: next, material: nextMaterial)
    }

    func canRemember(in workspace: Workspace) -> Bool {
        workspace.hosts.contains { $0.id == originalHost.id }
            || host.credentialID.map { id in workspace.credentials.contains { $0.id == id } } == true
    }

    func validatedResult(workspace: Workspace, chinese: Bool,
                         readFile: (String) throws -> String = { try String(contentsOfFile: NSString(string: $0).expandingTildeInPath, encoding: .utf8) }) throws -> ConnectionAuthenticationResult {
        // The authentication form never changes the endpoint or its jump route.
        var effective = originalHost
        effective.groupInheritance = nil
        effective.username = host.username; effective.auth = host.auth
        effective.keySource = host.keySource; effective.keyPath = host.keyPath
        effective.credentialID = nil
        effective = try ConnectionValidation.host(effective, workspace: workspace, chinese: chinese)
        if let id = host.credentialID {
            guard let credential = workspace.credentials.first(where: { $0.id == id }) else {
                throw AppFailure.message(chinese ? "共享凭据已不存在，请选择其他凭据。" : "The shared credential is unavailable. Choose another credential.")
            }
            // A shared identity owns its username and authentication method.
            guard effective.username == (try ConnectionValidation.username(credential.username, chinese: chinese)), effective.auth == credential.auth else {
                throw AppFailure.message(chinese ? "共享凭据已更改，请重新选择。" : "The shared credential changed. Select it again.")
            }
            effective.credentialID = id
        }
        let key: String
        if effective.auth == "key" {
            if effective.keySource == "text" { key = PrivateKeys.normalize(privateKey) }
            else { key = PrivateKeys.normalize(try readFile(effective.keyPath)) }
        } else {
            guard !secret.isEmpty else { throw AppFailure.message(chinese ? "请输入密码" : "Enter a password") }
            key = ""
        }
        let result = ConnectionAuthenticationResult(host: effective, secret: secret, privateKey: key,
                                                    remember: remember && canRemember(in: workspace), sharedSnapshot: sharedSnapshot)
        _ = try result.authentication(chinese: chinese)
        return result
    }
}

struct ConnectionAuthenticationResult {
    let host: Host
    let secret: String
    /// Also holds a file key while the current connection is alive. Persistence
    /// writes these bytes only when the explicitly selected source is text.
    let privateKey: String
    let remember: Bool
    var sharedSnapshot: ConnectionAuthenticationSharedSnapshot? = nil

    func authentication(chinese: Bool) throws -> SSHAuthenticationMethod {
        if host.auth == "key" {
            return try PrivateKeys.authentication(privateKey, passphrase: secret, username: host.username, chinese: chinese, certificatePath: host.certificatePath, authorityPath: host.certificateAuthorityPath)
        }
        guard !secret.isEmpty else { throw AppFailure.message(chinese ? "请输入密码" : "Enter a password") }
        return .passwordBased(username: host.username, password: secret)
    }
    var keychainValue: Secrets.Value {
        .init(secret: secret, privateKey: host.auth == "key" && host.keySource == "text" ? privateKey : "")
    }
}

struct ConnectionAuthenticationSharedSnapshot {
    let host: Host
    let material: Secrets.Value
    func matches(host current: Host, material currentMaterial: Secrets.Value) -> Bool {
        host.credentialID == current.credentialID && host.username == current.username && host.auth == current.auth
            && host.keySource == current.keySource && host.keyPath == current.keyPath
            && material.secret == currentMaterial.secret && material.privateKey == currentMaterial.privateKey
    }
}

struct ConnectionAuthenticationCacheEntry {
    let sourceHost: Host
    let sourceMaterial: Secrets.Value
    let result: ConnectionAuthenticationResult

    func matches(host: Host, material: Secrets.Value) -> Bool {
        sourceHost == host && sourceMaterial.secret == material.secret && sourceMaterial.privateKey == material.privateKey
    }
}

extension AppStore {
    /// Commit the shared identity, host association and Keychain together. A
    /// failed workspace save uses the same rollback as normal credential edits.
    func rememberConnectionAuthentication(_ result: ConnectionAuthenticationResult) throws {
        guard result.remember else { return }
        _ = try result.authentication(chinese: chinese)
        let savedIndex = workspace.hosts.firstIndex { $0.id == result.host.id }
        guard savedIndex != nil || result.host.credentialID != nil else {
            throw AppFailure.message(text("Save the host before remembering its credentials", "请先保存主机，再记住它的凭据"))
        }
        var updated = workspace
        var changes: [UUID: Secrets.Value] = [:]
        if let id = result.host.credentialID {
            guard let index = updated.credentials.firstIndex(where: { $0.id == id }) else {
                throw AppFailure.message(text("Shared credential no longer exists", "共享凭据已不存在"))
            }
            var credential = updated.credentials[index]
            guard (try ConnectionValidation.username(credential.username, chinese: chinese)) == result.host.username, credential.auth == result.host.auth else {
                throw AppFailure.message(text("The shared credential changed. Select it again.", "共享凭据已更改，请重新选择。"))
            }
            credential.keySource = result.host.keySource; credential.keyPath = result.host.keyPath
            updated.credentials[index] = credential
            changes[id] = result.keychainValue
        } else { changes[result.host.id] = result.keychainValue }
        if let savedIndex {
            // Preserve metadata that was not part of the authentication form.
            var host = updated.hosts[savedIndex]
            host.username = result.host.username; host.auth = result.host.auth
            host.keySource = result.host.keySource; host.keyPath = result.host.keyPath
            host.credentialID = result.host.credentialID
            // A remembered authentication chosen during connection is a host
            // override; it must not overwrite credentials for the whole group.
            host.groupInheritance?.authentication = false
            host.groupInheritance?.username = false
            updated.hosts[savedIndex] = try GroupDefaults.validatedForStorage(host, workspace: updated, chinese: chinese)
        }
        try commitCredentials(updated, changes: changes)
    }
}
