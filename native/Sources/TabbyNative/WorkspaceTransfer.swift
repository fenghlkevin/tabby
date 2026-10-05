import Foundation

struct HostImportReview {
    var workspace: Workspace
    var secrets: [UUID: Secrets.Value]
    var added: Int
    var skipped: Int
    var warnings: [String]
}

enum WorkspaceTransfer {
    static func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw AppFailure.message("File exceeds 20 MB / 文件超过 20 MB") }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw AppFailure.message("File exceeds 20 MB / 文件超过 20 MB") }
        return data
    }
    static func review(_ document: HostImportDocument, workspace: Workspace, chinese: Bool = false) throws -> HostImportReview {
        var updated = workspace
        var added: [Host] = []
        var mapped: [UUID: UUID] = [:]
        var secrets: [UUID: Secrets.Value] = [:]
        var skipped = 0
        for incoming in document.hosts {
            let address = try ConnectionValidation.address(incoming.address, chinese: chinese)
            let username = try ConnectionValidation.username(incoming.username, chinese: chinese)
            if let existing = (workspace.hosts + added).first(where: {
                let effective = GroupDefaults.resolved($0, workspace: workspace)
                return effective.address.caseInsensitiveCompare(address) == .orderedSame && effective.port == incoming.port && effective.username == username
            }) {
                mapped[incoming.id] = existing.id; skipped += 1
            } else {
                var host = incoming
                host.id = UUID(); host.address = address; host.username = username
                host.credentialID = nil; host.groupInheritance = nil
                mapped[incoming.id] = host.id
                if let secret = document.secrets[incoming.id] { secrets[host.id] = secret }
                added.append(host)
            }
        }
        for i in added.indices {
            if let jump = added[i].jumpHostID {
                guard let target = mapped[jump] else { throw AppFailure.message("Jump host missing from import / 导入文件缺少跳板主机") }
                added[i].jumpHostID = target
            }
        }
        updated.hosts += added
        updated.groups = CatalogNames.unique(updated.groups + added.map(\.group))
        for i in updated.hosts.indices where added.contains(where: { $0.id == updated.hosts[i].id }) {
            updated.hosts[i] = try ConnectionValidation.host(updated.hosts[i], workspace: updated, chinese: chinese)
        }
        return HostImportReview(workspace: updated, secrets: secrets, added: added.count, skipped: skipped, warnings: document.warnings)
    }
}

extension AppStore {
    func importHosts(_ document: HostImportDocument) throws -> HostImportReview {
        let review = try WorkspaceTransfer.review(document, workspace: workspace, chinese: chinese)
        if review.added > 0 { try commitCredentials(review.workspace, changes: review.secrets) }
        return review
    }
    func archiveData(password: String?, includeSecrets: Bool) throws -> Data {
        guard !includeSecrets || password != nil else { throw AppFailure.message(text("A password is required to include credentials", "携带凭据需要设置备份密码")) }
        if let password, password.count < 8 { throw WorkspaceArchiveError.passwordTooShort }
        var secrets: [UUID: Secrets.Value] = [:]
        if includeSecrets {
            let ids = Set(workspace.hosts.map(\.id) + workspace.credentials.map(\.id) + workspace.groupDefaults.map(\.id))
            for id in ids {
                let value = try Secrets.readCredential(id)
                if !value.secret.isEmpty || !value.privateKey.isEmpty { secrets[id] = value }
            }
        }
        return try WorkspaceArchiveCodec.encode(workspace: workspace, password: password, secrets: secrets)
    }
    func restoreArchive(_ archive: WorkspaceArchive) throws {
        try WorkspaceArchiveCodec.validate(archive)
        guard sessions.isEmpty, forwardTasks.isEmpty, openScenes.isEmpty, logViewers.isEmpty else { throw AppFailure.message(text("Close terminals, scenes and log tabs, and stop forwarding before restoring", "请先关闭终端、工作场景和日志标签，并停止端口转发，再恢复工作区")) }
        var changes: [UUID: Secrets.Value] = [:]
        // Restoring a metadata-only backup must not reuse an unrelated old
        // Keychain item that happens to have the same stored identity.
        for id in archive.workspace.hosts.map(\.id) + archive.workspace.credentials.map(\.id) + archive.workspace.groupDefaults.map(\.id) {
            let entry = archive.secrets?[id.uuidString]
            changes[id] = Secrets.Value(secret: entry?.secret ?? "", privateKey: entry?.privateKey ?? "")
        }
        let iconChange = archive.workspace.preferences.applicationIcon != workspace.preferences.applicationIcon
            ? try applicationIconController?.prepare(archive.workspace.preferences.applicationIcon, chinese: chinese) : nil
        do { try commitArchive(archive, changes: changes); iconChange?.commit() }
        catch { _ = iconChange?.rollback(); throw error }
        group = ""; search = ""; monitoring.connectionsChanged()
    }
}
