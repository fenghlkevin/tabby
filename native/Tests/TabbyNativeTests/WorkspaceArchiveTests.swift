import XCTest
@testable import TabbyNative

final class WorkspaceArchiveTests: XCTestCase {
    private let password = "backup-password-fixture"

    private func workspace() -> Workspace {
        var jump = TabbyNative.Host(); jump.name = "Jump"; jump.address = "jump.example.invalid"; jump.username = "root"
        var identity = VaultCredential(); identity.name = "Production key"; identity.username = "deploy"
        identity.auth = "key"; identity.keySource = "text"
        var group = HostGroup(); group.name = "Production"; group.port = 2200
        group.credentialID = identity.id; group.jumpHostID = jump.id
        var host = TabbyNative.Host(); host.name = "Application"; host.address = "app.example.invalid"
        host.group = group.name; host.groupInheritance = .all; host.port = 0; host.username = ""
        host.favorite = true; host.tags = "production"
        var forward = PortForwardRule(); forward.name = "Database"; forward.hostID = host.id
        var snippet = CommandSnippet(); snippet.name = "Disk usage"; snippet.group = "Maintenance"; snippet.body = "df -h"
        var result = Workspace()
        result.hosts = [jump, host]; result.credentials = [identity]; result.groupDefaults = [group]
        result.groups = [group.name]; result.tags = ["production"]; result.forwards = [forward]; result.snippets = [snippet]
        result.preferences.fontName = "Monaco"; result.preferences.fontSize = 21
        result.preferences.language = "zh-CN"; result.preferences.localShell = "/bin/zsh"
        result.bookmarks = [host.id.uuidString: ["/var/log"]]
        result.trustedKeys = ["app.example.invalid:2200": "ssh-ed25519 trusted-fixture"]
        result.logs = [ActivityLog(category: "SSH", event: "Connected", host: "session-history-fixture", failed: false)]
        result.recentTargets = [RecentTarget(kind: .ssh, hostID: host.id)]
        return result
    }

    private func mutateJSON(_ data: Data, _ mutation: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertArchiveError(_ data: Data, password: String? = nil, expected: WorkspaceArchiveError,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WorkspaceArchiveCodec.decode(data, password: password), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        }
    }

    func testPlainBackupPreservesConfigurationAndReferencesWithoutHistoryOrSecrets() throws {
        let original = workspace()
        let secretID = original.credentials[0].id
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: nil,
                                                   secrets: [secretID: Secrets.Value(secret: "password-fixture", privateKey: "private-key-fixture")])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("password-fixture")); XCTAssertFalse(text.contains("private-key-fixture"))
        XCTAssertFalse(text.contains("session-history-fixture")); XCTAssertFalse(text.contains("\"secrets\""))
        XCTAssertFalse(WorkspaceArchiveCodec.isEncrypted(data))
        let archive = try WorkspaceArchiveCodec.decode(data, password: nil)
        XCTAssertEqual(archive.version, 1); XCTAssertNil(archive.secrets)
        XCTAssertEqual(archive.workspace.hosts, original.hosts)
        XCTAssertEqual(archive.workspace.groupDefaults, original.groupDefaults)
        XCTAssertEqual(archive.workspace.credentials, original.credentials)
        XCTAssertEqual(archive.workspace.preferences, original.preferences)
        XCTAssertEqual(archive.workspace.snippets, original.snippets)
        XCTAssertEqual(archive.workspace.bookmarks, original.bookmarks)
        XCTAssertEqual(archive.workspace.trustedKeys, original.trustedKeys)
        XCTAssertEqual(archive.workspace.forwards[0].hostID, original.forwards[0].hostID)
        XCTAssertEqual(archive.workspace.credentials[0].keySource, "text")
        XCTAssertTrue(archive.workspace.logs.isEmpty); XCTAssertTrue(archive.workspace.recentTargets.isEmpty)
        XCTAssertEqual(archive.workspace.hosts[1].port, 0, "Raw inherited overrides must not be flattened")
        XCTAssertEqual(try ConnectionValidation.host(archive.workspace.hosts[1], workspace: archive.workspace).port, 2200)
        XCTAssertEqual(original.logs.count, 1, "Encoding must not mutate the active workspace")
    }

    func testEncryptedBackupRoundTripsSecretsAndUsesFreshSaltAndNonce() throws {
        let original = workspace()
        let id = original.credentials[0].id
        let secrets = [id: Secrets.Value(secret: "private-key-passphrase", privateKey: "private-key-content-fixture")]
        let first = try WorkspaceArchiveCodec.encode(workspace: original, password: password, secrets: secrets)
        let second = try WorkspaceArchiveCodec.encode(workspace: original, password: password, secrets: secrets)
        XCTAssertNotEqual(first, second); XCTAssertTrue(WorkspaceArchiveCodec.isEncrypted(first))
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertFalse(text.contains("app.example.invalid")); XCTAssertFalse(text.contains("private-key-content-fixture"))
        let archive = try WorkspaceArchiveCodec.decode(first, password: password)
        XCTAssertEqual(archive.workspace.hosts, original.hosts)
        XCTAssertEqual(archive.secrets?[id.uuidString], ArchiveSecret(secret: "private-key-passphrase", privateKey: "private-key-content-fixture"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(envelope["algorithm"] as? String, "AES-256-GCM")
        XCTAssertEqual(envelope["keyDerivation"] as? String, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(envelope["iterations"] as? Int, 200_000)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(envelope["salt"] as? String))?.count, 16)
    }

    func testWrongMissingPasswordAndCiphertextDamageAreReportedWithoutSecrets() throws {
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: password)
        assertArchiveError(data, expected: .passwordRequired)
        assertArchiveError(data, password: "", expected: .passwordRequired)
        assertArchiveError(data, password: "wrong-password", expected: .authenticationFailed)
        let tampered = try mutateJSON(data) { object in
            var sealed = Data(base64Encoded: object["sealed"] as! String)!
            sealed[sealed.count - 1] ^= 1
            object["sealed"] = sealed.base64EncodedString()
        }
        assertArchiveError(tampered, password: password, expected: .authenticationFailed)
    }

    func testEmptyAndShortEncryptionPasswordsAreRejected() {
        for value in ["", "short", "1234567"] {
            XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: workspace(), password: value)) { error in
                XCTAssertEqual(error.localizedDescription, WorkspaceArchiveError.passwordTooShort.localizedDescription)
            }
        }
    }

    func testEncryptionParametersAreBoundedBeforePasswordDerivation() throws {
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: password)
        for (field, value) in [("iterations", 1), ("iterations", Int.max), ("version", 2)] {
            let changed = try mutateJSON(data) { $0[field] = value }
            assertArchiveError(changed, password: password, expected: .unsupportedVersion)
        }
        let weakAlgorithm = try mutateJSON(data) { $0["algorithm"] = "AES-CBC" }
        assertArchiveError(weakAlgorithm, password: password, expected: .unsupportedVersion)
        let invalidSalt = try mutateJSON(data) { $0["salt"] = Data([1, 2, 3]).base64EncodedString() }
        assertArchiveError(invalidSalt, password: password, expected: .invalidArchive)
    }

    func testBackupVersionAndSchemaCannotSilentlyCreateEmptyWorkspace() throws {
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: nil)
        assertArchiveError(try mutateJSON(data) { $0["version"] = 2 }, expected: .unsupportedVersion)
        assertArchiveError(try mutateJSON(data) { $0["version"] = true }, expected: .invalidArchive)
        assertArchiveError(try mutateJSON(data) { $0["workspace"] = [:] }, expected: .invalidArchive)
        assertArchiveError(Data("{}".utf8), expected: .invalidArchive)
        assertArchiveError(Data("[]".utf8), expected: .invalidArchive)
        assertArchiveError(Data("not JSON".utf8), expected: .invalidArchive)
        assertArchiveError(try mutateJSON(data) { $0["unknown-schema"] = 1 }, expected: .invalidArchive)
        for field in ["preferences", "groups", "tags", "bookmarks", "trustedKeys", "logs", "recentTargets"] {
            let changed = try mutateJSON(data) { object in
                var workspace = object["workspace"] as! [String: Any]
                workspace[field] = NSNull(); object["workspace"] = workspace
            }
            assertArchiveError(changed, expected: .invalidArchive)
        }
        for incomplete in [true, false] {
            let changed = try mutateJSON(data) { object in
                var workspace = object["workspace"] as! [String: Any]
                var preferences = workspace["preferences"] as! [String: Any]
                if incomplete { preferences = [:] }
                else { preferences["fontSize"] = NSNull() }
                workspace["preferences"] = preferences; object["workspace"] = workspace
            }
            assertArchiveError(changed, expected: .invalidArchive)
        }
    }

    func testPlainSecretDictionaryIsNeverImported() throws {
        let original = workspace()
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: nil)
        let changed = try mutateJSON(data) { object in
            object["secrets"] = [original.credentials[0].id.uuidString: ["secret": "fixture", "privateKey": "fixture"]]
        }
        assertArchiveError(changed, expected: .invalidArchive)
    }

    func testMalformedAndMissingUUIDsCannotBeRegeneratedDuringRestore() throws {
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: nil)
        for field in ["hosts", "credentials", "groupDefaults", "forwards", "snippets"] {
            for missing in [false, true] {
                let changed = try mutateJSON(data) { object in
                    var workspace = object["workspace"] as! [String: Any]
                    var values = workspace[field] as! [[String: Any]]
                    if missing { values[0].removeValue(forKey: "id") }
                    else { values[0]["id"] = "malformed-id" }
                    workspace[field] = values; object["workspace"] = workspace
                }
                assertArchiveError(changed, expected: .invalidArchive)
            }
        }
    }

    func testDanglingReferencesAndDuplicateIDsAreRejectedBeforeEncoding() {
        var original = workspace()
        original.hosts[0].credentialID = UUID()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.hosts[0].jumpHostID = UUID()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.groupDefaults[0].credentialID = UUID()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.groupDefaults[0].jumpHostID = UUID()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.forwards[0].hostID = UUID()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.groupDefaults = []
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.credentials[0].id = original.hosts[0].id
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
    }

    func testDecodeAlsoRejectsDanglingReferencesAndJumpCycles() throws {
        let original = workspace()
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: nil)
        let missing = try mutateJSON(data) { object in
            var workspace = object["workspace"] as! [String: Any]
            var hosts = workspace["hosts"] as! [[String: Any]]
            hosts[0]["credentialID"] = UUID().uuidString
            workspace["hosts"] = hosts; object["workspace"] = workspace
        }
        assertArchiveError(missing, expected: .invalidReference)
        let cycle = try mutateJSON(data) { object in
            var workspace = object["workspace"] as! [String: Any]
            var hosts = workspace["hosts"] as! [[String: Any]]
            hosts[0]["jumpHostID"] = original.hosts[1].id.uuidString
            workspace["hosts"] = hosts; object["workspace"] = workspace
        }
        XCTAssertThrowsError(try WorkspaceArchiveCodec.decode(cycle, password: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cycle"))
        }
    }

    func testSecretsForUnknownIDsAndOversizedPrivateKeysAreRejected() {
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: workspace(), password: password,
                                                            secrets: [UUID(): Secrets.Value(secret: "fixture")])) { error in
            XCTAssertEqual(error.localizedDescription, WorkspaceArchiveError.invalidReference.localizedDescription)
        }
        let original = workspace()
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: password,
                                                            secrets: [original.credentials[0].id: Secrets.Value(privateKey: String(repeating: "x", count: 128 * 1024 + 1))]))
        // A secret for a removed identity cannot make an otherwise normal plain
        // export fail: plain exports intentionally never inspect credential bytes.
        XCTAssertNoThrow(try WorkspaceArchiveCodec.encode(workspace: original, password: nil,
                                                         secrets: [UUID(): Secrets.Value(secret: "fixture")]))
    }

    func testInvalidPortsHostsAndForwardingConfigurationAreRejected() {
        var original = workspace(); original.hosts[0].address = "https://example.invalid"
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.groupDefaults[0].port = 65536
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.forwards[0].targetPort = 0
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
        original = workspace(); original.snippets[0].body = "command\u{1b}[31m"
        XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: original, password: nil))
    }

    func testOversizedInputIsRejectedBeforeJSONOrCryptoProcessing() {
        let data = Data(repeating: 0, count: WorkspaceArchiveCodec.maximumBytes + 1)
        assertArchiveError(data, expected: .tooLarge)
        XCTAssertFalse(WorkspaceArchiveCodec.isEncrypted(data))
    }

    func testPreferenceValidationRejectsUnsafeValuesButAllowsOtherMacFontsAndPaths() throws {
        let original = workspace()
        var cases: [Preferences] = []
        var value = original.preferences; value.fontSize = .infinity; cases.append(value)
        value = original.preferences; value.fontSize = 0; cases.append(value)
        value = original.preferences; value.scrollback = 1_000_001; cases.append(value)
        value = original.preferences; value.sshConnectTimeout = 0; cases.append(value)
        value = original.preferences; value.language = "unknown"; cases.append(value)
        value = original.preferences; value.applicationIcon = "unknown"; cases.append(value)
        value = original.preferences; value.cursorShape = "unknown"; cases.append(value)
        value = original.preferences; value.bellStyle = "unknown"; cases.append(value)
        value = original.preferences; value.terminalTheme = "unknown"; cases.append(value)
        value = original.preferences; value.foreground = "#12345"; cases.append(value)
        value = original.preferences; value.ansiColors = ["#112233"]; cases.append(value)
        value = original.preferences; value.localShell = "/bin/zsh\n"; cases.append(value)
        value = original.preferences; value.localDirectory = "/tmp\0"; cases.append(value)
        for preferences in cases {
            var invalid = original; invalid.preferences = preferences
            XCTAssertThrowsError(try WorkspaceArchiveCodec.encode(workspace: invalid, password: nil))
        }
        var portable = original
        portable.preferences.fontName = "A font only installed on the originating Mac"
        portable.preferences.localShell = "/an-absent-fixture-directory/custom-shell"
        portable.preferences.localDirectory = "/an-absent-fixture-directory/home"
        let data = try WorkspaceArchiveCodec.encode(workspace: portable, password: nil)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(data, password: nil).workspace.preferences, portable.preferences)
        let badNumber = try mutateJSON(data) { object in
            var workspace = object["workspace"] as! [String: Any]
            var preferences = workspace["preferences"] as! [String: Any]
            preferences["fontSize"] = 1e100
            workspace["preferences"] = preferences; object["workspace"] = workspace
        }
        XCTAssertThrowsError(try WorkspaceArchiveCodec.decode(badNumber, password: nil))
    }

    func testNoncanonicalSecretIDsCannotSilentlyLoseCredentialBytes() {
        var original = workspace()
        original.credentials[0].id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        original.groupDefaults[0].credentialID = original.credentials[0].id
        let id = original.credentials[0].id.uuidString.lowercased()
        let archive = WorkspaceArchive(workspace: original, secrets: [id: ArchiveSecret(secret: "fixture", privateKey: "")])
        XCTAssertThrowsError(try WorkspaceArchiveCodec.validate(archive)) { error in
            XCTAssertEqual(error.localizedDescription, WorkspaceArchiveError.invalidReference.localizedDescription)
        }
    }

    @MainActor func testRestoreCommitsWorkspaceAndCredentialsAndMetadataOnlyRestoreClearsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-archive-test-" + UUID().uuidString)
        let original = workspace()
        let ids = Set(original.hosts.map(\.id) + original.credentials.map(\.id) + original.groupDefaults.map(\.id))
        defer {
            for id in ids { try? Secrets.saveCredential(Secrets.Value(), id: id) }
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.applicationIconController = nil
        store.workspace = original
        XCTAssertTrue(store.save())
        let credentialID = original.credentials[0].id
        try Secrets.saveCredential(Secrets.Value(secret: "old-password-fixture", privateKey: "old-private-key-fixture"), id: credentialID)
        try Secrets.saveCredential(Secrets.Value(secret: "unused-host-override-fixture"), id: original.hosts[1].id)
        var replacement = original
        replacement.hosts[1].name = "Restored application"
        replacement.preferences.fontSize = 24
        let data = try WorkspaceArchiveCodec.encode(workspace: replacement, password: password,
                                                    secrets: [credentialID: Secrets.Value(secret: "restored-passphrase-fixture", privateKey: "restored-private-key-fixture")])
        let archive = try WorkspaceArchiveCodec.decode(data, password: password)
        try store.restoreArchive(archive)
        XCTAssertEqual(store.workspace.hosts, replacement.hosts)
        XCTAssertEqual(store.workspace.preferences, replacement.preferences)
        XCTAssertEqual(store.workspace.groupDefaults, replacement.groupDefaults)
        XCTAssertEqual(store.workspace.credentials, replacement.credentials)
        XCTAssertEqual(store.workspace.snippets, replacement.snippets)
        XCTAssertTrue(store.workspace.logs.isEmpty); XCTAssertTrue(store.workspace.recentTargets.isEmpty)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(saved.hosts, replacement.hosts); XCTAssertEqual(saved.preferences, replacement.preferences)
        XCTAssertEqual(try Secrets.readCredential(credentialID).secret, "restored-passphrase-fixture")
        XCTAssertEqual(try Secrets.readCredential(credentialID).privateKey, "restored-private-key-fixture")
        XCTAssertEqual(try Secrets.readCredential(original.hosts[1].id).secret, "")
        XCTAssertEqual(GroupDefaults.secretID(for: store.workspace.hosts[1], workspace: store.workspace), credentialID)

        let encryptedExport = try store.archiveData(password: password, includeSecrets: true)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(encryptedExport, password: password).secrets?[credentialID.uuidString],
                       ArchiveSecret(secret: "restored-passphrase-fixture", privateKey: "restored-private-key-fixture"))
        let plain = try store.archiveData(password: nil, includeSecrets: false)
        let metadataOnly = try WorkspaceArchiveCodec.decode(plain, password: nil)
        XCTAssertNil(metadataOnly.secrets)
        try store.restoreArchive(metadataOnly)
        XCTAssertEqual(store.workspace.hosts, replacement.hosts)
        XCTAssertEqual(store.workspace.credentials[0].keySource, "text")
        for id in ids {
            let value = try Secrets.readCredential(id)
            XCTAssertEqual(value.secret, ""); XCTAssertEqual(value.privateKey, "")
        }
    }

    @MainActor func testSecretInclusiveExportRestoresEveryCredentialOwnerAfterKeychainEntriesAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-archive-credential-owners-test-" + UUID().uuidString)
        var passwordHost = TabbyNative.Host()
        passwordHost.name = "Independent password"; passwordHost.address = "password.example.invalid"
        var keyHost = TabbyNative.Host()
        keyHost.name = "Independent pasted key"; keyHost.address = "key.example.invalid"
        keyHost.auth = "key"; keyHost.keySource = "text"
        var shared = VaultCredential()
        shared.name = "Shared pasted key"; shared.username = "deploy"; shared.auth = "key"; shared.keySource = "text"
        var sharedHost = TabbyNative.Host()
        sharedHost.name = "Shared identity host"; sharedHost.address = "shared.example.invalid"; sharedHost.credentialID = shared.id
        var ownGroup = HostGroup()
        ownGroup.name = "Own group password"; ownGroup.username = "group-user"
        var groupHost = TabbyNative.Host()
        groupHost.name = "Own group host"; groupHost.address = "group.example.invalid"
        groupHost.group = ownGroup.name; groupHost.groupInheritance = .all
        var sharedGroup = HostGroup()
        sharedGroup.name = "Shared group identity"; sharedGroup.credentialID = shared.id
        var sharedGroupHost = TabbyNative.Host()
        sharedGroupHost.name = "Shared group host"; sharedGroupHost.address = "group-shared.example.invalid"
        sharedGroupHost.group = sharedGroup.name; sharedGroupHost.groupInheritance = .all
        var original = Workspace()
        original.hosts = [passwordHost, keyHost, sharedHost, groupHost, sharedGroupHost]
        original.credentials = [shared]; original.groupDefaults = [ownGroup, sharedGroup]
        original.groups = [ownGroup.name, sharedGroup.name]
        let ids = Set(original.hosts.map(\.id) + original.credentials.map(\.id) + original.groupDefaults.map(\.id))
        let values: [UUID: ArchiveSecret] = [
            passwordHost.id: ArchiveSecret(secret: "independent-password-fixture", privateKey: ""),
            keyHost.id: ArchiveSecret(secret: "independent-passphrase-fixture", privateKey: "independent-pasted-key-fixture"),
            shared.id: ArchiveSecret(secret: "shared-passphrase-fixture", privateKey: "shared-pasted-key-fixture"),
            ownGroup.id: ArchiveSecret(secret: "own-group-password-fixture", privateKey: "")
        ]
        defer {
            for id in ids { try? Secrets.saveCredential(Secrets.Value(), id: id) }
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.applicationIconController = nil; store.workspace = original
        XCTAssertTrue(store.save())
        for (id, value) in values {
            try Secrets.saveCredential(Secrets.Value(secret: value.secret, privateKey: value.privateKey), id: id)
        }
        let data = try store.archiveData(password: password, includeSecrets: true)
        let archive = try WorkspaceArchiveCodec.decode(data, password: password)
        XCTAssertEqual(archive.secrets?.count, values.count)
        for (id, value) in values { XCTAssertEqual(archive.secrets?[id.uuidString], value) }
        let envelope = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(envelope.contains("password.example.invalid"))
        XCTAssertFalse(envelope.contains("independent-password-fixture"))
        XCTAssertFalse(envelope.contains("shared-pasted-key-fixture"))

        // Simulate a destination Mac with no credential items. This exercises
        // the real export and restore paths rather than merely the codec.
        for id in ids { try Secrets.saveCredential(Secrets.Value(), id: id) }
        store.workspace = Workspace(); XCTAssertTrue(store.save())
        try store.restoreArchive(archive)
        XCTAssertEqual(store.workspace.hosts, original.hosts)
        XCTAssertEqual(store.workspace.credentials, original.credentials)
        XCTAssertEqual(store.workspace.groupDefaults, original.groupDefaults)
        for id in ids {
            let restored = try Secrets.readCredential(id)
            XCTAssertEqual(restored.secret, values[id]?.secret ?? "")
            XCTAssertEqual(restored.privateKey, values[id]?.privateKey ?? "")
        }
        let expectedOwners = [passwordHost.id, keyHost.id, shared.id, ownGroup.id, shared.id]
        for (index, host) in store.workspace.hosts.enumerated() {
            let owner = GroupDefaults.secretID(for: host, workspace: store.workspace)
            XCTAssertEqual(owner, expectedOwners[index])
            let restored = try Secrets.readCredential(owner)
            XCTAssertEqual(restored.secret, values[owner]?.secret)
            XCTAssertEqual(restored.privateKey, values[owner]?.privateKey)
        }
        let disk = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(disk.hosts, original.hosts)
        XCTAssertEqual(disk.credentials, original.credentials)
        XCTAssertEqual(disk.groupDefaults, original.groupDefaults)
    }

    @MainActor func testEncryptedExportWithoutSecretsDoesNotPretendToRestoreStoredPasswordOrPastedKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-archive-no-secrets-test-" + UUID().uuidString)
        var host = TabbyNative.Host()
        host.name = "Metadata only key"; host.address = "metadata.example.invalid"; host.auth = "key"; host.keySource = "text"
        var original = Workspace(); original.hosts = [host]
        defer {
            try? Secrets.saveCredential(Secrets.Value(), id: host.id)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.applicationIconController = nil; store.workspace = original
        XCTAssertTrue(store.save())
        try Secrets.saveCredential(Secrets.Value(secret: "unexported-passphrase-fixture", privateKey: "unexported-pasted-key-fixture"), id: host.id)
        let data = try store.archiveData(password: password, includeSecrets: false)
        XCTAssertTrue(WorkspaceArchiveCodec.isEncrypted(data))
        let archive = try WorkspaceArchiveCodec.decode(data, password: password)
        XCTAssertEqual(archive.secrets, [:], "Encryption alone does not include connection credentials")
        try store.restoreArchive(archive)
        XCTAssertEqual(store.workspace.hosts[0].keySource, "text")
        let restored = try Secrets.readCredential(host.id)
        XCTAssertEqual(restored.secret, ""); XCTAssertEqual(restored.privateKey, "")
    }

    @MainActor func testFailedRestoreRollsBackWorkspaceAndBothKeychainValuesWhenDiskWriteFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-archive-rollback-test-" + UUID().uuidString)
        let directory = root.appendingPathComponent("read-only-workspace", isDirectory: true)
        let original = workspace()
        let ids = Set(original.hosts.map(\.id) + original.credentials.map(\.id) + original.groupDefaults.map(\.id))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            for id in ids { try? Secrets.saveCredential(Secrets.Value(), id: id) }
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.applicationIconController = nil
        store.workspace = original
        XCTAssertTrue(store.save())
        let originalDisk = try Data(contentsOf: store.fileURL)
        let memoryEncoder = JSONEncoder(); memoryEncoder.outputFormatting = [.sortedKeys]
        let originalMemory = try memoryEncoder.encode(store.workspace)
        var previous: [UUID: ArchiveSecret] = [:]
        for id in ids {
            let old = ArchiveSecret(secret: "old-secret-" + id.uuidString, privateKey: "old-key-" + id.uuidString)
            previous[id] = old
            try Secrets.saveCredential(Secrets.Value(secret: old.secret, privateKey: old.privateKey), id: id)
        }
        var replacement = original
        replacement.hosts[1].name = "Must not commit"
        replacement.preferences.fontSize = 24
        let data = try WorkspaceArchiveCodec.encode(workspace: replacement, password: password,
                                                    secrets: [original.credentials[0].id: Secrets.Value(secret: "replacement-secret-fixture", privateKey: "replacement-key-fixture")])
        let archive = try WorkspaceArchiveCodec.decode(data, password: password)
        // All archive Keychain changes occur before save. Deny writes in this
        // test's own directory to exercise the transaction's rollback path.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.restoreArchive(archive))
        XCTAssertEqual(try memoryEncoder.encode(store.workspace), originalMemory)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalDisk)
        for id in ids {
            let value = try Secrets.readCredential(id)
            XCTAssertEqual(value.secret, previous[id]?.secret)
            XCTAssertEqual(value.privateKey, previous[id]?.privateKey)
        }
    }

    @MainActor func testValidArchiveRestoresCorruptLocalWorkspaceAndPreservesOriginalBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-corrupt-restore-test-" + UUID().uuidString)
        let fileURL = root.appendingPathComponent("workspace.json")
        let replacement = workspace()
        let ids = Set(replacement.hosts.map(\.id) + replacement.credentials.map(\.id) + replacement.groupDefaults.map(\.id))
        defer {
            for id in ids { try? Secrets.saveCredential(Secrets.Value(), id: id) }
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("corrupt-workspace-fixture".utf8)
        try corrupt.write(to: fileURL)
        let store = AppStore(fileURL: fileURL); store.applicationIconController = nil
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.save(), "A normal save must preserve a workspace that failed to load")
        let data = try WorkspaceArchiveCodec.encode(workspace: replacement, password: nil)
        try store.restoreArchive(WorkspaceArchiveCodec.decode(data, password: nil))
        XCTAssertEqual(store.workspace.hosts, replacement.hosts)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: fileURL)).hosts, replacement.hosts)
        XCTAssertEqual(try Data(contentsOf: fileURL.appendingPathExtension("backup")), corrupt)
        XCTAssertTrue(store.save(), "Successful archive recovery must restore normal persistence")
    }

    @MainActor func testFailedCorruptWorkspaceRestoreKeepsOriginalFileAndLoadFailureProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-corrupt-rollback-test-" + UUID().uuidString)
        let directory = root.appendingPathComponent("read-only-workspace", isDirectory: true)
        let fileURL = directory.appendingPathComponent("workspace.json")
        let replacement = workspace()
        let ids = Set(replacement.hosts.map(\.id) + replacement.credentials.map(\.id) + replacement.groupDefaults.map(\.id))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            for id in ids { try? Secrets.saveCredential(Secrets.Value(), id: id) }
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("corrupt-workspace-fixture".utf8)
        try corrupt.write(to: fileURL)
        let store = AppStore(fileURL: fileURL); store.applicationIconController = nil
        let originalMemory = store.workspace.hosts
        let id = replacement.credentials[0].id
        try Secrets.saveCredential(Secrets.Value(secret: "existing-secret-fixture", privateKey: "existing-key-fixture"), id: id)
        let data = try WorkspaceArchiveCodec.encode(workspace: replacement, password: password,
                                                    secrets: [id: Secrets.Value(secret: "new-secret-fixture", privateKey: "new-key-fixture")])
        let archive = try WorkspaceArchiveCodec.decode(data, password: password)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.restoreArchive(archive))
        XCTAssertEqual(store.workspace.hosts, originalMemory)
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
        XCTAssertEqual(try Secrets.readCredential(id).secret, "existing-secret-fixture")
        XCTAssertEqual(try Secrets.readCredential(id).privateKey, "existing-key-fixture")
        // Even after writes are possible again, ordinary edits must not replace
        // the unreadable original following an unsuccessful archive recovery.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertFalse(store.save())
        XCTAssertThrowsError(try store.commitCredentials(replacement, changes: [:]))
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }
}
