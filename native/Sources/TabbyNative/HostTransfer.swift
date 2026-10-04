import Foundation
import CoreFoundation
import Yams

/// Parsers only read the selected document. They never follow Include files,
/// launch proxy commands, read key files, or touch the Keychain.
enum HostImportFormat: String, CaseIterable, Identifiable {
    case tabby, openssh, csv, putty
    var id: String { rawValue }
}

enum HostExportFormat: String, CaseIterable, Identifiable {
    case tabby, openssh, csv
    var id: String { rawValue }
}

struct HostImportDocument {
    var hosts: [Host]
    var secrets: [UUID: Secrets.Value] = [:]
    var warnings: [String] = []
}

enum HostTransfer {
    static func parse(_ data: Data, format: HostImportFormat) throws -> HostImportDocument {
        guard data.count <= 20 * 1024 * 1024 else { throw failure("The import file exceeds 20 MB") }
        let source = try decoded(data, registry: format == .putty)
        var document: HostImportDocument
        switch format {
        case .tabby: document = try parseTabby(source)
        case .openssh: document = try parseOpenSSH(source)
        case .csv: document = try parseCSV(source)
        case .putty: document = try parsePuTTY(source)
        }
        var workspace = Workspace()
        workspace.hosts = document.hosts
        for index in document.hosts.indices {
            document.hosts[index] = try ConnectionValidation.host(document.hosts[index], workspace: workspace)
        }
        document.warnings = Array(Set(document.warnings)).sorted()
        return document
    }

    /// Host metadata is portable. Passwords, passphrases, pasted private keys,
    /// Keychain IDs, group inheritance, and workspace settings are not exported.
    static func export(_ workspace: Workspace, format: HostExportFormat) throws -> Data {
        var hosts = try workspace.hosts.map { original -> Host in
            var host = try ConnectionValidation.host(original, workspace: workspace)
            host.credentialID = nil
            host.groupInheritance = nil
            if host.keySource == "text" {
                host.keyPath = ""
                host.keySource = nil
                host.auth = "password"
            }
            return try ConnectionValidation.host(host, workspace: workspace)
        }
        // Validate every resolved route against the same portable snapshot.
        var portable = Workspace(); portable.hosts = hosts
        hosts = try hosts.map { try ConnectionValidation.host($0, workspace: portable) }
        let value: String
        switch format {
        case .tabby: value = try exportTabby(hosts)
        case .openssh: value = exportOpenSSH(hosts)
        case .csv: value = exportCSV(hosts)
        }
        return Data(value.utf8)
    }

    private static func failure(_ text: String) -> AppFailure { .message(text) }
    private static func decoded(_ data: Data, registry: Bool) throws -> String {
        let value: String?
        if registry && (data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])) {
            value = String(data: data, encoding: .utf16)
        } else { value = String(data: data, encoding: .utf8) }
        guard var source = value, !source.contains("\0") else { throw failure("Use a UTF-8 file (PuTTY also supports UTF-16 registry exports)") }
        if source.hasPrefix("\u{feff}") { source.removeFirst() }
        return source
    }
    private static func port(_ raw: String, context: String) throws -> Int {
        guard let value = ConnectionValidation.integer(raw.trimmingCharacters(in: .whitespaces), range: 1...65535) else {
            throw failure("Invalid port for \(context); use an integer from 1 to 65535")
        }
        return value
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let text = raw as? String else { throw failure("Invalid \(key): expected text") }
        return text
    }

    private static func parseTabby(_ source: String) throws -> HostImportDocument {
        let loaded = try Yams.load(yaml: source)
        let profiles: [[String: Any]]
        var groups: [[String: Any]] = []
        var warnings: [String] = []
        if let root = loaded as? [String: Any], let list = root["profiles"] as? [[String: Any]] {
            profiles = list
            if let rawGroups = root["groups"] {
                guard let list = rawGroups as? [[String: Any]] else { throw failure("Invalid Tabby groups") }
                groups = list
            }
            if root["encrypted"] != nil || root["vault"] != nil { warnings.append("Encrypted Tabby vault contents are not imported.（不导入 Tabby 加密保险库内容。）") }
        } else if let list = loaded as? [[String: Any]] { profiles = list }
        else { throw failure("No profiles in the Tabby YAML configuration") }
        var hosts: [Host] = [], secrets: [UUID: Secrets.Value] = [:]
        var ids: [String: UUID] = [:], pending: [UUID: String] = [:]
        for profile in profiles {
            let type = try string(profile, "type") ?? "ssh"
            guard type == "ssh" else { continue }
            guard let options = profile["options"] as? [String: Any] else { throw failure("SSH profile is missing its options") }
            guard let address = try string(options, "host"), !address.isEmpty else { throw failure("SSH profile is missing its host address") }
            var host = Host()
            host.address = address; host.name = try string(profile, "name") ?? address
            host.username = try string(options, "user") ?? "root"
            if let raw = options["port"] {
                // Yams preserves YAML integers as Int and YAML booleans as Bool.
                let isBoolean = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                if let number = raw as? Int, !isBoolean, (1...65535).contains(number) { host.port = number }
                else if let value = raw as? String { host.port = try port(value, context: host.name) }
                else { throw failure("Invalid port for \(host.name)") }
            }
            let group = try string(profile, "group") ?? "Imported"
            host.group = try groups.first(where: { ($0["id"] as? String) == group }).flatMap { try string($0, "name") } ?? group
            if let keys = options["privateKeys"] {
                guard let paths = keys as? [String] else { throw failure("Invalid privateKeys: expected file paths") }
                host.keyPath = paths.first ?? ""
                if paths.count > 1 { warnings.append("Only the first private-key path is imported for each host.（每台主机仅导入第一个私钥路径。）") }
            }
            if let raw = profile["tags"] {
                if let tags = raw as? String { host.tags = tags }
                else if let tags = raw as? [String] { host.tags = TagTokens.serialized(tags) }
                else { throw failure("Invalid tags for \(host.name)") }
            }
            host.auth = host.keyPath.isEmpty ? "password" : "key"
            if let favorite = profile["favorite"] as? Bool { host.favorite = favorite }
            if let id = try string(profile, "id") {
                guard ids[id] == nil else { throw failure("Duplicate Tabby profile ID") }
                ids[id] = host.id
            }
            if let jump = try string(options, "jumpHost"), !jump.isEmpty { pending[host.id] = jump }
            if let password = try string(options, "password"), !password.isEmpty { secrets[host.id] = Secrets.Value(secret: password) }
            if options["proxyCommand"] != nil || options["agentForward"] != nil || options["forwardedPorts"] != nil || options["scripts"] != nil {
                warnings.append("Proxy commands, SSH agent settings, port forwarding, and login scripts are not imported.（不导入代理命令、SSH agent、端口转发和登录脚本。）")
            }
            hosts.append(host)
        }
        for index in hosts.indices {
            if let sourceID = pending[hosts[index].id] {
                guard let target = ids[sourceID] else { throw failure("Imported Tabby jump host was not found") }
                hosts[index].jumpHostID = target
            }
        }
        return HostImportDocument(hosts: hosts, secrets: secrets, warnings: warnings)
    }

    private struct SSHBlock {
        var patterns: [String] = []
        var directives: [(String, String)] = []
    }
    private static func parseOpenSSH(_ source: String) throws -> HostImportDocument {
        var blocks = [SSHBlock(patterns: ["*"])]
        var aliases: [String] = [], warnings: [String] = []
        var ignoringMatch = false
        for (lineIndex, line) in source.components(separatedBy: .newlines).enumerated() {
            let tokens = try sshTokens(line, line: lineIndex + 1)
            guard let first = tokens.first else { continue }
            let key = first.lowercased(), values = Array(tokens.dropFirst())
            if key == "host" {
                guard !values.isEmpty else { throw failure("Host is missing a pattern at line \(lineIndex + 1)") }
                ignoringMatch = false
                blocks.append(SSHBlock(patterns: values))
                for alias in values where !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?") {
                    if !aliases.contains(alias) { aliases.append(alias) }
                }
                continue
            }
            if key == "match" { ignoringMatch = true; warnings.append("Match blocks are ignored; review their connection settings after import.（已忽略 Match 条件块，请核对导入后的连接设置。）"); continue }
            if key == "include" { warnings.append("Include files are not read; import each referenced configuration separately.（不会读取 Include 引用文件，请分别导入。）"); continue }
            guard !ignoringMatch else { continue }
            let supported: Set<String> = ["hostname", "user", "port", "identityfile", "proxyjump"]
            guard supported.contains(key) else {
                warnings.append("OpenSSH directive \(first) is not imported.（未导入此 OpenSSH 配置项。）")
                continue
            }
            guard values.count == 1 else { throw failure("\(first) requires one value at line \(lineIndex + 1)") }
            blocks[blocks.count - 1].directives.append((key, values[0]))
        }
        var hosts: [Host] = [], ids: [String: UUID] = [:], pending: [UUID: String] = [:]
        for alias in aliases {
            var fields: [String: String] = [:]
            var keyCount = 0
            for block in blocks where sshMatches(alias, patterns: block.patterns) {
                for (key, value) in block.directives {
                    if key == "identityfile" { keyCount += 1 }
                    if fields[key] == nil { fields[key] = value }
                }
            }
            var host = Host()
            host.name = alias; host.address = fields["hostname"] ?? alias
            host.username = fields["user"] ?? NSUserName(); host.group = "OpenSSH"
            if let value = fields["port"] { host.port = try port(value, context: alias) }
            if let path = fields["identityfile"], path.lowercased() != "none" {
                if path.contains("%") || path.contains("${") {
                    warnings.append("OpenSSH IdentityFile tokens are not expanded; select a key file after import.（不会展开私钥路径中的占位符，请重新选择私钥文件。）")
                } else { host.keyPath = path; host.auth = "key" }
            }
            if keyCount > 1 { warnings.append("Only the first IdentityFile is imported for each host.（每台主机仅导入第一个 IdentityFile。）") }
            if let jump = fields["proxyjump"], jump.lowercased() != "none" { pending[host.id] = jump }
            ids[alias.lowercased()] = host.id; hosts.append(host)
        }
        // OpenSSH specifies the hop list in connection order; Host stores the
        // nearest hop first. Resolve named aliases before creating endpoint hops.
        var resolving = Set<UUID>(), resolved = Set<UUID>()
        func resolveRoute(_ targetID: UUID) throws {
            guard !resolved.contains(targetID), let raw = pending[targetID] else { return }
            guard resolving.insert(targetID).inserted else { throw failure("Jump hosts cannot contain a cycle") }
            defer { resolving.remove(targetID) }
            let route = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !route.isEmpty, route.allSatisfy({ !$0.isEmpty }) else { throw failure("Invalid ProxyJump route") }
            var previous: UUID?
            for specification in route {
                let endpoint = try jumpEndpoint(specification)
                let jumpID: UUID
                if let id = ids[endpoint.address.lowercased()] {
                    try resolveRoute(id)
                    guard let named = hosts.first(where: { $0.id == id }) else { throw failure("Jump alias was not found") }
                    if endpoint.user != nil || endpoint.port != nil {
                        var override = named; override.id = UUID(); override.name = specification
                        override.username = endpoint.user ?? named.username; override.port = endpoint.port ?? named.port
                        if let previous, let existing = named.jumpHostID, existing != previous {
                            throw failure("Conflicting ProxyJump routes for \(named.name)")
                        }
                        override.jumpHostID = previous ?? named.jumpHostID
                        hosts.append(override); jumpID = override.id
                    } else { jumpID = id }
                } else {
                    var jump = Host(); jump.name = specification
                    jump.address = endpoint.address; jump.username = endpoint.user ?? NSUserName()
                    jump.port = endpoint.port ?? 22; jump.group = "OpenSSH"
                    if let existing = hosts.first(where: { $0.address == jump.address && $0.port == jump.port && $0.username == jump.username }) { jumpID = existing.id }
                    else { hosts.append(jump); jumpID = jump.id }
                }
                if let previous, let index = hosts.firstIndex(where: { $0.id == jumpID }) {
                    if let existing = hosts[index].jumpHostID, existing != previous { throw failure("Conflicting ProxyJump routes for \(hosts[index].name)") }
                    hosts[index].jumpHostID = previous
                }
                previous = jumpID
            }
            if let index = hosts.firstIndex(where: { $0.id == targetID }) {
                if let existing = hosts[index].jumpHostID, existing != previous {
                    throw failure("Conflicting ProxyJump routes for \(hosts[index].name)")
                }
                hosts[index].jumpHostID = previous
            }
            resolved.insert(targetID)
        }
        for targetID in hosts.map(\.id) { try resolveRoute(targetID) }
        return HostImportDocument(hosts: hosts, warnings: warnings)
    }

    /// OpenSSH accepts keyword=value and keyword value, quoted strings, escaped
    /// quotes, and comments beginning with an unquoted #.
    private static func sshTokens(_ line: String, line number: Int) throws -> [String] {
        var result: [String] = [], token = "", quoted = false, escaped = false, active = false
        for char in line {
            if escaped { token.append(char); escaped = false; active = true; continue }
            if char == "\\" { escaped = true; active = true; continue }
            if char == "\"" { quoted.toggle(); active = true; continue }
            if !quoted && char == "#" { break }
            if !quoted && (char.isWhitespace || (char == "=" && (result.isEmpty || (result.count == 1 && !active)))) {
                if active { result.append(token); token = ""; active = false }
            } else { token.append(char); active = true }
        }
        guard !quoted, !escaped else { throw failure("Unclosed quote or escape in SSH configuration at line \(number)") }
        if active { result.append(token) }
        return result
    }
    private static func sshMatches(_ alias: String, patterns: [String]) -> Bool {
        var positive = false
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let pattern = negated ? String(raw.dropFirst()) : raw
            let regex = "^" + pattern.map { char -> String in
                if char == "*" { return ".*" }; if char == "?" { return "." }
                return NSRegularExpression.escapedPattern(for: String(char))
            }.joined() + "$"
            if alias.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
                if negated { return false }; positive = true
            }
        }
        return positive
    }
    private static func jumpEndpoint(_ raw: String) throws -> (address: String, user: String?, port: Int?) {
        let pieces = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count) else { throw failure("Invalid ProxyJump endpoint") }
        let user = pieces.count == 2 ? try ConnectionValidation.username(String(pieces[0])) : nil
        var endpoint = String(pieces.last!), parsedPort: Int?
        if endpoint.hasPrefix("[") {
            guard let closing = endpoint.firstIndex(of: "]") else { throw failure("Invalid bracketed IPv6 ProxyJump endpoint") }
            let suffix = endpoint[endpoint.index(after: closing)...]
            if !suffix.isEmpty {
                guard suffix.first == ":" else { throw failure("Invalid ProxyJump endpoint") }
                parsedPort = try port(String(suffix.dropFirst()), context: "ProxyJump")
            }
            endpoint = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closing])
        } else if endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.lastIndex(of: ":") {
            parsedPort = try port(String(endpoint[endpoint.index(after: colon)...]), context: "ProxyJump")
            endpoint = String(endpoint[..<colon])
        }
        return (try ConnectionValidation.address(endpoint), user, parsedPort)
    }

    private static func header(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func parseCSV(_ source: String) throws -> HostImportDocument {
        let rows = try csvRows(source)
        guard let headings = rows.first else { throw failure("CSV file is empty") }
        let keys = headings.map(header)
        guard Set(keys).count == keys.count else { throw failure("CSV has duplicate column names") }
        let addressNames = ["hostname", "hostnameip", "ipaddress", "address", "host", "ip"]
        guard keys.contains(where: { addressNames.contains($0) }) else { throw failure("CSV requires a hostname or Hostname/IP column") }
        var hosts: [Host] = [], secrets: [UUID: Secrets.Value] = [:], ids: [String: UUID] = [:], pending: [UUID: String] = [:], warnings: [String] = []
        let known = Set(addressNames + ["label", "alias", "name", "username", "user", "port", "group", "groups", "tags", "identityfile", "keypath", "privatekeyfile", "jumphost", "proxyjump", "id", "password", "protocol", "auth", "favorite"])
        if keys.contains(where: { !known.contains($0) }) { warnings.append("Unrecognized CSV columns are ignored (including key names, key text, scripts, and forwarding settings).（已忽略不支持的 CSV 列，包括密钥名称、私钥文本、脚本和转发设置。）") }
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.contains(where: { !$0.isEmpty }) else { continue }
            guard row.count == keys.count else { throw failure("CSV row \(offset + 2) has \(row.count) fields; expected \(keys.count)") }
            let fields = Dictionary(uniqueKeysWithValues: zip(keys, row))
            func field(_ names: [String]) -> String? { names.compactMap { fields[$0] }.first { !$0.isEmpty } }
            if let protocolName = field(["protocol"]), !["ssh", "ssh2"].contains(protocolName.lowercased()) {
                warnings.append("Non-SSH CSV rows are skipped.（已跳过非 SSH 的 CSV 记录。）"); continue
            }
            guard let address = field(addressNames) else { throw failure("CSV row \(offset + 2) has no hostname") }
            var host = Host(); host.address = address; host.name = field(["label", "alias", "name"]) ?? address
            host.username = field(["username", "user"]) ?? "root"
            if let value = field(["port"]) { host.port = try port(value, context: host.name) }
            host.group = field(["group", "groups"]) ?? "Imported"; host.tags = field(["tags"]) ?? ""
            host.keyPath = field(["identityfile", "keypath", "privatekeyfile"]) ?? ""
            host.auth = field(["auth"])?.lowercased() ?? (host.keyPath.isEmpty ? "password" : "key")
            if let favorite = field(["favorite"]) {
                guard ["true", "false", "1", "0"].contains(favorite.lowercased()) else { throw failure("Invalid CSV favorite value") }
                host.favorite = favorite.lowercased() == "true" || favorite == "1"
            }
            if let sourceID = field(["id"]) {
                guard ids[sourceID] == nil else { throw failure("Duplicate CSV host ID") }
                ids[sourceID] = host.id
            }
            if let jump = field(["jumphost", "proxyjump"]) { pending[host.id] = jump }
            if let password = field(["password"]) { secrets[host.id] = Secrets.Value(secret: password) }
            hosts.append(host)
        }
        for index in hosts.indices {
            if let reference = pending[hosts[index].id] {
                let named = hosts.filter { $0.name == reference }
                guard let jump = ids[reference] ?? (named.count == 1 ? named.first?.id : nil) else { throw failure("CSV jump host was not found or its name is ambiguous") }
                hosts[index].jumpHostID = jump
            }
        }
        return HostImportDocument(hosts: hosts, secrets: secrets, warnings: warnings)
    }

    /// RFC 4180 quoting, CRLF, escaped double quotes, and embedded newlines.
    /// Metadata validators reject control characters in names after tokenization.
    private static func csvRows(_ source: String) throws -> [[String]] {
        let chars = Array(source)
        var rows: [[String]] = [], row: [String] = [], value = "", quoted = false, closedQuote = false, i = 0
        func endField() { row.append(value); value = ""; closedQuote = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let char = chars[i]
            if quoted {
                if char == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { value.append("\""); i += 1 }
                    else { quoted = false; closedQuote = true }
                } else { value.append(char) }
            } else if char == "," { endField() }
            else if char == "\r" || char == "\n" || char == "\r\n" {
                endRow()
                if char == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else if char == "\"" {
                guard value.isEmpty && !closedQuote else { throw failure("Invalid quote in CSV") }; quoted = true
            } else {
                guard !closedQuote else { throw failure("Unexpected text after a quoted CSV field") }; value.append(char)
            }
            i += 1
        }
        guard !quoted else { throw failure("Unclosed quote in CSV") }
        if !row.isEmpty || !value.isEmpty || closedQuote { endRow() }
        return rows
    }

    private static func parsePuTTY(_ source: String) throws -> HostImportDocument {
        guard source.hasPrefix("Windows Registry Editor Version 5.00") || source.hasPrefix("REGEDIT4") else { throw failure("Select a PuTTY Windows registry export (.reg)") }
        var entries: [(String, [String: String])] = [], name: String?, fields: [String: String] = [:]
        func finish() { if let name { entries.append((name, fields)) }; name = nil; fields = [:] }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                finish()
                guard line.hasSuffix("]"), !line.hasPrefix("[-") else { continue }
                let registryPath = String(line.dropFirst().dropLast())
                let marker = "\\software\\simontatham\\putty\\sessions\\"
                if let range = registryPath.lowercased().range(of: marker) {
                    let session = String(registryPath[range.upperBound...])
                    guard !session.contains("\\") else { continue }
                    name = session.removingPercentEncoding ?? session
                }
                continue
            }
            guard name != nil, line.hasPrefix("\""), let equals = line.range(of: "\"=") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<equals.lowerBound])
            let value = String(line[equals.upperBound...])
            if value.hasPrefix("\"") {
                fields[key.lowercased()] = try registryString(value)
            } else if value.lowercased().hasPrefix("dword:") {
                let hex = String(value.dropFirst(6))
                guard hex.count == 8, let number = UInt32(hex, radix: 16) else { throw failure("Invalid PuTTY registry integer") }
                fields[key.lowercased()] = String(number)
            } else if ["hostname", "portnumber", "username", "protocol", "publickeyfile", "proxymethod"].contains(key.lowercased()) {
                throw failure("Unsupported or invalid PuTTY registry field \(key)")
            }
        }
        finish()
        var hosts: [Host] = [], warnings: [String] = []
        for (name, fields) in entries {
            guard let address = fields["hostname"], !address.isEmpty else { continue }
            if let proto = fields["protocol"], proto.lowercased() != "ssh" { warnings.append("Non-SSH PuTTY sessions are skipped.（已跳过非 SSH 的 PuTTY 会话。）"); continue }
            var host = Host(); host.name = name; host.address = address
            host.username = fields["username"].flatMap { $0.isEmpty ? nil : $0 } ?? "root"; host.group = "PuTTY"
            if let value = fields["portnumber"] { host.port = try port(value, context: name) }
            if let path = fields["publickeyfile"], !path.isEmpty {
                // PuTTY PPK bytes cannot be consumed by the app's OpenSSH key reader.
                // Keep the session usable with a prompt to select a converted key.
                if path.lowercased().hasSuffix(".ppk") {
                    warnings.append("PuTTY .ppk keys need conversion to OpenSSH format; select a converted key after import.（请将 .ppk 私钥转为 OpenSSH 格式，并在导入后重新选择。）")
                } else { host.keyPath = path; host.auth = "key" }
            }
            if (fields["proxymethod"] ?? "0") != "0" || !(fields["portforwardings"] ?? "").isEmpty {
                warnings.append("PuTTY proxy and forwarding settings are not imported.（不导入 PuTTY 代理和转发设置。）")
            }
            if (fields["agentfwd"] ?? "0") != "0" || (fields["tryagent"] ?? "0") != "0" {
                warnings.append("PuTTY SSH agent settings are not imported.（不导入 PuTTY SSH agent 设置。）")
            }
            hosts.append(host)
        }
        guard !entries.isEmpty else { throw failure("No PuTTY sessions in this registry export") }
        return HostImportDocument(hosts: hosts, warnings: warnings)
    }
    private static func registryString(_ raw: String) throws -> String {
        guard raw.first == "\"", raw.last == "\"", raw.count >= 2 else { throw failure("Invalid quoted registry value") }
        var value = "", escaped = false
        for char in raw.dropFirst().dropLast() {
            if escaped {
                guard char == "\\" || char == "\"" else { throw failure("Invalid registry string escape") }
                value.append(char); escaped = false
            } else if char == "\\" { escaped = true }
            else if char == "\"" { throw failure("Invalid registry string quote") }
            else { value.append(char) }
        }
        guard !escaped else { throw failure("Incomplete registry string escape") }
        return value
    }

    private static func exportTabby(_ hosts: [Host]) throws -> String {
        let profiles: [[String: Any]] = hosts.map { host in
            var options: [String: Any] = ["host": host.address, "port": host.port, "user": host.username]
            if host.auth == "key", !host.keyPath.isEmpty { options["privateKeys"] = [host.keyPath] }
            if let jump = host.jumpHostID { options["jumpHost"] = jump.uuidString }
            return ["id": host.id.uuidString, "type": "ssh", "name": host.name, "group": host.group,
                    "tags": TagTokens.parse(host.tags), "favorite": host.favorite, "options": options]
        }
        return try Yams.dump(object: ["version": 7, "profiles": profiles])
    }
    private static func csvQuoted(_ value: String) -> String {
        // Always quote text. This keeps commas and double quotes lossless.
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func exportCSV(_ hosts: [Host]) -> String {
        let columns = ["id", "label", "hostname", "port", "username", "group", "tags", "identity_file", "jump_host", "auth", "favorite"]
        let rows = hosts.map { host in
            [host.id.uuidString, host.name, host.address, String(host.port), host.username, host.group, host.tags,
             host.auth == "key" ? host.keyPath : "", host.jumpHostID?.uuidString ?? "", host.auth, String(host.favorite)].map(csvQuoted).joined(separator: ",")
        }
        return ([columns.joined(separator: ",")] + rows).joined(separator: "\r\n") + "\r\n"
    }
    private static func sshQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func exportOpenSSH(_ hosts: [Host]) -> String {
        var aliases: [UUID: String] = [:], taken = Set<String>()
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for host in hosts {
            let proposed = (host.name.isEmpty ? host.address : host.name).unicodeScalars.map { safe.contains($0) ? String($0) : "-" }.joined()
            let base = proposed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let candidate = base.isEmpty ? "host" : String(base.prefix(60))
            var alias = candidate, suffix = 2
            while !taken.insert(alias.lowercased()).inserted { alias = "\(candidate)-\(suffix)"; suffix += 1 }
            aliases[host.id] = alias
        }
        var output = "# Exported by Axon. Passwords and pasted private keys are omitted.\n# Group names, tags, and favorites are available in the YAML and CSV exports.\n\n"
        for host in hosts {
            output += "Host \(aliases[host.id]!)\n"
            output += "    HostName \(sshQuoted(host.address))\n    User \(sshQuoted(host.username))\n    Port \(host.port)\n"
            if host.auth == "key", !host.keyPath.isEmpty { output += "    IdentityFile \(sshQuoted(host.keyPath))\n" }
            if let jump = host.jumpHostID, let alias = aliases[jump] { output += "    ProxyJump \(sshQuoted(alias))\n" }
            output += "\n"
        }
        return output
    }
}
