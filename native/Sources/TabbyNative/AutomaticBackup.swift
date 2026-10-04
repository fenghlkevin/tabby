import Foundation
import Combine
import Darwin

/// Only preferences and the user-granted folder bookmark are serialized. The
/// encryption password and S3 secret remain in separate Keychain items.
struct AutomaticBackupSettings: Codable, Equatable {
    var passwordID = UUID()
    var folderEnabled = false
    var s3Enabled = false
    var includeSecrets = false
    var folderBookmark: Data?
    var folderPath = ""
    var s3Prefix = "Axon/Automatic"
    var isEnabled: Bool { folderEnabled || s3Enabled }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case passwordID, folderEnabled, s3Enabled, includeSecrets, folderBookmark, folderPath, s3Prefix
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        passwordID = try values.decodeIfPresent(UUID.self, forKey: .passwordID) ?? UUID()
        folderEnabled = try values.decodeIfPresent(Bool.self, forKey: .folderEnabled) ?? false
        s3Enabled = try values.decodeIfPresent(Bool.self, forKey: .s3Enabled) ?? false
        includeSecrets = try values.decodeIfPresent(Bool.self, forKey: .includeSecrets) ?? false
        folderBookmark = try values.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderPath = try values.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        s3Prefix = try values.decodeIfPresent(String.self, forKey: .s3Prefix) ?? "Axon/Automatic"
    }
}

struct AutomaticBackupTargetStatus: Codable, Equatable {
    var completedAt: Date
    var succeeded: Bool
    var location: String
    var message: String
}

struct AutomaticBackupReport: Codable, Equatable {
    var lastAttemptAt: Date?
    var folder: AutomaticBackupTargetStatus?
    var s3: AutomaticBackupTargetStatus?
    var generalMessage: String?
}

enum AutomaticBackupPersistence {
    static func url(workspaceURL: URL) -> URL {
        workspaceURL.deletingLastPathComponent().appendingPathComponent("automatic-backup.json")
    }
    static func statusURL(workspaceURL: URL) -> URL {
        workspaceURL.deletingLastPathComponent().appendingPathComponent("automatic-backup-status.json")
    }
    static func load(workspaceURL: URL) throws -> AutomaticBackupSettings {
        let file = url(workspaceURL: workspaceURL)
        guard FileManager.default.fileExists(atPath: file.path) else { return AutomaticBackupSettings() }
        return try JSONDecoder().decode(AutomaticBackupSettings.self, from: WorkspaceTransfer.read(file))
    }
    static func loadReport(workspaceURL: URL) throws -> AutomaticBackupReport {
        let file = statusURL(workspaceURL: workspaceURL)
        guard FileManager.default.fileExists(atPath: file.path) else { return AutomaticBackupReport() }
        return try JSONDecoder().decode(AutomaticBackupReport.self, from: WorkspaceTransfer.read(file))
    }
    static func saveReport(_ report: AutomaticBackupReport, workspaceURL: URL) throws {
        let destination = statusURL(workspaceURL: workspaceURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: destination, options: .atomic)
    }

    /// A blank password preserves the existing Keychain value. Disabling all
    /// targets never requires first reading or unlocking the old password.
    @discardableResult static func save(_ settings: AutomaticBackupSettings, password: String,
                                       workspaceURL: URL) throws -> String? {
        let destination = url(workspaceURL: workspaceURL)
        let previousSettings = try load(workspaceURL: workspaceURL)
        if FileManager.default.fileExists(atPath: destination.path), settings.passwordID != previousSettings.passwordID {
            throw AppFailure.message("Keep the existing automatic backup password identity. / 请保留自动备份密码的原有标识。")
        }
        let encoded = try JSONEncoder().encode(settings)
        if !settings.isEnabled {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: destination, options: .atomic)
            do { try Secrets.save("", id: settings.passwordID); return nil }
            catch { return "Automatic backup is disabled; the saved password could not be removed from Keychain. / 自动备份已关闭，但钥匙串中的密码暂未清理。" }
        }
        if !password.isEmpty, password.count < 8 { throw WorkspaceArchiveError.passwordTooShort }
        try validate(settings, workspaceURL: workspaceURL)
        let previousPassword = try Secrets.readChecked(settings.passwordID)
        let chosenPassword = password.isEmpty ? previousPassword : password
        guard chosenPassword.count >= 8 else { throw WorkspaceArchiveError.passwordTooShort }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !password.isEmpty { try Secrets.save(password, id: settings.passwordID) }
        do { try encoded.write(to: destination, options: .atomic) }
        catch {
            if !password.isEmpty { try? Secrets.save(previousPassword, id: settings.passwordID) }
            throw error
        }
        return nil
    }

    static func validate(_ settings: AutomaticBackupSettings, workspaceURL: URL) throws {
        if settings.folderEnabled {
            guard let bookmark = settings.folderBookmark else {
                throw AppFailure.message("Choose an automatic backup folder first. / 请先选择自动备份文件夹。")
            }
            let folder = try resolveFolder(bookmark)
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try validateFolder(folder)
        }
        if settings.s3Enabled {
            let prefix = try validatedPrefix(settings.s3Prefix)
            let cloud = try CloudConnectionPersistence.load(workspaceURL: workspaceURL)
            var configuration = cloud.s3
            configuration.objectKey = prefix + "/" + filename()
            _ = try configuration.objectURL()
            guard !(try Secrets.readChecked(cloud.id)).isEmpty else {
                throw AppFailure.message("Save the S3 connection and secret key first. / 请先保存 S3 连接与 Secret Access Key。")
            }
        }
    }

    static func chooseFolder(_ folder: URL) throws -> (bookmark: Data, path: String) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try validateFolder(folder)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return (bookmark, folder.path)
    }
    static func resolveFolder(_ bookmark: Data) throws -> URL {
        var stale = false
        let folder: URL
        do {
            folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw AppFailure.message("The backup folder permission is unavailable. Select the folder again. / 备份文件夹授权不可用，请重新选择文件夹。")
        }
        guard !stale else {
            throw AppFailure.message("The backup folder permission is outdated. Select the folder again. / 备份文件夹授权已过期，请重新选择文件夹。")
        }
        return folder
    }
    static func validateFolder(_ folder: URL) throws {
        guard folder.isFileURL, let directory = try? folder.resourceValues(forKeys: [.isDirectoryKey]), directory.isDirectory == true else {
            throw AppFailure.message("The backup folder no longer exists. Select an existing folder. / 备份文件夹不存在，请选择已有文件夹。")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw AppFailure.message("The backup folder is not writable. Select another folder or repair its permissions. / 备份文件夹不可写，请更换文件夹或修复权限。")
        }
    }
    static func validatedPrefix(_ value: String) throws -> String {
        let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !prefix.hasPrefix("/"), !prefix.hasSuffix("/"), prefix.utf8.count <= 850,
              !prefix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !prefix.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AppFailure.message("Enter an S3 backup directory without leading/trailing slashes or dot segments. / 请填写不带开头结尾斜杠、空段或相对路径的 S3 备份目录。")
        }
        return prefix
    }
    static func filename() -> String { "Axon-latest.axonbackup" }
    static func writeBackup(_ data: Data, to file: URL) throws {
        try Task.checkCancellation()
        // Write and sync a private sibling first. Atomic replacement leaves the
        // previous backup intact if writing or publishing the new bytes fails.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".axon-backup-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw fileError(errno, path: temporary.path) }
        defer {
            close(descriptor)
            _ = temporary.path.withCString { unlink($0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw fileError(errno, path: temporary.path)
                }
                guard written > 0 else { throw fileError(EIO, path: temporary.path) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw fileError(errno, path: temporary.path) }
        try Task.checkCancellation()
        let published = temporary.path.withCString { source in
            file.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard published == 0 else { throw fileError(errno, path: file.path) }
    }
    private static func fileError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}

/// Injectable I/O keeps launch behavior testable without real cloud accounts.
struct AutomaticBackupDependencies {
    var loadSettings: (URL) throws -> AutomaticBackupSettings = { try AutomaticBackupPersistence.load(workspaceURL: $0) }
    var loadReport: (URL) throws -> AutomaticBackupReport = { try AutomaticBackupPersistence.loadReport(workspaceURL: $0) }
    var readPassword: (UUID) throws -> String = { try Secrets.readChecked($0, allowInteraction: false) }
    var readCredential: (UUID) throws -> Secrets.Value = { try Secrets.readCredential($0, allowInteraction: false) }
    var loadCloudSettings: (URL) throws -> CloudConnectionSettings = { try CloudConnectionPersistence.load(workspaceURL: $0) }
    var resolveFolder: (Data) throws -> URL = AutomaticBackupPersistence.resolveFolder
    var writeBackup: (Data, URL) throws -> Void = { try AutomaticBackupPersistence.writeBackup($0, to: $1) }
    var upload: (Data, S3BackupConfiguration, String) async throws -> Void = {
        try await S3BackupClient(configuration: $1, secretAccessKey: $2).upload($0, overwrite: true)
    }
    var encodeArchive: (Workspace, String, [UUID: Secrets.Value]) throws -> Data = {
        try WorkspaceArchiveCodec.encode(workspace: $0, password: $1, secrets: $2)
    }
    var saveReport: (AutomaticBackupReport, URL) throws -> Void = { try AutomaticBackupPersistence.saveReport($0, workspaceURL: $1) }
    var now: () -> Date = Date.init
}

@MainActor final class AutomaticBackupCoordinator: ObservableObject {
    private weak var store: AppStore?
    private let dependencies: AutomaticBackupDependencies
    @Published private(set) var isRunning = false
    @Published private(set) var report = AutomaticBackupReport()
    private var didStartAtLaunch = false
    private var operation: Task<Void, Never>?
    private var runID = UUID()

    init(store: AppStore, dependencies: AutomaticBackupDependencies = AutomaticBackupDependencies()) {
        self.store = store
        self.dependencies = dependencies
        do { report = try dependencies.loadReport(store.fileURL) }
        catch { report.generalMessage = "Could not read the last backup result. / 无法读取上次自动备份结果。" }
    }
    func startAtLaunch() {
        guard !didStartAtLaunch else { return }
        didStartAtLaunch = true
        runNow()
    }
    func runNow() {
        guard !isRunning, let store else { return }
        let workspace = store.workspace
        let workspaceReadable = store.canAutomaticallyBackup
        let workspaceURL = store.fileURL
        let dependencies = dependencies
        let previousReport = report
        let id = UUID()
        runID = id
        isRunning = true
        operation = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try await Self.perform(workspace: workspace, workspaceReadable: workspaceReadable,
                                       workspaceURL: workspaceURL, previousReport: previousReport,
                                       dependencies: dependencies)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.runID == id else { return }
                if let result {
                    self.report = result
                    do { try dependencies.saveReport(result, workspaceURL) }
                    catch { self.report.generalMessage = "The backup result could not be saved. / 自动备份结果无法保存。" }
                }
                self.isRunning = false
                self.operation = nil
            } catch {
                guard let self, self.runID == id else { return }
                if error is CancellationError {
                    self.report.generalMessage = "Automatic backup cancelled; completed files are retained. / 自动备份已取消，已完成的文件保留。"
                }
                self.isRunning = false
                self.operation = nil
            }
        }
    }
    func cancel() {
        operation?.cancel()
    }
    func waitUntilFinished() async { await operation?.value }

    private nonisolated static func perform(workspace: Workspace, workspaceReadable: Bool, workspaceURL: URL,
                                            previousReport: AutomaticBackupReport,
                                            dependencies: AutomaticBackupDependencies) async throws -> AutomaticBackupReport? {
        try Task.checkCancellation()
        let settings: AutomaticBackupSettings
        do { settings = try dependencies.loadSettings(workspaceURL) }
        catch {
            var result = previousReport
            result.lastAttemptAt = dependencies.now()
            result.generalMessage = "Automatic backup settings could not be read. / 自动备份设置无法读取。"
            return result
        }
        guard settings.isEnabled else { return nil }
        var result = previousReport
        result.lastAttemptAt = dependencies.now()
        result.generalMessage = nil
        let name = AutomaticBackupPersistence.filename()
        let data: Data
        do {
            guard workspaceReadable else { throw AppFailure.message("The workspace could not be read; automatic backup was skipped. / 工作区读取失败，已跳过自动备份。") }
            let password = try dependencies.readPassword(settings.passwordID)
            guard password.count >= 8 else { throw WorkspaceArchiveError.passwordTooShort }
            var secrets: [UUID: Secrets.Value] = [:]
            if settings.includeSecrets {
                for id in Set(workspace.hosts.map(\.id) + workspace.credentials.map(\.id) + workspace.groupDefaults.map(\.id)) {
                    try Task.checkCancellation()
                    let value = try dependencies.readCredential(id)
                    if !value.secret.isEmpty || !value.privateKey.isEmpty { secrets[id] = value }
                }
            }
            try Task.checkCancellation()
            data = try dependencies.encodeArchive(workspace, password, secrets)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            let message = error.localizedDescription
            if settings.folderEnabled { result.folder = failure(message, location: settings.folderPath, dependencies: dependencies) }
            if settings.s3Enabled { result.s3 = failure(message, location: settings.s3Prefix, dependencies: dependencies) }
            return result
        }
        if settings.folderEnabled {
            var location = settings.folderPath
            do {
                guard let bookmark = settings.folderBookmark else { throw AppFailure.message("Choose the automatic backup folder again. / 请重新选择自动备份文件夹。") }
                let folder = try dependencies.resolveFolder(bookmark)
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                try AutomaticBackupPersistence.validateFolder(folder)
                let destination = folder.appendingPathComponent(name)
                location = destination.path
                try Task.checkCancellation()
                try dependencies.writeBackup(data, destination)
                result.folder = AutomaticBackupTargetStatus(completedAt: dependencies.now(), succeeded: true, location: location,
                    message: "Encrypted backup saved; folder syncing is handled by macOS or the folder provider. / 加密备份已保存，文件夹同步由 macOS 或网盘服务完成。")
            } catch {
                try Task.checkCancellation()
                result.folder = failure(error.localizedDescription, location: location, dependencies: dependencies)
            }
        }
        if settings.s3Enabled {
            var location = settings.s3Prefix
            do {
                try Task.checkCancellation()
                let prefix = try AutomaticBackupPersistence.validatedPrefix(settings.s3Prefix)
                let cloud = try dependencies.loadCloudSettings(workspaceURL)
                var configuration = cloud.s3
                configuration.objectKey = prefix + "/" + name
                _ = try configuration.objectURL()
                location = configuration.bucket + "/" + configuration.objectKey
                let secret = try dependencies.readCredential(cloud.id).secret
                guard !secret.isEmpty else { throw AppFailure.message("The saved S3 secret key is unavailable. / 已保存的 S3 Secret Access Key 不可用。") }
                try Task.checkCancellation()
                try await dependencies.upload(data, configuration, secret)
                try Task.checkCancellation()
                result.s3 = AutomaticBackupTargetStatus(completedAt: dependencies.now(), succeeded: true, location: location,
                                                       message: "Encrypted backup uploaded. / 加密备份已上传。")
            } catch {
                try Task.checkCancellation()
                result.s3 = failure(error.localizedDescription, location: location, dependencies: dependencies)
            }
        }
        try Task.checkCancellation()
        return result
    }
    private nonisolated static func failure(_ message: String, location: String,
                                            dependencies: AutomaticBackupDependencies) -> AutomaticBackupTargetStatus {
        AutomaticBackupTargetStatus(completedAt: dependencies.now(), succeeded: false, location: location, message: message)
    }
}
