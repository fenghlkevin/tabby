import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Portable workspace metadata. Credential bytes appear only inside an
/// authenticated, password-encrypted envelope, never in a plain JSON export.
struct WorkspaceArchive: Codable {
    var version = 1
    var createdAt = Date()
    var workspace: Workspace
    var secrets: [String: ArchiveSecret]?
}

struct ArchiveSecret: Codable, Equatable {
    var secret: String
    var privateKey: String
}

enum WorkspaceArchiveError: LocalizedError {
    case invalidArchive, unsupportedVersion, tooLarge, passwordTooShort
    case passwordRequired, authenticationFailed, invalidReference, duplicateIdentifier
    case invalidConfiguration(String), cryptographyFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "Invalid or incomplete Axon workspace backup. / Axon 工作区备份无效或不完整。"
        case .unsupportedVersion:
            return "This backup version or encryption format is not supported. / 不支持此备份版本或加密格式。"
        case .tooLarge:
            return "Workspace backups must be 20 MB or smaller. / 工作区备份不能超过 20 MB。"
        case .passwordTooShort:
            return "Use a backup password with at least 8 characters. / 备份密码至少需要 8 个字符。"
        case .passwordRequired:
            return "Enter the password for this encrypted backup. / 请输入此加密备份的密码。"
        case .authenticationFailed:
            return "The backup password is incorrect or the encrypted file was damaged. / 备份密码不正确，或加密文件已损坏。"
        case .invalidReference:
            return "The backup contains a missing or invalid identity, group, jump host, or forwarding reference. / 备份中存在无效或缺失的凭据、分组、跳板机或端口转发引用。"
        case .duplicateIdentifier:
            return "The backup contains duplicate identifiers. / 备份包含重复的标识符。"
        case .invalidConfiguration(let reason):
            return "The backup contains invalid connection settings. / 备份包含无效的连接设置。 \(reason)"
        case .cryptographyFailed:
            return "Could not encrypt the workspace backup. / 无法加密工作区备份。"
        }
    }
}

enum WorkspaceArchiveCodec {
    static let maximumBytes = 20 * 1024 * 1024
    static let currentVersion = 1
    private static let encryptionFormat = "axon-workspace-encrypted"
    private static let algorithm = "AES-256-GCM"
    private static let keyDerivation = "PBKDF2-HMAC-SHA256"
    private static let iterations = 200_000
    private static let saltBytes = 16
    private static let authenticationData = Data("axon-workspace-encrypted:1:AES-256-GCM:PBKDF2-HMAC-SHA256:200000".utf8)

    private struct EncryptedEnvelope: Codable {
        let format: String
        let version: Int
        let algorithm: String
        let keyDerivation: String
        let iterations: Int
        let salt: Data
        /// CryptoKit's combined form includes the random nonce and GCM tag.
        let sealed: Data
    }

    static func encode(workspace: Workspace, password: String?, secrets: [UUID: Secrets.Value] = [:]) throws -> Data {
        var snapshot = workspace
        // A backup carries configuration, not a user's connection/file history.
        snapshot.logs = []
        snapshot.recentTargets = []
        let protectedSecrets: [String: ArchiveSecret]?
        if let password {
            guard password.count >= 8 else { throw WorkspaceArchiveError.passwordTooShort }
            protectedSecrets = Dictionary(uniqueKeysWithValues: secrets.map {
                ($0.key.uuidString, ArchiveSecret(secret: $0.value.secret, privateKey: $0.value.privateKey))
            })
        } else {
            // Pasted private keys are already stored only in Keychain. Preserve
            // keySource="text" so restore can request the missing key explicitly.
            protectedSecrets = nil
        }
        let archive = WorkspaceArchive(workspace: snapshot, secrets: protectedSecrets)
        try validate(archive)
        let payload = try encoder().encode(archive)
        guard payload.count <= maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        guard let password else { return payload }
        let salt = try randomSalt()
        let key = try deriveKey(password: password, salt: salt)
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(payload, using: key, authenticating: authenticationData).combined else {
                throw WorkspaceArchiveError.cryptographyFailed
            }
            sealed = combined
        } catch {
            throw WorkspaceArchiveError.cryptographyFailed
        }
        let result = try encoder().encode(EncryptedEnvelope(format: encryptionFormat, version: currentVersion,
                                                           algorithm: algorithm, keyDerivation: keyDerivation,
                                                           iterations: iterations, salt: salt, sealed: sealed))
        guard result.count <= maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        return result
    }

    static func decode(_ data: Data, password: String?) throws -> WorkspaceArchive {
        guard data.count <= maximumBytes else { throw WorkspaceArchiveError.tooLarge }
        let document = try jsonObject(data)
        let encrypted = document["format"] != nil
        let payload: Data
        if encrypted {
            guard Set(document.keys) == Set(["format", "version", "algorithm", "keyDerivation", "iterations", "salt", "sealed"]) else {
                throw WorkspaceArchiveError.invalidArchive
            }
            let envelope: EncryptedEnvelope
            do { envelope = try decoder().decode(EncryptedEnvelope.self, from: data) }
            catch { throw WorkspaceArchiveError.invalidArchive }
            // Fixed parameters must be checked before deriving a key: malicious
            // files cannot request unbounded PBKDF2 work or weaken encryption.
            guard envelope.format == encryptionFormat, envelope.version == currentVersion,
                  envelope.algorithm == algorithm, envelope.keyDerivation == keyDerivation,
                  envelope.iterations == iterations else { throw WorkspaceArchiveError.unsupportedVersion }
            guard envelope.salt.count == saltBytes, envelope.sealed.count >= 28 else { throw WorkspaceArchiveError.invalidArchive }
            guard let password, !password.isEmpty else { throw WorkspaceArchiveError.passwordRequired }
            let key = try deriveKey(password: password, salt: envelope.salt)
            do {
                payload = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: authenticationData)
            } catch { throw WorkspaceArchiveError.authenticationFailed }
        } else {
            payload = data
        }
        let raw = try jsonObject(payload)
        try validateSchema(raw, encrypted: encrypted)
        let archive: WorkspaceArchive
        do { archive = try decoder().decode(WorkspaceArchive.self, from: payload) }
        catch { throw WorkspaceArchiveError.invalidArchive }
        try validate(archive)
        return archive
    }

    static func isEncrypted(_ data: Data) -> Bool {
        guard data.count <= maximumBytes, let raw = try? jsonObject(data) else { return false }
        return raw["format"] != nil
    }

    /// Validate references without flattening inherited host/group metadata.
    /// No Keychain reads or filesystem access happen during validation.
    static func validate(_ archive: WorkspaceArchive) throws {
        guard archive.version == currentVersion else { throw WorkspaceArchiveError.unsupportedVersion }
        guard archive.createdAt.timeIntervalSince1970.isFinite else { throw WorkspaceArchiveError.invalidArchive }
        let workspace = archive.workspace
        let allIDs = workspace.hosts.map(\.id) + workspace.credentials.map(\.id) + workspace.groupDefaults.map(\.id)
            + workspace.forwards.map(\.id) + workspace.snippets.map(\.id) + workspace.workScenes.map(\.id) + workspace.batchTemplates.map(\.id)
        guard Set(allIDs).count == allIDs.count else { throw WorkspaceArchiveError.duplicateIdentifier }
        for template in workspace.batchTemplates { _ = try template.validated(chinese: false) }
        let hostIDs = Set(workspace.hosts.map(\.id))
        let credentialIDs = Set(workspace.credentials.map(\.id))
        let secretIDs = hostIDs.union(credentialIDs).union(workspace.groupDefaults.map(\.id))
        var parsedSecretIDs = Set<UUID>()
        for (rawID, value) in archive.secrets ?? [:] {
            guard let id = UUID(uuidString: rawID), rawID == id.uuidString, secretIDs.contains(id) else {
                throw WorkspaceArchiveError.invalidReference
            }
            guard parsedSecretIDs.insert(id).inserted else { throw WorkspaceArchiveError.duplicateIdentifier }
            guard value.privateKey.utf8.count <= 128 * 1024, value.secret.utf8.count <= 128 * 1024 else {
                throw WorkspaceArchiveError.invalidArchive
            }
        }
        for host in workspace.hosts {
            if let id = host.credentialID, !credentialIDs.contains(id) { throw WorkspaceArchiveError.invalidReference }
            if let id = host.jumpHostID, !hostIDs.contains(id) { throw WorkspaceArchiveError.invalidReference }
            if host.groupInheritance?.hasAny == true, GroupDefaults.group(named: host.group, workspace: workspace) == nil {
                throw WorkspaceArchiveError.invalidReference
            }
        }
        for group in workspace.groupDefaults {
            if let id = group.credentialID, !credentialIDs.contains(id) { throw WorkspaceArchiveError.invalidReference }
            if let id = group.jumpHostID, !hostIDs.contains(id) { throw WorkspaceArchiveError.invalidReference }
        }
        for rule in workspace.forwards {
            guard let id = rule.hostID, hostIDs.contains(id) else { throw WorkspaceArchiveError.invalidReference }
        }
        do {
            try validatePreferences(workspace.preferences)
            for name in workspace.groups + workspace.tags { _ = try ConnectionValidation.label(name, required: true) }
            for credential in workspace.credentials { _ = try ConnectionValidation.credential(credential) }
            var groupNames: [String] = []
            for group in workspace.groupDefaults {
                let name = try ConnectionValidation.label(group.name, required: true)
                guard !CatalogNames.contains(groupNames, name) else { throw WorkspaceArchiveError.duplicateIdentifier }
                groupNames.append(name)
                var probe = Host()
                probe.id = group.id; probe.name = name; probe.address = "group-defaults.invalid"
                probe.port = group.port; probe.username = group.username; probe.auth = group.auth
                probe.keyPath = group.keyPath; probe.keySource = group.keySource
                probe.credentialID = group.credentialID; probe.jumpHostID = group.jumpHostID
                _ = try ConnectionValidation.host(probe, workspace: workspace)
            }
            for host in workspace.hosts { _ = try ConnectionValidation.host(host, workspace: workspace) }
            for rule in workspace.forwards { _ = try ConnectionValidation.forward(rule, workspace: workspace) }
            for scene in workspace.workScenes { _ = try scene.validated(workspace: workspace, allowEmpty: true) }
            for snippet in workspace.snippets {
                _ = try ConnectionValidation.label(snippet.name, required: true)
                _ = try ConnectionValidation.label(snippet.group)
                try SnippetInput.validate(snippet.body, chinese: false)
            }
        } catch let error as WorkspaceArchiveError { throw error }
        catch { throw WorkspaceArchiveError.invalidConfiguration(error.localizedDescription) }
    }

    /// Portability checks deliberately avoid installed-font and path-existence
    /// checks: a valid backup may come from a different Mac.
    private static func validatePreferences(_ value: Preferences) throws {
        func failure(_ reason: String) -> AppFailure { .message(reason) }
        guard ["auto", "zh-CN", "en-US"].contains(value.language),
              ApplicationIconAppearance.styles.contains(value.applicationIcon) else {
            throw failure("Unknown language or application icon")
        }
        if let issue = ShortcutBinding.validationIssue(value, chinese: false) { throw failure(issue) }
        _ = try ConnectionValidation.label(value.fontName, required: true)
        guard value.fontName.count <= 256, value.fontSize.isFinite, (10...40).contains(value.fontSize),
              (0...1_000_000).contains(value.scrollback), (1...120).contains(value.sshConnectTimeout) else {
            throw failure("Invalid font size, scrollback, or connection timeout")
        }
        guard ["block", "bar", "underline"].contains(value.cursorShape),
              ["none", "sound", "visual", "soundAndVisual"].contains(value.bellStyle) else {
            throw failure("Unknown cursor shape or bell style")
        }
        try TerminalThemeLibrary.validate(value, chinese: false)
        guard TerminalTheme.library(value).contains(where: { $0.id == value.terminalTheme }) else {
            throw failure("Unknown terminal theme")
        }
        for path in [value.localShell, value.localDirectory] {
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw failure("Shell and directory paths cannot contain control characters")
            }
        }
    }

    private static func validateSchema(_ raw: [String: Any], encrypted: Bool) throws {
        let keys = Set(raw.keys)
        guard keys.isSubset(of: Set(["version", "createdAt", "workspace", "secrets"])),
              keys.isSuperset(of: Set(["version", "createdAt", "workspace"])),
              let number = raw["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = raw["version"] as? Int else { throw WorkspaceArchiveError.invalidArchive }
        guard version == currentVersion else { throw WorkspaceArchiveError.unsupportedVersion }
        // Plain imports must never introduce passwords or private keys, even if
        // another tool placed a secrets dictionary in the JSON file.
        guard encrypted || raw["secrets"] == nil else { throw WorkspaceArchiveError.invalidArchive }
        guard let workspace = raw["workspace"] as? [String: Any],
              Set(workspace.keys).isSuperset(of: Set(["hosts", "groups", "groupDefaults", "tags", "credentials", "forwards", "logs", "snippets", "recentTargets", "preferences", "bookmarks", "trustedKeys"])),
              Set(workspace.keys).isSubset(of: Set(["hosts", "groups", "groupDefaults", "tags", "credentials", "forwards", "logs", "snippets", "workScenes", "batchTemplates", "recentTargets", "preferences", "bookmarks", "trustedKeys"])) else {
            throw WorkspaceArchiveError.invalidArchive
        }
        guard workspace["groups"] is [String], workspace["tags"] is [String],
              workspace["logs"] is [[String: Any]], workspace["recentTargets"] is [[String: Any]],
              workspace["bookmarks"] is [String: [String]], workspace["trustedKeys"] is [String: String],
              let preferences = workspace["preferences"] as? [String: Any] else {
            throw WorkspaceArchiveError.invalidArchive
        }
        let requiredPreferences = Set([
            "language", "applicationIcon", "fontName", "fontSize", "scrollback", "copyOnSelect", "rightClickPaste", "trimPaste",
            "analytics", "globalHotkey", "restoreTabs", "autoOpen", "foreground", "background", "customTerminalThemes",
            "cursorColor", "terminalTheme", "cursorShape", "cursorBlink", "optionAsMeta", "backspaceControlH",
            "mouseReporting", "bellStyle", "confirmMultilinePaste", "middleClickPaste", "localShell", "localDirectory",
            "localLoginShell", "sshConnectTimeout"
        ])
        // Workspace and Preferences intentionally default missing/null fields
        // when opening legacy local files. Full archive restoration must never
        // silently replace missing configuration with those defaults.
        guard Set(preferences.keys).isSuperset(of: requiredPreferences),
              Set(preferences.keys).isSubset(of: requiredPreferences.union(["shortcuts", "ansiColors", "keywordRules", "commandHistoryLimit", "commandHistoryExclusions", "commandCompletionNotifications"])),
              !preferences.values.contains(where: { $0 is NSNull }) else {
            throw WorkspaceArchiveError.invalidArchive
        }
        if let scenes = workspace["workScenes"], !(scenes is [[String: Any]]) { throw WorkspaceArchiveError.invalidArchive }
        for field in ["hosts", "credentials", "groupDefaults", "forwards", "snippets"] + (workspace["workScenes"] != nil ? ["workScenes"] : []) {
            guard let values = workspace[field] as? [[String: Any]] else { throw WorkspaceArchiveError.invalidArchive }
            for value in values {
                // CommandSnippet's legacy decoder creates a fresh UUID for a
                // missing id. An archive must instead preserve every identity.
                guard let rawID = value["id"] as? String, UUID(uuidString: rawID) != nil else {
                    throw WorkspaceArchiveError.invalidArchive
                }
            }
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw WorkspaceArchiveError.invalidArchive }
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkspaceArchiveError.invalidArchive }
            return value
        } catch { throw WorkspaceArchiveError.invalidArchive }
    }

    private static func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.dateEncodingStrategy = .iso8601
        result.outputFormatting = [.sortedKeys, .prettyPrinted]
        return result
    }

    private static func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.dateDecodingStrategy = .iso8601
        return result
    }

    private static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceArchiveError.cryptographyFailed
        }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                keyBytes.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBuffer.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
                                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                        keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyBuffer.count)
                }
            }
        }
        guard status == kCCSuccess else { throw WorkspaceArchiveError.cryptographyFailed }
        return SymmetricKey(data: keyBytes)
    }
}
