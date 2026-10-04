import XCTest
@testable import TabbyNative

final class HostTransferTests: XCTestCase {
    private func parse(_ source: String, _ format: HostImportFormat) throws -> HostImportDocument {
        try HostTransfer.parse(Data(source.utf8), format: format)
    }
    private func fixture() -> Workspace {
        var jump = TabbyNative.Host(); jump.name = "Jump, \"中文\""; jump.address = "2001:db8::1"
        jump.username = "bastion"; jump.port = 2200; jump.group = "Production"; jump.favorite = true
        var destination = TabbyNative.Host(); destination.name = "service #1"; destination.address = "example.invalid"
        destination.username = "deploy"; destination.port = 2222; destination.group = "Production"; destination.tags = "web, prod"
        destination.auth = "key"; destination.keyPath = "/tmp/a key #with \"quotes\".pem"; destination.jumpHostID = jump.id
        var workspace = Workspace(); workspace.hosts = [jump, destination]; return workspace
    }
    func testTabbyAndCSVExportsRoundTripNamesKeysAndJumps() throws {
        let workspace = fixture()
        for format in [HostExportFormat.tabby, .csv] {
            let encoded = try HostTransfer.export(workspace, format: format)
            let decoded = try HostTransfer.parse(encoded, format: format == .csv ? .csv : .tabby)
            XCTAssertEqual(decoded.hosts.count, 2)
            XCTAssertEqual(decoded.hosts.map(\.name), workspace.hosts.map(\.name))
            XCTAssertEqual(decoded.hosts.map(\.address), workspace.hosts.map(\.address))
            XCTAssertEqual(decoded.hosts.map(\.username), workspace.hosts.map(\.username))
            XCTAssertEqual(decoded.hosts.map(\.port), workspace.hosts.map(\.port))
            XCTAssertEqual(decoded.hosts.map(\.tags), workspace.hosts.map(\.tags))
            XCTAssertEqual(decoded.hosts[1].keyPath, workspace.hosts[1].keyPath)
            XCTAssertEqual(decoded.hosts[1].jumpHostID, decoded.hosts[0].id)
            XCTAssertTrue(decoded.secrets.isEmpty)
        }
    }
    func testOpenSSHExportQuotesKeyPathsAndUsesUniqueSafeAliases() throws {
        var workspace = fixture()
        workspace.hosts[0].name = "same alias"; workspace.hosts[1].name = "same alias"
        let encoded = try HostTransfer.export(workspace, format: .openssh)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("Host same-alias\n"))
        XCTAssertTrue(text.contains("Host same-alias-2\n"))
        let decoded = try HostTransfer.parse(encoded, format: .openssh)
        XCTAssertEqual(decoded.hosts.count, 2)
        XCTAssertEqual(decoded.hosts[1].keyPath, workspace.hosts[1].keyPath)
        XCTAssertEqual(decoded.hosts[1].jumpHostID, decoded.hosts[0].id)
        XCTAssertEqual(decoded.hosts[0].address, "2001:db8::1")
    }
    func testExportsFlattenGroupAndSharedCredentialDefaultsWithoutSecrets() throws {
        var workspace = fixture()
        var credential = VaultCredential(); credential.name = "Shared"; credential.username = "shared"
        credential.auth = "key"; credential.keyPath = "/tmp/shared key.pem"
        var group = HostGroup(); group.name = "Production"; group.port = 4444; group.credentialID = credential.id
        workspace.credentials = [credential]; workspace.groupDefaults = [group]
        workspace.hosts[0].groupInheritance = .all
        workspace.hosts[1].credentialID = credential.id
        for format in HostExportFormat.allCases {
            let encoded = try HostTransfer.export(workspace, format: format)
            let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            XCTAssertFalse(text.contains("credentialID")); XCTAssertFalse(text.contains("groupInheritance"))
            XCTAssertFalse(text.contains(credential.id.uuidString)); XCTAssertFalse(text.contains(group.id.uuidString))
            let parsed = try HostTransfer.parse(encoded, format: format == .tabby ? .tabby : format == .csv ? .csv : .openssh)
            XCTAssertEqual(parsed.hosts[0].username, "shared"); XCTAssertEqual(parsed.hosts[0].port, 4444)
            XCTAssertEqual(parsed.hosts[0].keyPath, credential.keyPath)
            XCTAssertEqual(parsed.hosts[1].username, "shared")
            XCTAssertTrue(parsed.secrets.isEmpty)
        }
    }
    func testPastedKeyProfilesExportMetadataOnly() throws {
        var workspace = fixture()
        workspace.hosts[1].keySource = "text"; workspace.hosts[1].keyPath = "must-not-export-stale-path"
        for format in HostExportFormat.allCases {
            let encoded = try HostTransfer.export(workspace, format: format)
            let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            XCTAssertFalse(text.contains("must-not-export-stale-path")); XCTAssertFalse(text.contains("privateKey"))
            let document = try HostTransfer.parse(encoded, format: format == .tabby ? .tabby : format == .csv ? .csv : .openssh)
            XCTAssertEqual(document.hosts[1].auth, "password"); XCTAssertEqual(document.hosts[1].keyPath, "")
        }
    }
    func testTabbyResolvesGroupIDsAndImportsPasswordToSeparateSecretMap() throws {
        let document = try parse("""
        groups:
          - id: group-id
            name: Production
        profiles:
          - id: jump
            name: jump
            type: ssh
            group: group-id
            options: { host: jump.invalid, user: tester }
          - id: target
            name: target
            type: ssh
            options:
              host: target.invalid
              port: '2222'
              user: deploy
              password: password-only-in-secret-map
              jumpHost: jump
          - type: local
            name: ignored
        """, .tabby)
        XCTAssertEqual(document.hosts.count, 2)
        XCTAssertEqual(document.hosts[0].group, "Production")
        XCTAssertEqual(document.hosts[1].jumpHostID, document.hosts[0].id)
        XCTAssertEqual(document.secrets[document.hosts[1].id]?.secret, "password-only-in-secret-map")
    }
    func testOpenSSHHonorsFirstValueWildcardDefaultsAndMatchExclusion() throws {
        let document = try parse("""
        Host * !ignored
            User global
        Host web alias
            HostName = example.invalid # comment
            Port=2222
            User later-will-not-win
            IdentityFile "/tmp/a # key.pem"
            IdentityFile /tmp/second.pem
        Host ignored
            HostName ignored.invalid
            User specific
        Match exec "touch /tmp/must-not-execute"
            User must-not-import
        Host after
            HostName after.invalid
        Include /tmp/must-not-read
        """, .openssh)
        XCTAssertEqual(document.hosts.map(\.name), ["web", "alias", "ignored", "after"])
        XCTAssertEqual(document.hosts.map(\.username), ["global", "global", "specific", "global"])
        XCTAssertEqual(document.hosts[0].port, 2222)
        XCTAssertEqual(document.hosts[0].keyPath, "/tmp/a # key.pem")
        XCTAssertTrue(document.warnings.contains { $0.contains("Match") })
        XCTAssertTrue(document.warnings.contains { $0.contains("Include") })
        XCTAssertTrue(document.warnings.contains { $0.contains("first IdentityFile") })
    }
    func testOpenSSHMultiHopAndIPv6ProxyJump() throws {
        let document = try parse("""
        Host gateway
            HostName gateway.invalid
            User first
        Host web
            HostName web.invalid
            ProxyJump gateway,jump@[2001:db8::2]:2222
        """, .openssh)
        let gateway = document.hosts[0], web = document.hosts[1], secondHop = document.hosts[2]
        XCTAssertEqual(web.jumpHostID, secondHop.id)
        XCTAssertEqual(secondHop.jumpHostID, gateway.id)
        XCTAssertEqual(secondHop.username, "jump"); XCTAssertEqual(secondHop.port, 2222)
        XCTAssertEqual(secondHop.address, "2001:db8::2")
    }
    func testOpenSSHNamedJumpOverridesRetainItsRouteRegardlessOfFileOrder() throws {
        let document = try parse("""
        Host target
            HostName target.invalid
            ProxyJump override@gateway:2222
        Host gateway
            HostName gateway.invalid
            ProxyJump first
        Host first
            HostName first.invalid
        """, .openssh)
        let first = document.hosts[2], override = document.hosts[3]
        XCTAssertEqual(override.username, "override")
        XCTAssertEqual(override.port, 2222)
        XCTAssertEqual(override.jumpHostID, first.id)
        XCTAssertEqual(document.hosts[0].jumpHostID, override.id)
    }
    func testCSVAcceptsTermiusColumnsAndQuotedNames() throws {
        let document = try parse("""
        Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password,SSH_KEY
        Production,"A, ""quoted"" host","prod, web",example.invalid,ssh,2222,deploy,secret,ignored-key-name
        Other,Non SSH,,telnet.invalid,telnet,23,user,,
        """, .csv)
        XCTAssertEqual(document.hosts.count, 1)
        XCTAssertEqual(document.hosts[0].name, "A, \"quoted\" host")
        XCTAssertEqual(document.hosts[0].group, "Production")
        XCTAssertEqual(document.hosts[0].tags, "prod, web")
        XCTAssertEqual(document.secrets[document.hosts[0].id]?.secret, "secret")
        XCTAssertTrue(document.warnings.contains { $0.contains("Unrecognized") })
        XCTAssertTrue(document.warnings.contains { $0.contains("Non-SSH") })
    }
    func testPuTTYUTF16RegistryDecodesSessionAndPortWithoutExecutingRegistry() throws {
        let registry = #"""
        Windows Registry Editor Version 5.00
        [HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Production%20host]
        "HostName"="example.invalid"
        "PortNumber"=dword:000008ae
        "UserName"="deploy"
        "Protocol"="ssh"
        "PublicKeyFile"="C:\\keys\\deploy.ppk"
        "ProxyMethod"=dword:00000001
        [HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\telnet]
        "HostName"="telnet.invalid"
        "Protocol"="telnet"
        "PortNumber"=dword:00000017
        """#
        let data = try XCTUnwrap(registry.data(using: .utf16))
        let document = try HostTransfer.parse(data, format: .putty)
        XCTAssertEqual(document.hosts.count, 1); XCTAssertEqual(document.hosts[0].name, "Production host")
        XCTAssertEqual(document.hosts[0].port, 2222); XCTAssertEqual(document.hosts[0].username, "deploy")
        XCTAssertEqual(document.hosts[0].keyPath, "")
        XCTAssertTrue(document.warnings.contains { $0.contains(".ppk") })
        XCTAssertTrue(document.warnings.contains { $0.contains("proxy") })
    }
    func testRejectsInvalidPortsAndFieldsBeforeStorage() throws {
        for value in ["0", "65536", "-1", "22oops", "9999999999999999999999"] {
            XCTAssertThrowsError(try parse("hostname,port\nexample.invalid,\(value)\n", .csv))
            XCTAssertThrowsError(try parse("Host sample\n HostName example.invalid\n Port \(value)\n", .openssh))
            XCTAssertThrowsError(try parse("profiles: [{type: ssh, options: {host: example.invalid, port: '\(value)'}}]", .tabby))
        }
        XCTAssertEqual(try parse("profiles: [{type: ssh, options: {host: example.invalid, port: 1}}]", .tabby).hosts[0].port, 1)
        XCTAssertThrowsError(try parse("profiles: [{type: ssh, options: {host: example.invalid, port: true}}]", .tabby))
        XCTAssertThrowsError(try parse("hostname,username\nexample.invalid,user name\n", .csv))
        XCTAssertThrowsError(try parse("hostname,port\nhttps://example.invalid,22\n", .csv))
        XCTAssertThrowsError(try parse("hostname,label\nexample.invalid,\"name\nnewline\"\n", .csv))
        XCTAssertThrowsError(try parse("hostname,label\nexample.invalid,\"unterminated", .csv))
    }
    func testRejectsJumpCyclesAndMissingJumpReferences() throws {
        XCTAssertThrowsError(try parse("""
        id,hostname,jump_host
        first,first.invalid,second
        second,second.invalid,first
        """, .csv))
        XCTAssertThrowsError(try parse("hostname,jump_host\nexample.invalid,missing\n", .csv))
        XCTAssertThrowsError(try parse("Host self\n ProxyJump self\n", .openssh))
    }
}
