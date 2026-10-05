import XCTest
@testable import TabbyNative

@MainActor final class AutomaticBackupTests: XCTestCase {
    private let password = "automatic-backup-password-fixture"

    private func fixture() throws -> (root: URL, folder: URL, store: AppStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-automatic-backup-test-" + UUID().uuidString)
        let folder = root.appendingPathComponent("SelectedBackupFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.applicationIconController = nil
        var host = TabbyNative.Host()
        host.name = "Automatic backup fixture"
        host.address = "backup-fixture.example.invalid"
        host.username = "fixture"
        store.workspace.hosts = [host]
        store.workspace.logs = [ActivityLog(category: "SSH", event: "Connected", host: "history-must-be-excluded", failed: false)]
        store.workspace.recentTargets = [RecentTarget(kind: .ssh, hostID: host.id)]
        XCTAssertTrue(store.save())
        return (root, folder, store)
    }

    private func backupFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "axonbackup" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func cloudConfiguration() -> CloudConnectionSettings {
        CloudConnectionSettings(s3: S3BackupConfiguration(endpoint: "https://backup.example.invalid", region: "us-east-1",
                                                         bucket: "backups", objectKey: "Manual/keep-this-object.axonbackup",
                                                         accessKeyID: "public-key-fixture"))
    }

    private func folderSettings(_ folder: URL) throws -> AutomaticBackupSettings {
        let selected = try AutomaticBackupPersistence.chooseFolder(folder)
        var settings = AutomaticBackupSettings()
        settings.folderEnabled = true
        settings.folderBookmark = selected.bookmark
        settings.folderPath = selected.path
        return settings
    }

    func testNewFilePolicyRetainsTwoAutomaticFolderAndS3BackupsAtIdenticalTime() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try folderSettings(fixture.folder); settings.s3Enabled = true
        var cloud = cloudConfiguration(); cloud.createNewFile = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloud, folder: fixture.folder, password: password)
        var dependencies = harness.dependencies(); dependencies.now = { Date(timeIntervalSince1970: 0) }
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: dependencies)
        coordinator.runNow(); await coordinator.waitUntilFinished()
        coordinator.runNow(); await coordinator.waitUntilFinished()
        let files = try backupFiles(in: fixture.folder)
        XCTAssertEqual(files.count, 2); XCTAssertEqual(Set(harness.uploads.map { $0.configuration.objectKey }).count, 2)
        XCTAssertTrue(harness.uploads.allSatisfy { $0.configuration.objectKey.hasPrefix("Axon/Automatic/Axon-19700101") })
        for file in files { XCTAssertEqual(try WorkspaceArchiveCodec.decode(Data(contentsOf: file), password: password).workspace.hosts, fixture.store.workspace.hosts) }
    }

    func testMissingSettingsDefaultOffAndMalformedMetadataDoesNotResetToEnabledDefaults() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = try AutomaticBackupPersistence.load(workspaceURL: fixture.store.fileURL)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.includeSecrets)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL).path))
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticBackupSettings.self, from: encoded), settings)
        let corrupt = Data("{\"folderEnabled\":true,broken".utf8)
        try corrupt.write(to: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL))
        XCTAssertThrowsError(try AutomaticBackupPersistence.load(workspaceURL: fixture.store.fileURL))
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        var dependencies = harness.dependencies()
        dependencies.loadSettings = { try AutomaticBackupPersistence.load(workspaceURL: $0) }
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: dependencies)
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        XCTAssertNotNil(coordinator.report.generalMessage)
        XCTAssertEqual(harness.passwordReads, 0)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertTrue(harness.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL)), corrupt)
    }

    func testSavedPasswordIsOnlyInKeychainBlankPreservesItAndDisablingClearsIt() throws {
        let fixture = try fixture()
        var settings = try folderSettings(fixture.folder)
        defer {
            try? Secrets.save("", id: settings.passwordID)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try AutomaticBackupPersistence.save(settings, password: password, workspaceURL: fixture.store.fileURL)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), password)
        settings.includeSecrets = true
        try AutomaticBackupPersistence.save(settings, password: "", workspaceURL: fixture.store.fileURL)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), password)
        XCTAssertEqual(try AutomaticBackupPersistence.load(workspaceURL: fixture.store.fileURL), settings)
        let metadata = try String(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL), encoding: .utf8)
        XCTAssertFalse(metadata.contains(password))
        settings.folderEnabled = false
        try AutomaticBackupPersistence.save(settings, password: "", workspaceURL: fixture.store.fileURL)
        XCTAssertFalse(try AutomaticBackupPersistence.load(workspaceURL: fixture.store.fileURL).isEnabled)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), "")
    }

    func testFailedSettingsWriteRestoresPreviousKeychainPasswordAndMetadata() throws {
        let fixture = try fixture()
        var settings = try folderSettings(fixture.folder)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
            try? Secrets.save("", id: settings.passwordID)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try AutomaticBackupPersistence.save(settings, password: password, workspaceURL: fixture.store.fileURL)
        let before = try Data(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL))
        settings.includeSecrets = true
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        XCTAssertThrowsError(try AutomaticBackupPersistence.save(settings, password: "replacement-password-fixture", workspaceURL: fixture.store.fileURL))
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), password)
        XCTAssertEqual(try Data(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL)), before)
    }

    func testInvalidTargetsAndShortPasswordsCannotSaveOrReplaceSavedPassword() throws {
        let fixture = try fixture()
        var settings = try folderSettings(fixture.folder)
        let cloud = cloudConfiguration()
        defer {
            try? Secrets.save("", id: settings.passwordID)
            try? Secrets.save("", id: cloud.id)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try AutomaticBackupPersistence.save(settings, password: password, workspaceURL: fixture.store.fileURL)
        let original = try Data(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL))
        XCTAssertThrowsError(try AutomaticBackupPersistence.save(settings, password: "short", workspaceURL: fixture.store.fileURL))
        settings.folderBookmark = nil
        XCTAssertThrowsError(try AutomaticBackupPersistence.save(settings, password: "replacement-password-fixture", workspaceURL: fixture.store.fileURL))
        settings.folderEnabled = false
        settings.s3Enabled = true
        var invalidCloud = cloud
        invalidCloud.s3.endpoint = "http://untrusted.example.invalid"
        try CloudConnectionPersistence.save(invalidCloud, secret: "s3-secret-fixture", workspaceURL: fixture.store.fileURL)
        XCTAssertThrowsError(try AutomaticBackupPersistence.save(settings, password: "replacement-password-fixture", workspaceURL: fixture.store.fileURL))
        try CloudConnectionPersistence.save(cloud, secret: "s3-secret-fixture", workspaceURL: fixture.store.fileURL)
        settings.s3Prefix = "Backups/../escape"
        XCTAssertThrowsError(try AutomaticBackupPersistence.save(settings, password: "replacement-password-fixture", workspaceURL: fixture.store.fileURL))
        XCTAssertEqual(try Data(contentsOf: AutomaticBackupPersistence.url(workspaceURL: fixture.store.fileURL)), original)
        XCTAssertEqual(try Secrets.readChecked(settings.passwordID), password)
    }

    func testRealEncryptedFolderBackupRunsOncePerLaunchAndReplacesSameFileOnRestart() async throws {
        let fixture = try fixture()
        let settings = try folderSettings(fixture.folder)
        defer {
            try? Secrets.save("", id: settings.passwordID)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try AutomaticBackupPersistence.save(settings, password: password, workspaceURL: fixture.store.fileURL)
        let first = AutomaticBackupCoordinator(store: fixture.store)
        first.startAtLaunch()
        first.startAtLaunch()
        first.runNow()
        await first.waitUntilFinished()
        let originalFiles = try backupFiles(in: fixture.folder)
        XCTAssertEqual(originalFiles.count, 1)
        XCTAssertEqual(originalFiles.first?.lastPathComponent, "Axon-latest.axonbackup")
        let originalBytes = try Data(contentsOf: XCTUnwrap(originalFiles.first))
        first.startAtLaunch()
        await first.waitUntilFinished()
        XCTAssertEqual(try Data(contentsOf: originalFiles[0]), originalBytes)
        XCTAssertTrue(WorkspaceArchiveCodec.isEncrypted(originalBytes))
        let archive = try WorkspaceArchiveCodec.decode(originalBytes, password: password)
        XCTAssertEqual(archive.workspace.hosts, fixture.store.workspace.hosts)
        XCTAssertTrue(archive.workspace.logs.isEmpty)
        XCTAssertTrue(archive.workspace.recentTargets.isEmpty)
        XCTAssertTrue(archive.secrets?.isEmpty ?? true)
        XCTAssertThrowsError(try WorkspaceArchiveCodec.decode(originalBytes, password: "wrong-password-fixture"))
        XCTAssertEqual(first.report.folder?.succeeded, true)
        fixture.store.workspace.hosts[0].name = "Updated before the next launch"
        XCTAssertTrue(fixture.store.save())
        let restartedStore = AppStore(fileURL: fixture.store.fileURL)
        let second = AutomaticBackupCoordinator(store: restartedStore)
        second.startAtLaunch()
        await second.waitUntilFinished()
        let files = try backupFiles(in: fixture.folder)
        XCTAssertEqual(files, originalFiles, "Later launches must update the same file")
        let updatedBytes = try Data(contentsOf: files[0])
        XCTAssertNotEqual(updatedBytes, originalBytes)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(updatedBytes, password: password).workspace.hosts, fixture.store.workspace.hosts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path), ["Axon-latest.axonbackup"],
                       "Successful replacement must leave one completed file and no temporary files")
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try AutomaticBackupPersistence.loadReport(workspaceURL: fixture.store.fileURL), second.report)
        let reportText = try String(contentsOf: AutomaticBackupPersistence.statusURL(workspaceURL: fixture.store.fileURL), encoding: .utf8)
        XCTAssertFalse(reportText.contains(password))
        XCTAssertFalse(reportText.contains(fixture.store.workspace.hosts[0].address))
    }

    func testS3BackupsUpdateFixedKeyUnderAutomaticPrefixWithoutChangingManualObjectKey() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = AutomaticBackupSettings()
        settings.s3Enabled = true
        settings.s3Prefix = "Custom/LaunchBackups"
        let cloud = cloudConfiguration()
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloud, folder: fixture.folder, password: password)
        for run in 0..<2 {
            fixture.store.workspace.hosts[0].name = "Automatic S3 snapshot \(run)"
            let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
            coordinator.startAtLaunch()
            await coordinator.waitUntilFinished()
            XCTAssertEqual(coordinator.report.s3?.succeeded, true)
        }
        let uploads = harness.uploads
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0].configuration.objectKey, uploads[1].configuration.objectKey)
        XCTAssertNotEqual(uploads[0].data, uploads[1].data)
        for (run, upload) in uploads.enumerated() {
            XCTAssertEqual(upload.configuration.objectKey, "Custom/LaunchBackups/Axon-latest.axonbackup")
            XCTAssertEqual(upload.configuration.endpoint, cloud.s3.endpoint)
            XCTAssertEqual(upload.secret, "s3-secret-fixture")
            XCTAssertTrue(WorkspaceArchiveCodec.isEncrypted(upload.data))
            XCTAssertEqual(try WorkspaceArchiveCodec.decode(upload.data, password: password).workspace.hosts.first?.name,
                           "Automatic S3 snapshot \(run)")
        }
        XCTAssertEqual(harness.cloud.s3.objectKey, "Manual/keep-this-object.axonbackup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudConnectionPersistence.url(workspaceURL: fixture.store.fileURL).path))
    }

    func testFailedFolderReplacementPreservesPreviousBackupAndCleansTemporaryFile() throws {
        let fixture = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let destination = fixture.folder.appendingPathComponent(AutomaticBackupPersistence.filename())
        let original = try WorkspaceArchiveCodec.encode(workspace: fixture.store.workspace, password: password)
        try AutomaticBackupPersistence.writeBackup(original, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        XCTAssertThrowsError(try AutomaticBackupPersistence.writeBackup(Data("incomplete replacement".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path), [destination.lastPathComponent])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path)
        let blockedDestination = fixture.folder.appendingPathComponent("blocked.axonbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDestination, withIntermediateDirectories: false)
        let marker = blockedDestination.appendingPathComponent("original")
        try original.write(to: marker)
        XCTAssertThrowsError(try AutomaticBackupPersistence.writeBackup(Data("replacement".utf8), to: blockedDestination))
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).contains { $0.hasPrefix(".axon-backup-") })
    }

    func testFolderFailureDoesNotPreventS3BackupAndBothResultsPersist() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try folderSettings(fixture.folder)
        settings.s3Enabled = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        harness.folderFailure = true
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.report.folder?.succeeded, false)
        XCTAssertEqual(coordinator.report.s3?.succeeded, true)
        XCTAssertEqual(harness.uploads.count, 1)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertEqual(try AutomaticBackupPersistence.loadReport(workspaceURL: fixture.store.fileURL), coordinator.report)
        XCTAssertFalse(try String(contentsOf: AutomaticBackupPersistence.statusURL(workspaceURL: fixture.store.fileURL), encoding: .utf8).contains(password))
    }

    func testS3FailurePreservesSuccessfulFolderBackup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try folderSettings(fixture.folder)
        settings.s3Enabled = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        harness.uploadFailure = true
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.report.folder?.succeeded, true)
        XCTAssertEqual(coordinator.report.s3?.succeeded, false)
        let files = try backupFiles(in: fixture.folder)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(Data(contentsOf: files[0]), password: password).workspace.hosts, fixture.store.workspace.hosts)
        XCTAssertEqual(try AutomaticBackupPersistence.loadReport(workspaceURL: fixture.store.fileURL), coordinator.report)
    }

    func testDisabledTargetsDoNotReadPasswordsCredentialsOrWriteAnyBackup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let harness = AutomaticBackupHarness(settings: AutomaticBackupSettings(), cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(harness.passwordReads, 0)
        XCTAssertTrue(harness.credentialReads.isEmpty)
        XCTAssertTrue(harness.uploads.isEmpty)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertTrue(harness.savedReports.isEmpty)
        XCTAssertTrue(try backupFiles(in: fixture.folder).isEmpty)
    }

    func testUnreadableWorkspaceCannotBackUpReplacementDefaults() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = Data("{broken-workspace-fixture".utf8)
        try original.write(to: fixture.store.fileURL)
        let unreadable = AppStore(fileURL: fixture.store.fileURL)
        var settings = try folderSettings(fixture.folder)
        settings.s3Enabled = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        let coordinator = AutomaticBackupCoordinator(store: unreadable, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(harness.passwordReads, 0)
        XCTAssertTrue(harness.uploads.isEmpty)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertEqual(coordinator.report.folder?.succeeded, false)
        XCTAssertEqual(coordinator.report.s3?.succeeded, false)
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), original)
        XCTAssertTrue(try backupFiles(in: fixture.folder).isEmpty)
    }

    func testMissingShortOrUnavailablePasswordAndUnreadableCredentialsNeverWriteBackup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try folderSettings(fixture.folder)
        settings.s3Enabled = true
        for value in ["", "short", password] {
            let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: value)
            harness.passwordFailure = value == password
            let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
            coordinator.startAtLaunch()
            await coordinator.waitUntilFinished()
            XCTAssertEqual(coordinator.report.folder?.succeeded, false)
            XCTAssertEqual(coordinator.report.s3?.succeeded, false)
            XCTAssertEqual(harness.writeCalls, 0)
            XCTAssertTrue(harness.uploads.isEmpty)
            XCTAssertTrue(harness.credentialReads.isEmpty)
        }
        settings.includeSecrets = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        harness.credentialFailure = true
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.runNow()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.report.folder?.succeeded, false)
        XCTAssertEqual(coordinator.report.s3?.succeeded, false)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertTrue(harness.uploads.isEmpty)
        XCTAssertTrue(try backupFiles(in: fixture.folder).isEmpty)
    }

    func testIncludingSecretsPreservesCredentialValuesOnlyInsideEncryptedArchive() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var identity = VaultCredential()
        identity.name = "Private key fixture"
        identity.auth = "key"
        identity.keySource = "text"
        fixture.store.workspace.credentials = [identity]
        var group = HostGroup()
        group.name = "Production fixture"
        fixture.store.workspace.groups = [group.name]
        fixture.store.workspace.groupDefaults = [group]
        var settings = try folderSettings(fixture.folder)
        settings.includeSecrets = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        harness.credentials = [fixture.store.workspace.hosts[0].id: Secrets.Value(secret: "host-password-fixture"),
                               identity.id: Secrets.Value(secret: "key-passphrase-fixture", privateKey: "pasted-private-key-fixture"),
                               group.id: Secrets.Value(secret: "group-password-fixture")]
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        await coordinator.waitUntilFinished()
        let bytes = try Data(contentsOf: XCTUnwrap(try backupFiles(in: fixture.folder).first))
        let archive = try WorkspaceArchiveCodec.decode(bytes, password: password)
        XCTAssertEqual(archive.secrets?[identity.id.uuidString], ArchiveSecret(secret: "key-passphrase-fixture", privateKey: "pasted-private-key-fixture"))
        XCTAssertEqual(archive.secrets?[group.id.uuidString]?.secret, "group-password-fixture")
        XCTAssertEqual(archive.secrets?[fixture.store.workspace.hosts[0].id.uuidString]?.secret, "host-password-fixture")
        XCTAssertEqual(Set(harness.credentialReads), Set(harness.credentials.keys))
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in [password, "host-password-fixture", "key-passphrase-fixture", "pasted-private-key-fixture", "group-password-fixture"] {
            XCTAssertFalse(text.contains(forbidden))
            XCTAssertFalse(try String(contentsOf: AutomaticBackupPersistence.statusURL(workspaceURL: fixture.store.fileURL), encoding: .utf8).contains(forbidden))
        }
    }

    func testCancelStopsInFlightUploadAndRepeatedTriggersDoNotStartSecondRun() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = AutomaticBackupSettings()
        settings.s3Enabled = true
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        harness.waitForCancellation = true
        let coordinator = AutomaticBackupCoordinator(store: fixture.store, dependencies: harness.dependencies())
        coordinator.startAtLaunch()
        for _ in 0..<200 {
            if !harness.uploads.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(harness.uploads.count, 1)
        coordinator.runNow()
        coordinator.startAtLaunch()
        XCTAssertEqual(harness.passwordReads, 1)
        coordinator.cancel()
        coordinator.runNow()
        XCTAssertEqual(harness.uploads.count, 1)
        await coordinator.waitUntilFinished()
        for _ in 0..<200 {
            if harness.uploadCancellationObserved { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(harness.uploadCancellationObserved)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(harness.uploads.count, 1)
        XCTAssertNotNil(coordinator.report.generalMessage)
        XCTAssertTrue(harness.savedReports.isEmpty, "A cancelled upload must not publish a stale success result")
        harness.waitForCancellation = false
        coordinator.runNow()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(harness.uploads.count, 2)
        XCTAssertEqual(coordinator.report.s3?.succeeded, true)
        XCTAssertEqual(harness.savedReports.count, 1)
    }

    func testUnavailableBookmarkDoesNotFallBackToDisplayPathOrRecreateMissingFolder() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try folderSettings(fixture.folder)
        settings.folderBookmark = Data("not-a-folder-bookmark".utf8)
        let harness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        var dependencies = harness.dependencies()
        dependencies.resolveFolder = AutomaticBackupPersistence.resolveFolder
        let invalidBookmark = AutomaticBackupCoordinator(store: fixture.store, dependencies: dependencies)
        invalidBookmark.startAtLaunch()
        await invalidBookmark.waitUntilFinished()
        XCTAssertEqual(invalidBookmark.report.folder?.succeeded, false)
        XCTAssertEqual(harness.writeCalls, 0)
        XCTAssertTrue(try backupFiles(in: fixture.folder).isEmpty)
        settings = try folderSettings(fixture.folder)
        try FileManager.default.removeItem(at: fixture.folder)
        let missingHarness = AutomaticBackupHarness(settings: settings, cloud: cloudConfiguration(), folder: fixture.folder, password: password)
        var missingDependencies = missingHarness.dependencies()
        missingDependencies.resolveFolder = AutomaticBackupPersistence.resolveFolder
        let missing = AutomaticBackupCoordinator(store: fixture.store, dependencies: missingDependencies)
        missing.startAtLaunch()
        await missing.waitUntilFinished()
        XCTAssertEqual(missing.report.folder?.succeeded, false)
        XCTAssertEqual(missingHarness.writeCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
    }
}

private struct AutomaticBackupUpload {
    var data: Data
    var configuration: S3BackupConfiguration
    var secret: String
}

/// The coordinator does I/O on a detached worker. Keep fixture mutation behind
/// a lock so the tests observe the actual background execution safely.
private final class AutomaticBackupHarness: @unchecked Sendable {
    private let lock = NSLock()
    let settings: AutomaticBackupSettings
    let cloud: CloudConnectionSettings
    let folder: URL
    let password: String
    private var storedFolderFailure = false
    private var storedUploadFailure = false
    private var storedPasswordFailure = false
    private var storedCredentialFailure = false
    private var storedWaitForCancellation = false
    private var storedUploadCancellationObserved = false
    private var storedCredentials: [UUID: Secrets.Value] = [:]
    private var storedPasswordReads = 0
    private var storedCredentialReads: [UUID] = []
    private var storedWriteCalls = 0
    private var storedUploads: [AutomaticBackupUpload] = []
    private var storedReports: [AutomaticBackupReport] = []

    init(settings: AutomaticBackupSettings, cloud: CloudConnectionSettings, folder: URL, password: String) {
        self.settings = settings
        self.cloud = cloud
        self.folder = folder
        self.password = password
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var folderFailure: Bool { get { locked { storedFolderFailure } } set { locked { storedFolderFailure = newValue } } }
    var uploadFailure: Bool { get { locked { storedUploadFailure } } set { locked { storedUploadFailure = newValue } } }
    var passwordFailure: Bool { get { locked { storedPasswordFailure } } set { locked { storedPasswordFailure = newValue } } }
    var credentialFailure: Bool { get { locked { storedCredentialFailure } } set { locked { storedCredentialFailure = newValue } } }
    var waitForCancellation: Bool { get { locked { storedWaitForCancellation } } set { locked { storedWaitForCancellation = newValue } } }
    var credentials: [UUID: Secrets.Value] { get { locked { storedCredentials } } set { locked { storedCredentials = newValue } } }
    var passwordReads: Int { locked { storedPasswordReads } }
    var credentialReads: [UUID] { locked { storedCredentialReads } }
    var writeCalls: Int { locked { storedWriteCalls } }
    var uploads: [AutomaticBackupUpload] { locked { storedUploads } }
    var savedReports: [AutomaticBackupReport] { locked { storedReports } }
    var uploadCancellationObserved: Bool { locked { storedUploadCancellationObserved } }

    func dependencies() -> AutomaticBackupDependencies {
        var dependencies = AutomaticBackupDependencies()
        dependencies.loadSettings = { [self] _ in settings }
        dependencies.loadReport = { _ in AutomaticBackupReport() }
        dependencies.readPassword = { [self] id in
            locked { storedPasswordReads += 1 }
            guard id == settings.passwordID else { throw AppFailure.message("Unexpected password identity") }
            if passwordFailure { throw AppFailure.message("Keychain unavailable fixture") }
            return password
        }
        dependencies.readCredential = { [self] id in
            locked { storedCredentialReads.append(id) }
            if credentialFailure { throw AppFailure.message("Keychain unavailable fixture") }
            if id == cloud.id { return Secrets.Value(secret: "s3-secret-fixture") }
            return credentials[id] ?? Secrets.Value()
        }
        dependencies.loadCloudSettings = { [self] _ in cloud }
        dependencies.resolveFolder = { [self] _ in
            if folderFailure { throw AppFailure.message("Folder unavailable fixture") }
            return folder
        }
        dependencies.writeBackup = { [self] bytes, destination in
            locked { storedWriteCalls += 1 }
            try AutomaticBackupPersistence.writeBackup(bytes, to: destination)
        }
        dependencies.upload = { [self] bytes, configuration, secret in
            locked { storedUploads.append(AutomaticBackupUpload(data: bytes, configuration: configuration, secret: secret)) }
            if uploadFailure { throw S3BackupError.forbidden }
            if waitForCancellation {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch {
                    locked { storedUploadCancellationObserved = error is CancellationError }
                    throw error
                }
            }
        }
        dependencies.saveReport = { [self] report, workspaceURL in
            try AutomaticBackupPersistence.saveReport(report, workspaceURL: workspaceURL)
            locked { storedReports.append(report) }
        }
        return dependencies
    }
}
