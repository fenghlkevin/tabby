import XCTest
@testable import TabbyNative

final class ConnectionValidationTests: XCTestCase {
    private func host() -> TabbyNative.Host {
        var value = TabbyNative.Host(); value.name = "测试服务器"; value.address = "example.invalid"; value.username = "root"
        return value
    }
    func testNumericDraftKeepsInvalidInputAndNeverSubmitsOldValue() {
        var value = 22
        var draft = IntegerInputDraft(text: "22", range: 1...65535)
        for text in ["22abc", "", "0", "65536", "+22", "-22", "22.0", "2e2", " 22", "22 ", "２２", "٢٢", String(repeating: "9", count: 100)] {
            draft.apply(text, to: &value)
            XCTAssertEqual(draft.text, text)
            XCTAssertFalse(draft.valid, text)
            XCTAssertNil(draft.parsed, text)
            XCTAssertEqual(value, 22, "Invalid text must not replace the model value or become a valid draft")
        }
        draft.apply("0002200", to: &value)
        XCTAssertTrue(draft.valid); XCTAssertEqual(value, 2200)
        XCTAssertEqual(ConnectionValidation.integer("1", range: 1...65535), 1)
        XCTAssertEqual(ConnectionValidation.integer("65535", range: 1...65535), 65535)
        XCTAssertEqual(ConnectionValidation.integer("0", range: 0...1000000), 0)
        XCTAssertEqual(ConnectionValidation.integer("1000000", range: 0...1000000), 1000000)
        XCTAssertNil(ConnectionValidation.integer("1000001", range: 0...1000000))
    }
    func testAddressesAllowRealHostnamesIPv6AndRejectURLsPortsAndOptions() throws {
        for address in ["example.invalid", "internal-host", "service_cluster", "服务器.公司", "xn--fsqu00a.xn--55qx5d", "example.invalid.", "127.0.0.1"] {
            XCTAssertEqual(try ConnectionValidation.address(address), address)
        }
        XCTAssertEqual(try ConnectionValidation.address("  [::1]  "), "::1")
        XCTAssertEqual(try ConnectionValidation.address("[fe80::123%en0]"), "fe80::123%en0")
        for address in ["", " ", ".", "..", "a..b", "-host", "host-", "[example.invalid]", "[::1]:22", "host:22", "https://host", "/tmp/server", "host/path", "root@host", "host;command", "host name", "host\n", "\thost", "127.0.0.999", "fe80::1%", "fe80::1%en 0"] {
            XCTAssertThrowsError(try ConnectionValidation.address(address), address)
        }
        XCTAssertEqual(try ConnectionValidation.username("  DOMAIN\\用户  "), "DOMAIN\\用户")
        for value in ["", " ", "root user", "root\n", "\troot", "root\0"] { XCTAssertThrowsError(try ConnectionValidation.username(value), value) }
        for value in ["\n名称", "名称\n", "\t分组", "tag\0"] { XCTAssertThrowsError(try ConnectionValidation.label(value), value) }
        XCTAssertEqual(try ConnectionValidation.label("  中文 名称  "), "中文 名称")
        XCTAssertThrowsError(try ConnectionValidation.address("https://host", chinese: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("URL"))
        }
        XCTAssertEqual(try ConnectionValidation.keyPath("/tmp/My Private Keys/id key", required: true), "/tmp/My Private Keys/id key")
        XCTAssertThrowsError(try ConnectionValidation.keyPath("/tmp/key\n", required: true))
    }
    func testHostNormalizationAndCurrentSharedAuthentication() throws {
        var value = host(); value.name = "  生产服务器  "; value.group = "  运维 分组  "; value.tags = "  中文,api  "; value.address = "  [::1]  "; value.username = "  root  "
        let normalized = try ConnectionValidation.host(value, workspace: Workspace())
        XCTAssertEqual(normalized.name, "生产服务器"); XCTAssertEqual(normalized.group, "运维 分组"); XCTAssertEqual(normalized.tags, "中文,api")
        XCTAssertEqual(normalized.address, "::1"); XCTAssertEqual(normalized.username, "root")
        var identity = VaultCredential(); identity.name = "  共享身份  "; identity.username = "  deploy  "; identity.auth = "key"; identity.keySource = "text"
        var workspace = Workspace(); workspace.credentials = [identity]
        value.credentialID = identity.id; value.username = ""; value.auth = "unsupported"; value.keyPath = "\n"; value.keySource = "unknown"
        let shared = try ConnectionValidation.host(value, workspace: workspace)
        XCTAssertEqual(shared.username, "deploy"); XCTAssertEqual(shared.auth, "key"); XCTAssertEqual(shared.keySource, "text")
        XCTAssertEqual(RecentTargets.effectiveUsername(value, workspace: workspace), "deploy")
        workspace.credentials[0].username = "deploy user"
        XCTAssertThrowsError(try ConnectionValidation.host(value, workspace: workspace))
        workspace.credentials = []
        XCTAssertThrowsError(try ConnectionValidation.host(value, workspace: workspace))
        var keyIdentity = identity; keyIdentity.keySource = "file"; keyIdentity.keyPath = "/fixture/My Keys/id key"
        XCTAssertEqual(try ConnectionValidation.credential(keyIdentity).keyPath, keyIdentity.keyPath)
        keyIdentity.auth = "agent"; XCTAssertThrowsError(try ConnectionValidation.credential(keyIdentity))
    }
    func testJumpReferencesRejectMissingAndCyclicRoutes() throws {
        var first = host(), second = host(), third = host()
        var workspace = Workspace(); workspace.hosts = [first, second, third]
        first.jumpHostID = second.id; second.jumpHostID = third.id
        workspace.hosts = [first, second, third]
        XCTAssertNoThrow(try ConnectionValidation.host(first, workspace: workspace))
        third.jumpHostID = first.id; workspace.hosts = [first, second, third]
        XCTAssertThrowsError(try ConnectionValidation.host(first, workspace: workspace))
        first.jumpHostID = first.id; XCTAssertThrowsError(try ConnectionValidation.host(first, workspace: workspace))
        first.jumpHostID = UUID(); XCTAssertThrowsError(try ConnectionValidation.host(first, workspace: workspace))
    }
    func testAllQuickConnectionParsersUseTheSameStrictPortsAndAddresses() {
        for prefix in ["ssh root@example.invalid", "root@example.invalid", "ssh example.invalid", "example.invalid"] {
            XCTAssertEqual(parseLauncherQuickHost(prefix + " -p 65535")?.port, 65535)
            for port in ["+22", "-22", "22abc", "0", "65536", "２２", "2.2"] { XCTAssertNil(parseLauncherQuickHost(prefix + " -p " + port), prefix + " " + port) }
        }
        XCTAssertEqual(parseLauncherQuickHost("root@[::1] -p 22")?.address, "::1")
        XCTAssertEqual(parseLauncherQuickHost("ssh 服务器.公司 -p 22")?.address, "服务器.公司")
        for address in [".", "..", "host:22", "host/path", "https://host", "127.0.0.999"] { XCTAssertNil(parseLauncherQuickHost("ssh root@" + address), address) }
    }
    @MainActor func testInvalidMetadataStopsBeforeCredentialWritesOrConnectionCreation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(fileURL: folder.appendingPathComponent("workspace.json"))
        var invalid = host(); invalid.address = "host:22"
        XCTAssertThrowsError(try store.upsert(invalid, secret: "not-saved"))
        XCTAssertFalse(store.connectQuick(invalid)); XCTAssertTrue(store.sessions.isEmpty)
        let session = TerminalSession(host: invalid, store: store)
        XCTAssertThrowsError(try session.settings(for: invalid), "Metadata is checked before reading Keychain or opening a password prompt")
        invalid = host(); invalid.username = "root user"
        XCTAssertThrowsError(try store.upsert(invalid, secret: "not-saved"))
        invalid = host(); invalid.auth = "agent"
        XCTAssertThrowsError(try store.upsert(invalid, secret: "not-saved"))
        var identity = VaultCredential(); identity.name = "fixture"; identity.username = "user\n"
        XCTAssertThrowsError(try store.saveCredential(identity, secret: "not-saved"))
        XCTAssertTrue(store.workspace.hosts.isEmpty); XCTAssertTrue(store.workspace.credentials.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    @MainActor func testForwardSaveNormalizesAndInvalidStartHasNoSideEffects() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(fileURL: folder.appendingPathComponent("workspace.json"))
        let saved = host(); store.workspace.hosts = [saved]
        var rule = PortForwardRule(); rule.name = "  开发转发  "; rule.hostID = saved.id; rule.bindHost = "  [::1]  "; rule.targetHost = "  服务器.公司  "
        try store.saveForward(rule)
        XCTAssertEqual(store.workspace.forwards[0].name, "开发转发"); XCTAssertEqual(store.workspace.forwards[0].bindHost, "::1")
        let original = try Data(contentsOf: store.fileURL)
        rule.targetHost = "host:80"
        XCTAssertThrowsError(try store.saveForward(rule)); store.startForward(rule)
        XCTAssertTrue(store.forwardTasks.isEmpty); XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        rule.targetHost = "127.0.0.1"; rule.kind = "remote"; rule.bindHost = "*"
        XCTAssertNoThrow(try ConnectionValidation.forward(rule, workspace: store.workspace))
        rule.kind = "local"; XCTAssertThrowsError(try ConnectionValidation.forward(rule, workspace: store.workspace))
        rule.bindHost = "127.0.0.1"; rule.bindPort = 0; XCTAssertThrowsError(try rule.validate())
        rule.bindPort = 65535; rule.targetPort = 65535; XCTAssertNoThrow(try rule.validate())
        rule.hostID = UUID(); XCTAssertThrowsError(try ConnectionValidation.forward(rule, workspace: store.workspace))
    }
    @MainActor func testImportValidatesAllProfilesAndJumpRoutesBeforeWriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(fileURL: folder.appendingPathComponent("workspace.json"))
        let url = folder.appendingPathComponent("import.yaml")
        let prefix = """
        profiles:
          - id: first
            name: 合法服务器
            type: ssh
            options:
              host: example.invalid
              user: root
              password: must-not-write
        """
        for invalid in ["port: 22abc", "port: true", "host: host:22", "user: root user", "jumpHost: missing"] {
            try (prefix + "\n  - name: invalid\n    type: ssh\n    options:\n      host: other.invalid\n      user: test\n      " + invalid + "\n").write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.importTabby(url), invalid)
            XCTAssertTrue(store.workspace.hosts.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
        try """
        profiles:
          - id: first
            name: 生产服务器
            type: ssh
            options:
              host: "[::1]"
              port: "2222"
              user: " root "
              jumpHost: second
          - id: second
            name: 跳板
            type: ssh
            options:
              host: example.invalid
              user: root
        """.write(to: url, atomically: true, encoding: .utf8)
        try store.importTabby(url)
        XCTAssertEqual(store.workspace.hosts.count, 2)
        XCTAssertEqual(store.workspace.hosts[0].address, "::1"); XCTAssertEqual(store.workspace.hosts[0].username, "root")
        XCTAssertEqual(store.workspace.hosts[0].jumpHostID, store.workspace.hosts[1].id)
    }
}
