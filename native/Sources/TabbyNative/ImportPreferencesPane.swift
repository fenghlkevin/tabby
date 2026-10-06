import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension HostImportFormat {
    var title: String { switch self { case .tabby: return "Tabby YAML"; case .openssh: return "OpenSSH config"; case .csv: return "CSV / Termius"; case .putty: return "PuTTY (.reg)" } }
}
extension HostExportFormat {
    var title: String { switch self { case .tabby: return "Tabby YAML"; case .openssh: return "OpenSSH config"; case .csv: return "CSV" } }
    var fileExtension: String { switch self { case .tabby: return "yaml"; case .openssh: return "config"; case .csv: return "csv" } }
}

struct ImportPreferencesPane: View {
    @EnvironmentObject var store: AppStore
    @State private var importFormat: HostImportFormat = .tabby
    @State private var exportFormat: HostExportFormat = .tabby
    @State private var selectedFile: URL?
    @State private var document: HostImportDocument?
    @State private var review: HostImportReview?
    @State private var message = ""
    @State private var resultArea = "import"
    @State private var failed = false
    @State private var password = ""
    @State private var encrypted = false
    @State private var includeSecrets = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BackupCard(title: store.text("Import SSH hosts", "导入 SSH 主机"), symbol: "square.and.arrow.down") {
                Text(store.text("Source format", "来源格式")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                AxonChoiceField(selection: $importFormat, choices: HostImportFormat.allCases.map { ($0, $0.title) }, placeholder: store.text("Source format", "来源格式"), symbol: "doc.text", identifier: "axon-importFormat").frame(maxWidth: 320).onChange(of: importFormat) { _, _ in selectedFile = nil; document = nil; review = nil; message = "" }
                Text(store.text("Tabby YAML, OpenSSH config, Termius-compatible CSV and PuTTY registry exports.", "支持 Tabby YAML、OpenSSH config、Termius 兼容 CSV 和 PuTTY 注册表导出。" )).foregroundStyle(Palette.muted)
                fileLabel(selectedFile)
                HStack(spacing: 10) {
                    action(store.text("Choose file…", "选择文件…"), "axon-import-choose", run: choose)
                    action(store.text("Import hosts", "导入主机"), "axon-import-confirm", prominent: true, enabled: document != nil, run: runImport)
                }
                if let review {
                    Text(store.text("\(review.added) new hosts; \(review.skipped) duplicates will be skipped.", "将新增 \(review.added) 台主机，跳过 \(review.skipped) 个重复项。" )).font(.system(size: 12, weight: .medium))
                    ForEach(Array(review.warnings.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
                Text(store.text("Matches use address, port and effective username. Source passwords go to macOS Keychain. SSH agents, scripts, proxy commands and encrypted vaults are not migrated.", "按地址、端口和有效用户名去重；源文件密码保存到 macOS 钥匙串。SSH agent、脚本、代理命令及加密保险库不迁移。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                result("import")
            }
            BackupCard(title: store.text("Export SSH hosts", "导出 SSH 主机"), symbol: "square.and.arrow.up") {
                Text(store.text("Export format", "导出格式")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                AxonChoiceField(selection: $exportFormat, choices: HostExportFormat.allCases.map { ($0, $0.title) }, placeholder: store.text("Export format", "导出格式"), symbol: "doc.text", identifier: "axon-exportFormat").frame(maxWidth: 320)
                Text(store.text("Exports all \(store.workspace.hosts.count) hosts using their effective connection settings, including groups and jump hosts where the format allows. Passwords and private-key contents are excluded.", "导出全部 \(store.workspace.hosts.count) 台主机的有效连接配置；按格式保留分组与跳板关系。不含密码和私钥内容。" )).foregroundStyle(Palette.muted)
                action(store.text("Export hosts…", "导出主机…"), "axon-export-hosts", enabled: !store.workspace.hosts.isEmpty, run: exportHosts)
                Text(store.text("CSV preserves groups and tags; OpenSSH uses generated aliases and does not preserve group or tag labels. Hosts using pasted keys need credentials reconfigured after import.", "CSV 保留分组与标签；OpenSSH 使用生成的别名，不保留分组与标签。使用文本私钥的主机迁移后需要重新配置凭据。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                result("export")
            }
            BackupCard(title: store.text("Axon workspace backup", "Axon 工作区备份"), symbol: "externaldrive") {
                Text(store.text("Preserves hosts, groups, identities, forwards, snippets, themes and preferences. Logs and recent history are excluded. Restore replaces the current workspace after confirmation and keeps a local backup.", "保留主机、分组、凭据元数据、转发、片段、主题与设置，不含日志和最近记录。确认恢复后替换当前工作区，同时保留本地备份。" )).foregroundStyle(Palette.muted)
                Toggle(store.text("Encrypt backup", "加密备份"), isOn: $encrypted).toggleStyle(AxonCheckboxStyle())
                    .accessibilityIdentifier("axon-backup-encryption")
                    .onChange(of: encrypted) { _, value in if !value { includeSecrets = false } }
                Toggle(store.text("Include passwords and pasted private keys", "携带密码与粘贴的私钥"), isOn: $includeSecrets).toggleStyle(AxonCheckboxStyle()).disabled(!encrypted)
                PreferencesSecureField(title: store.text("Backup password (at least 8 characters)", "备份密码（至少 8 位）"), text: $password, identifier: "axon-backup-password", chinese: store.chinese).appInput()
                HStack(spacing: 10) {
                    action(store.text("Save backup…", "保存备份…"), "axon-backup-export", enabled: !encrypted || password.count >= 8, run: exportArchive)
                    action(store.text("Restore backup…", "恢复备份…"), "axon-backup-import", run: restoreArchive)
                }
                Text(store.text("Private-key files are referenced by path, never copied. Keep the backup password: it cannot be recovered. Metadata-only backups require credentials to be entered again.", "私钥文件仅保存路径，不复制文件。请妥善保存备份密码，无法找回；不携带凭据的备份恢复后需重新填写凭据。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                result("backup")
            }
        }
    }
    @ViewBuilder private func result(_ area: String) -> some View {
        if resultArea == area && !message.isEmpty { Text(message).foregroundStyle(failed ? .red : Palette.blue).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("axon-" + area + "-result") }
    }
    private func action(_ title: String, _ id: String, prominent: Bool = false, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        PreferencesActionButton(title: title, identifier: id, prominent: prominent, enabled: enabled, action: run).frame(width: 144, height: 38).disabled(!enabled)
    }
    private func fileLabel(_ url: URL?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(Palette.blue)
            Text(url?.lastPathComponent ?? store.text("No configuration selected", "尚未选择配置文件")).lineLimit(2)
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func choose() {
        resultArea = "import"
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let parsed = try HostTransfer.parse(WorkspaceTransfer.read(url), format: importFormat)
                review = try WorkspaceTransfer.review(parsed, workspace: store.workspace, chinese: store.chinese)
                selectedFile = url; document = parsed; message = ""; failed = false
            } catch { selectedFile = nil; document = nil; review = nil; show(error) }
        }
    }
    private func runImport() {
        resultArea = "import"
        guard let document else { return }
        do {
            let result = try store.importHosts(document)
            message = store.text("Imported \(result.added) hosts; skipped \(result.skipped) duplicates. Saved immediately.", "已导入 \(result.added) 台主机，跳过 \(result.skipped) 个重复项，已立即保存。")
            failed = false; self.document = nil; review = nil
        } catch { show(error) }
    }
    private func exportHosts() {
        resultArea = "export"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Axon-hosts." + exportFormat.fileExtension
        if panel.runModal() == .OK, let url = panel.url {
            do { try HostTransfer.export(store.workspace, format: exportFormat).write(to: url, options: .atomic); message = store.text("Hosts exported to \(url.lastPathComponent)", "主机已导出到 \(url.lastPathComponent)"); failed = false }
            catch { show(error) }
        }
    }
    private func exportArchive() {
        guard !encrypted || password.count >= 8 else { return }
        resultArea = "backup"
        let panel = NSSavePanel(); panel.nameFieldStringValue = BackupPresentation.filename()
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.archiveData(password: encrypted ? password : nil, includeSecrets: includeSecrets).write(to: url, options: .atomic); message = store.text("Workspace backup saved", "工作区备份已保存"); failed = false }
            catch { show(error) }
        }
    }
    private func restoreArchive() {
        resultArea = "backup"
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                guard let archive = try BackupPresentation.decodeForRestore(WorkspaceTransfer.read(url), chinese: store.chinese) else { return }
                guard BackupPresentation.confirmRestore(archive, store: store) else { return }
                try store.restoreArchive(archive); message = store.text("Workspace restored", "工作区已恢复"); failed = false
            } catch { show(error) }
        }
    }
    private func show(_ error: Error) { message = error.localizedDescription; failed = true }
}

struct BackupCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

enum BackupPresentation {
    static func filename() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.timeZone = .current
        return "Axon-" + formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8)) + ".axonbackup"
    }
    /// Restoration deliberately has its own password prompt. Never reuse the
    /// export field or the remembered automatic-backup password.
    @MainActor static func decodeForRestore(_ data: Data, chinese: Bool,
        requestPassword: ((String?) -> String?)? = nil) throws -> WorkspaceArchive? {
        guard WorkspaceArchiveCodec.isEncrypted(data) else {
            return try WorkspaceArchiveCodec.decode(data, password: nil)
        }
        let request = requestPassword ?? { passwordPrompt(chinese: chinese, error: $0) }
        var failure: String?
        while let password = request(failure) {
            do { return try WorkspaceArchiveCodec.decode(data, password: password) }
            catch WorkspaceArchiveError.authenticationFailed { failure = WorkspaceArchiveError.authenticationFailed.localizedDescription }
            catch WorkspaceArchiveError.passwordRequired { failure = WorkspaceArchiveError.passwordRequired.localizedDescription }
        }
        return nil
    }
    @MainActor private static func passwordPrompt(chinese: Bool, error: String?) -> String? {
        BackupRestorePasswordWindowController(chinese: chinese, error: error).present()
    }
    static func credentialCounts(_ archive: WorkspaceArchive) -> (passwords: Int, privateKeys: Int) {
        let values = Array((archive.secrets ?? [:]).values)
        return (values.filter { !$0.secret.isEmpty }.count, values.filter { !$0.privateKey.isEmpty }.count)
    }
    @MainActor static func confirmRestore(_ archive: WorkspaceArchive, store: AppStore) -> Bool {
        let alert = AppModalAlert(); alert.destructive = true; alert.alertStyle = .warning
        alert.messageText = store.text("Restore this workspace backup?", "恢复此工作区备份？")
        let counts = credentialCounts(archive)
        let hasCredentials = counts.passwords > 0 || counts.privateKeys > 0
        let credentials = hasCredentials
            ? store.text("This backup contains \(counts.passwords) passwords/passphrases and \(counts.privateKeys) pasted private keys. Credentials missing from it must be entered again.", "此备份携带 \(counts.passwords) 项密码／口令和 \(counts.privateKeys) 项粘贴的私钥；未携带的凭据需重新填写。")
            : store.text("This backup contains NO passwords or private-key contents. Restoring it clears the restored hosts' existing credentials; you will need to enter them again. Encrypting a backup alone does not include credentials: select Include passwords and pasted private keys when creating it.", "此备份没有携带任何主机密码或私钥内容。恢复会清空所恢复主机的现有凭据，需要重新填写。仅加密不会携带凭据，创建备份时还需勾选“携带密码与粘贴的私钥”。")
        alert.informativeText = store.text("Replace \(store.workspace.hosts.count) current hosts with \(archive.workspace.hosts.count) backup hosts, along with groups, identities, snippets, forwards and saved preferences. Close sessions first. The previous configuration is kept as workspace.json.backup.", "将当前 \(store.workspace.hosts.count) 台主机替换为备份中的 \(archive.workspace.hosts.count) 台，同时恢复分组、凭据、片段、转发和已保存设置。请先关闭会话。旧配置保留为 workspace.json.backup。") + "\n\n" + credentials
        alert.addButton(withTitle: hasCredentials ? store.text("Restore", "恢复") : store.text("Restore without credentials", "恢复并清空凭据")); alert.addButton(withTitle: store.text("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
