import XCTest
@testable import TabbyNative

final class GroupDefaultsTests: XCTestCase {
    private func host(group: String = "Servers", username: String = "legacy") -> TabbyNative.Host {
        var value = TabbyNative.Host(); value.address = "fixture.invalid"; value.name = "Fixture"
        value.username = username; value.group = group; value.port = 2200
        return value
    }

    func testLegacyStringGroupsAndMissingInheritanceKeepExistingValues() throws {
        var workspace = Workspace(); workspace.groups = ["Servers"]
        let legacy = host(); workspace.hosts = [legacy]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        json.removeValue(forKey: "groupDefaults")
        var decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.groups, ["Servers"]); XCTAssertTrue(decoded.groupDefaults.isEmpty)
        XCTAssertNil(decoded.hosts[0].groupInheritance)
        decoded.groupDefaults = [HostGroup(name: "Servers", port: 2222, username: "deploy")]
        XCTAssertEqual(GroupDefaults.resolved(decoded.hosts[0], workspace: decoded), legacy)
        XCTAssertEqual(try ConnectionValidation.host(decoded.hosts[0], workspace: decoded), legacy)
    }

    func testInheritedFieldsAndExplicitOverridesResolveSharedGroupAuthAndJump() throws {
        var credential = VaultCredential(); credential.name = "Shared"; credential.username = "group-login"
        credential.auth = "key"; credential.keySource = "text"
        var jump = host(group: ""); jump.address = "jump.invalid"
        let group = HostGroup(name: "Servers", port: 2222, username: "deploy", credentialID: credential.id, jumpHostID: jump.id)
        var workspace = Workspace(); workspace.credentials = [credential]; workspace.groupDefaults = [group]; workspace.hosts = [jump]
        var value = host(group: "servers"); value.port = 0; value.username = ""
        value.groupInheritance = .all
        let inherited = try ConnectionValidation.host(value, workspace: workspace)
        XCTAssertEqual(inherited.port, 2222); XCTAssertEqual(inherited.username, "group-login")
        XCTAssertEqual(inherited.auth, "key"); XCTAssertEqual(inherited.keySource, "text")
        XCTAssertEqual(inherited.jumpHostID, jump.id); XCTAssertNil(inherited.credentialID)
        XCTAssertNil(inherited.groupInheritance); XCTAssertEqual(GroupDefaults.secretID(for: value, workspace: workspace), credential.id)
        value.groupInheritance?.username = false; value.username = "host-login"
        value.groupInheritance?.port = false; value.port = 2201
        value.groupInheritance?.jumpHost = false; value.jumpHostID = nil
        let override = try ConnectionValidation.host(value, workspace: workspace)
        XCTAssertEqual(override.username, "host-login"); XCTAssertEqual(override.port, 2201); XCTAssertNil(override.jumpHostID)
        XCTAssertEqual(override.auth, "key")
        value.groupInheritance?.authentication = false; value.auth = "password"
        XCTAssertEqual(try ConnectionValidation.host(value, workspace: workspace).auth, "password")
        XCTAssertEqual(GroupDefaults.secretID(for: value, workspace: workspace), value.id)
    }

    @MainActor func testGroupRenameAndDissolutionPreserveProfileReuseWithoutReusingChangedEndpointOrIndependentIdentity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var base = HostGroup(name: "Servers", port: 2222, username: "deploy", auth: "key", keyPath: "/fixture/key")
        var original = host(); original.groupInheritance = .all
        store.workspace.hosts = [original]; store.workspace.groupDefaults = [base]
        let session = TerminalSession(host: original, store: store); session.connected = true
        base.name = "Production"; store.workspace.groupDefaults = [base]; store.workspace.hosts[0].group = base.name
        XCTAssertTrue(RecentTargets.canReuseProfile(original, store.workspace.hosts[0], workspace: store.workspace))
        XCTAssertTrue(session.matchesEndpoint(store.workspace.hosts[0]))
        var retained = store.resolvedHost(store.workspace.hosts[0]); retained.group = ""
        store.workspace.groupDefaults = []; store.workspace.hosts = [retained]
        XCTAssertTrue(RecentTargets.canReuseProfile(original, retained, workspace: store.workspace))
        XCTAssertTrue(session.matchesEndpoint(retained))
        retained.port = 2223; store.workspace.hosts = [retained]
        XCTAssertFalse(session.matchesEndpoint(retained), "The actual connected port must still guard reuse")
        var independent = original; independent.groupInheritance?.authentication = false
        var shared = VaultCredential(); shared.name = "New shared identity"; shared.username = independent.username
        var requested = independent; requested.group = "Renamed"; requested.credentialID = shared.id
        store.workspace.credentials = [shared]; store.workspace.hosts = [requested]
        XCTAssertFalse(RecentTargets.canReuseProfile(independent, requested, workspace: store.workspace), "A group rename must not conceal an independent identity change")
        var legacy = independent; legacy.groupInheritance = nil
        requested.group = legacy.group; store.workspace.hosts = [requested]
        XCTAssertFalse(RecentTargets.canReuseProfile(legacy, requested, workspace: store.workspace))
        session.connected = false
    }

    @MainActor func testSaveAndRenameRetainInheritanceAndGroupKeychainIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var group = HostGroup(name: "Servers", port: 2222, username: "deploy")
        var value = host(); value.groupInheritance = .all
        defer { try? Secrets.saveCredential(.init(), id: group.id); try? Secrets.saveCredential(.init(), id: value.id) }
        try store.upsertGroup(group, secret: "group-fixture-password")
        try store.upsert(value, secret: "must-not-save-inherited-secret")
        XCTAssertEqual(store.workspace.hosts.first?.groupInheritance, .all)
        XCTAssertEqual(store.workspace.hosts.first?.port, value.port)
        XCTAssertTrue(try Secrets.readChecked(value.id).isEmpty)
        XCTAssertEqual(store.resolvedHost(value).username, "deploy")
        store.group = "Servers"
        group.name = "Production"
        try store.upsertGroup(group, secret: "group-fixture-password")
        XCTAssertEqual(store.workspace.hosts[0].group, "Production"); XCTAssertEqual(store.group, "Production")
        XCTAssertEqual(store.groupDefaults(named: "production")?.id, group.id)
        let session = TerminalSession(host: value, store: store)
        let settings = try session.settings(for: value, authenticationPrompt: { _ in XCTFail("Inherited saved auth should not prompt"); throw CancellationError() })
        XCTAssertEqual(settings.port, 2222); XCTAssertEqual(session.settingsUsername(for: value), "deploy")
        try store.renameGroup("production", to: "SERVERS")
        XCTAssertEqual(store.groupDefaults(named: "servers")?.id, group.id)
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.workspace.hosts[0].groupInheritance, .all)
        XCTAssertEqual(loaded.groupSecretID(for: loaded.workspace.hosts[0]), group.id)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("group-fixture-password")); XCTAssertFalse(json.contains("must-not-save"))
    }

    @MainActor func testDeletingGroupMaterializesMetadataAndSecretsWithoutChangingOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let group = HostGroup(name: "Servers", port: 2222, username: "deploy")
        var inherited = host(); inherited.groupInheritance = .all
        var override = host(username: "operator"); override.address = "override.invalid"
        defer {
            for id in [group.id, inherited.id, override.id] { try? Secrets.saveCredential(.init(), id: id) }
        }
        try store.upsertGroup(group, secret: "base-fixture-password")
        try store.upsert(inherited, secret: "")
        try store.upsert(override, secret: "override-fixture-password")
        store.group = "Servers"
        try store.removeGroup("servers")
        let retained = try XCTUnwrap(store.workspace.hosts.first { $0.id == inherited.id })
        XCTAssertEqual(retained.username, "deploy"); XCTAssertEqual(retained.port, 2222)
        XCTAssertEqual(retained.group, ""); XCTAssertNil(retained.groupInheritance)
        XCTAssertEqual(try Secrets.readChecked(retained.id), "base-fixture-password")
        XCTAssertEqual(try Secrets.readChecked(override.id), "override-fixture-password")
        XCTAssertEqual(store.workspace.hosts.first { $0.id == override.id }?.username, "operator")
        XCTAssertTrue(try Secrets.readChecked(group.id).isEmpty)
        XCTAssertTrue(store.workspace.groupDefaults.isEmpty); XCTAssertEqual(store.group, "")
        let loaded = AppStore(fileURL: store.fileURL)
        let session = TerminalSession(host: inherited, store: loaded)
        XCTAssertEqual(try session.settings(for: inherited).port, 2222)
        XCTAssertEqual(session.settingsUsername(for: inherited), "deploy")
    }

    @MainActor func testFailedGroupSaveAndDeleteRollBackSecretsMetadataAndSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory"); try Data("original".utf8).write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        var group = HostGroup(name: "Servers", port: 2222, username: "deploy")
        var inherited = host(); inherited.groupInheritance = .all
        defer { try? Secrets.saveCredential(.init(), id: group.id); try? Secrets.saveCredential(.init(), id: inherited.id) }
        try Secrets.save("base-before", id: group.id); try Secrets.save("host-before", id: inherited.id)
        store.workspace.groupDefaults = [group]; store.workspace.groups = [group.name]; store.workspace.hosts = [inherited]; store.group = group.name
        let before = store.workspace
        group.name = "Renamed"; group.username = "changed"
        XCTAssertThrowsError(try store.upsertGroup(group, secret: "base-after"))
        XCTAssertEqual(store.workspace.groupDefaults, before.groupDefaults); XCTAssertEqual(store.workspace.hosts, before.hosts)
        XCTAssertEqual(try Secrets.readChecked(group.id), "base-before"); XCTAssertEqual(store.group, "Servers")
        XCTAssertThrowsError(try store.removeGroup("Servers"))
        XCTAssertEqual(store.workspace.groupDefaults, before.groupDefaults); XCTAssertEqual(store.workspace.hosts, before.hosts)
        XCTAssertEqual(try Secrets.readChecked(group.id), "base-before")
        XCTAssertEqual(try Secrets.readChecked(inherited.id), "host-before"); XCTAssertEqual(store.group, "Servers")
        XCTAssertEqual(try String(contentsOf: blocker), "original")
    }

    @MainActor func testRemovingSharedCredentialKeepsGroupInheritedLoginWorking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var shared = VaultCredential(); shared.name = "Shared"; shared.username = "deploy"
        // An explicitly chosen shared identity replaces stale own-auth fields.
        let group = HostGroup(name: "Servers", username: "", auth: "key", keyPath: "", keySource: "file", credentialID: shared.id)
        var inherited = host(); inherited.groupInheritance = .all
        defer { for id in [shared.id, group.id, inherited.id] { try? Secrets.saveCredential(.init(), id: id) } }
        try store.saveCredential(shared, secret: "shared-fixture-password")
        try store.upsertGroup(group, secret: "ignored")
        XCTAssertEqual(store.workspace.groupDefaults.first?.username, "deploy")
        XCTAssertEqual(store.workspace.groupDefaults.first?.auth, "password")
        XCTAssertTrue(try Secrets.readChecked(group.id).isEmpty)
        try store.upsert(inherited, secret: "")
        try store.removeCredential(shared.id)
        XCTAssertNil(store.workspace.groupDefaults.first?.credentialID)
        XCTAssertEqual(store.resolvedHost(inherited).username, "deploy")
        XCTAssertEqual(try Secrets.readChecked(group.id), "shared-fixture-password")
        XCTAssertTrue(try Secrets.readChecked(shared.id).isEmpty)
        let session = TerminalSession(host: inherited, store: store)
        XCTAssertNoThrow(try session.settings(for: inherited, authenticationPrompt: { _ in XCTFail("Copied group identity should not prompt"); throw CancellationError() }))
    }

    @MainActor func testDeletingPrivateKeyGroupCopiesKeyMaterialToEachInheritedHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL = root.appendingPathComponent("fixture-key")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", keyURL.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let group = HostGroup(name: "Servers", username: "deploy", auth: "key", keySource: "text")
        var first = host(); first.groupInheritance = .all
        var second = host(); second.address = "second.invalid"; second.groupInheritance = .all
        second.groupInheritance?.username = false; second.username = "operator"
        defer { for id in [group.id, first.id, second.id] { try? Secrets.saveCredential(.init(), id: id) } }
        try store.upsertGroup(group, secret: "", privateKey: key)
        try store.upsert(first, secret: ""); try store.upsert(second, secret: "")
        try store.removeGroup(group.name)
        for host in store.workspace.hosts {
            XCTAssertEqual(host.auth, "key"); XCTAssertEqual(host.keySource, "text")
            XCTAssertEqual(try Secrets.readPrivateKey(host.id), PrivateKeys.normalize(key))
            XCTAssertNil(host.groupInheritance)
            XCTAssertNoThrow(try TerminalSession(host: host, store: store).settings(for: host, authenticationPrompt: { _ in XCTFail("Copied valid private key should not prompt"); throw CancellationError() }))
        }
        XCTAssertEqual(store.workspace.hosts.last?.username, "operator")
        XCTAssertTrue(try Secrets.readPrivateKey(group.id).isEmpty)
        XCTAssertFalse(try String(contentsOf: store.fileURL, encoding: .utf8).contains("BEGIN OPENSSH PRIVATE KEY"))
    }

    @MainActor func testGroupJumpCycleIsRejectedBeforeAnySecretWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var value = host(); value.groupInheritance = .all
        let group = HostGroup(name: "Servers", jumpHostID: value.id)
        store.workspace.hosts = [value]; store.workspace.groups = [group.name]
        defer { try? Secrets.saveCredential(.init(), id: group.id) }
        try Secrets.save("before", id: group.id)
        XCTAssertThrowsError(try store.upsertGroup(group, replacing: "Servers", secret: "after"))
        XCTAssertTrue(store.workspace.groupDefaults.isEmpty)
        XCTAssertEqual(try Secrets.readChecked(group.id), "before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @MainActor func testRememberingConnectionAuthCreatesHostOverrideAndLeavesBaseUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let group = HostGroup(name: "Servers", port: 2222, username: "deploy")
        var value = host(); value.groupInheritance = .all
        defer { try? Secrets.saveCredential(.init(), id: group.id); try? Secrets.saveCredential(.init(), id: value.id) }
        try store.upsertGroup(group, secret: "")
        try store.upsert(value, secret: "")
        let session = TerminalSession(host: value, store: store)
        _ = try session.settings(for: value, authenticationPrompt: { original in
            var draft = original; draft.host.username = "operator"; draft.secret = "host-fixture-password"; draft.remember = true
            return try draft.validatedResult(workspace: store.workspace, chinese: false)
        })
        let saved = try XCTUnwrap(store.workspace.hosts.first)
        XCTAssertEqual(saved.groupInheritance?.authentication, false); XCTAssertEqual(saved.groupInheritance?.username, false)
        XCTAssertEqual(saved.groupInheritance?.port, true); XCTAssertEqual(saved.groupInheritance?.jumpHost, true)
        XCTAssertEqual(store.resolvedHost(saved).username, "operator"); XCTAssertEqual(store.resolvedHost(saved).port, 2222)
        XCTAssertEqual(try Secrets.readChecked(value.id), "host-fixture-password")
        XCTAssertTrue(try Secrets.readChecked(group.id).isEmpty); XCTAssertEqual(store.workspace.groupDefaults.first, group)
    }
}
