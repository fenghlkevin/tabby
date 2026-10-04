import Foundation

/// Group identity and metadata live in Workspace; password/key bytes use the
/// group's UUID in the existing Keychain service, never the JSON configuration.
struct HostGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var port = 22
    var username = "root"
    var auth = "password"
    var keyPath = ""
    var keySource: String?
    var credentialID: UUID?
    var jumpHostID: UUID?
}

struct HostGroupInheritance: Codable, Equatable, Hashable {
    var port = true
    var username = true
    var authentication = true
    var jumpHost = true
    static let all = HostGroupInheritance()
    var hasAny: Bool { port || username || authentication || jumpHost }
}

enum GroupDefaults {
    static func group(named name: String, workspace: Workspace) -> HostGroup? {
        workspace.groupDefaults.first { CatalogNames.matches($0.name, name) }
    }

    /// Resolve shared and inherited metadata for endpoint comparisons as well as
    /// SSH/SFTP. Returned profiles are connection snapshots, not storage drafts.
    static func resolved(_ original: Host, workspace: Workspace) -> Host {
        var host = original
        if let flags = original.groupInheritance, let group = group(named: original.group, workspace: workspace) {
            let shared = group.credentialID.flatMap { id in workspace.credentials.first { $0.id == id } }
            if flags.port { host.port = group.port }
            if flags.username { host.username = shared?.username ?? group.username }
            if flags.jumpHost { host.jumpHostID = group.jumpHostID }
            if flags.authentication {
                host.auth = shared?.auth ?? group.auth
                host.keyPath = shared?.keyPath ?? group.keyPath
                host.keySource = shared?.keySource ?? group.keySource
                // Resolve group identity separately from the host's username:
                // per-host username overrides can still reuse the same secret.
                host.credentialID = nil
            }
        }
        if let shared = host.credentialID.flatMap({ id in workspace.credentials.first { $0.id == id } }) {
            host.username = shared.username; host.auth = shared.auth
            host.keyPath = shared.keyPath; host.keySource = shared.keySource
        }
        host.groupInheritance = nil
        return host
    }

    static func secretID(for host: Host, workspace: Workspace) -> UUID {
        if host.groupInheritance?.authentication == true, let group = group(named: host.group, workspace: workspace) {
            return group.credentialID ?? group.id
        }
        return host.credentialID ?? host.id
    }

    /// Existing sessions retain their destination coordinates, while a base
    /// rename or new inherited login applies to the next connection attempt.
    static func connectionSource(_ original: Host, workspace: Workspace) -> Host {
        guard let current = workspace.hosts.first(where: { $0.id == original.id }) else { return original }
        var host = original
        host.username = current.username; host.auth = current.auth
        host.keySource = current.keySource; host.keyPath = current.keyPath
        host.credentialID = current.credentialID; host.group = current.group
        host.groupInheritance = current.groupInheritance
        if original.groupInheritance?.port == true || current.groupInheritance?.port == true { host.port = current.port }
        if original.groupInheritance?.jumpHost == true || current.groupInheritance?.jumpHost == true { host.jumpHostID = current.jumpHostID }
        return host
    }

    /// Preserve raw overrides while validating the settings actually used. An
    /// inherited base does not flatten into repeated per-host values on Save.
    static func validatedForStorage(_ original: Host, workspace: Workspace, chinese: Bool) throws -> Host {
        let effective = try ConnectionValidation.host(original, workspace: workspace, chinese: chinese)
        guard original.groupInheritance?.hasAny == true, group(named: original.group, workspace: workspace) != nil else {
            var value = effective
            value.groupInheritance = original.groupInheritance
            return value
        }
        var stored = original
        stored.name = effective.name; stored.address = effective.address
        stored.group = effective.group; stored.tags = effective.tags
        if original.groupInheritance?.port != true { stored.port = effective.port }
        if original.groupInheritance?.username != true { stored.username = effective.username }
        if original.groupInheritance?.authentication != true {
            stored.auth = effective.auth; stored.keyPath = effective.keyPath; stored.keySource = effective.keySource
        }
        if original.groupInheritance?.jumpHost != true { stored.jumpHostID = effective.jumpHostID }
        return stored
    }
}

extension AppStore {
    func groupDefaults(named name: String) -> HostGroup? { GroupDefaults.group(named: name, workspace: workspace) }
    func resolvedHost(_ host: Host) -> Host { GroupDefaults.resolved(host, workspace: workspace) }
    func groupSecretID(for host: Host) -> UUID { GroupDefaults.secretID(for: host, workspace: workspace) }

    func upsertGroup(_ original: HostGroup, replacing oldName: String? = nil,
                     secret: String, privateKey: String? = nil) throws {
        var value = original
        value.name = try ConnectionValidation.label(value.name, required: true, chinese: chinese)
        let previous = workspace.groupDefaults.first { $0.id == value.id }
        let old = previous?.name ?? oldName
        guard !groups.contains(where: { CatalogNames.matches($0, value.name) && (old == nil || !CatalogNames.matches($0, old!)) }) else {
            throw AppFailure.message(text("Enter a unique group name", "请输入未使用的分组名称"))
        }
        guard (1...65535).contains(value.port) else { throw AppFailure.message(text("Port must be an integer from 1 to 65535", "端口必须是 1–65535 的整数")) }
        if let id = value.credentialID {
            guard let shared = workspace.credentials.first(where: { $0.id == id }) else { throw AppFailure.message(text("Shared identity no longer exists", "共享凭据已不存在")) }
            value.username = try ConnectionValidation.username(shared.username, chinese: chinese)
            value.auth = shared.auth; value.keyPath = shared.keyPath; value.keySource = shared.keySource
        }
        // Reuse pure credential validation without inventing a real endpoint.
        let metadata = try ConnectionValidation.credential(VaultCredential(id: value.id, name: value.name, username: value.username,
                                                                           auth: value.auth, keyPath: value.keyPath,
                                                                           keySource: value.keySource), chinese: chinese)
        value.username = metadata.username
        var updated = workspace
        if let index = updated.groupDefaults.firstIndex(where: { $0.id == value.id }) { updated.groupDefaults[index] = value }
        else { updated.groupDefaults.append(value) }
        updated.groups = CatalogNames.unique(updated.groups.filter { old == nil || !CatalogNames.matches($0, old!) } + [value.name])
        if let old {
            for i in updated.hosts.indices where CatalogNames.matches(updated.hosts[i].group, old) { updated.hosts[i].group = value.name }
        }
        // Validate the full affected route before reading or writing secrets.
        if let jump = value.jumpHostID {
            guard updated.hosts.contains(where: { $0.id == jump }) else { throw AppFailure.message(text("Jump host no longer exists", "跳板主机已不存在")) }
            var probe = Host(); probe.address = "group-defaults.invalid"; probe.username = value.username; probe.jumpHostID = jump
            _ = try ConnectionValidation.host(probe, workspace: updated, chinese: chinese)
        }
        for host in updated.hosts where CatalogNames.matches(host.group, value.name) && host.groupInheritance?.hasAny == true {
            _ = try ConnectionValidation.host(host, workspace: updated, chinese: chinese)
        }
        let changes = value.credentialID == nil
            ? [value.id: try keyValue(auth: value.auth, source: value.keySource, path: value.keyPath,
                                     id: value.id, secret: secret, privateKey: privateKey)] : [:]
        try commitCredentials(updated, changes: changes)
        if let old, CatalogNames.matches(group, old) { group = value.name }
    }

    /// Removing a base retains hosts' effective metadata and copies only the
    /// secrets they were inheriting. All changes roll back as a single commit.
    func removeGroup(_ name: String) throws {
        var updated = workspace
        var changes: [UUID: Secrets.Value] = [:]
        for i in updated.hosts.indices where CatalogNames.matches(updated.hosts[i].group, name) {
            let original = updated.hosts[i]
            if original.groupInheritance?.hasAny == true, groupDefaults(named: name) != nil {
                if original.groupInheritance?.authentication == true {
                    changes[original.id] = try Secrets.readCredential(groupSecretID(for: original))
                }
                updated.hosts[i] = resolvedHost(original)
            }
            updated.hosts[i].group = ""
            updated.hosts[i].groupInheritance = nil
        }
        for value in updated.groupDefaults where CatalogNames.matches(value.name, name) { changes[value.id] = Secrets.Value() }
        updated.groupDefaults.removeAll { CatalogNames.matches($0.name, name) }
        updated.groups.removeAll { CatalogNames.matches($0, name) }
        try commitCredentials(updated, changes: changes)
        if CatalogNames.matches(group, name) { group = "" }
    }
}
