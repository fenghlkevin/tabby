import Foundation
import Darwin

/// Pure metadata validation runs before any Keychain read, disk write, or connection.
enum ConnectionValidation {
    static func integer(_ text: String, range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, range.lowerBound >= 0 else { return nil }
        var result = 0
        for byte in text.utf8 {
            guard byte >= 48, byte <= 57 else { return nil }
            let product = result.multipliedReportingOverflow(by: 10)
            let sum = product.partialValue.addingReportingOverflow(Int(byte - 48))
            guard !product.overflow, !sum.overflow, sum.partialValue <= range.upperBound else { return nil }
            result = sum.partialValue
        }
        return range.contains(result) ? result : nil
    }
    private static func failure(_ english: String, _ chinese: String, chinese useChinese: Bool) -> AppFailure { .message(useChinese ? chinese : english) }
    private static func containsControl(_ value: String) -> Bool { value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func containsWhitespace(_ value: String) -> Bool { value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) } }
    static func username(_ raw: String, chinese: Bool = false) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsControl(raw), !containsWhitespace(value) else {
            throw failure("Username must be nonempty and contain no whitespace or control characters", "用户名不能为空，也不能包含空白或控制字符", chinese: chinese)
        }
        return value
    }
    static func address(_ raw: String, chinese: Bool = false, allowWildcard: Bool = false) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsControl(raw), !containsWhitespace(value) else {
            throw failure("Address must be nonempty and contain no whitespace or control characters", "地址不能为空，也不能包含空白或控制字符", chinese: chinese)
        }
        guard !value.contains("/"), !value.contains("@") else {
            throw failure("Enter a hostname or IP address without a URL, path, or username", "请输入主机名或 IP 地址，不要包含 URL、路径或用户名", chinese: chinese)
        }
        if allowWildcard && value == "*" { return value }
        let bracketed = value.hasPrefix("[") && value.hasSuffix("]")
        if bracketed { value = String(value.dropFirst().dropLast()) }
        if value.contains(":") {
            let components = value.split(separator: "%", omittingEmptySubsequences: false)
            let zoneAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let zoneValid = components.count == 1 || (components.count == 2 && !components[1].isEmpty && components[1].unicodeScalars.allSatisfy { zoneAllowed.contains($0) })
            var bytes = in6_addr()
            guard zoneValid, let ip = components.first, String(ip).withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 else {
                throw failure("Enter a hostname or valid IPv6 address; enter the port separately", "请输入主机名或有效 IPv6 地址；端口请单独填写", chinese: chinese)
            }
            return value
        }
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "._-"))
        let labels = (value.hasSuffix(".") ? String(value.dropLast()) : value).split(separator: ".", omittingEmptySubsequences: false)
        guard !bracketed, !labels.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63 }), value.count <= 254 else {
            throw failure("Enter a hostname or IP address without a URL, path, or port", "请输入主机名或 IP 地址，不要包含 URL、路径或端口", chinese: chinese)
        }
        if labels.count == 4, labels.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) {
            var bytes = in_addr()
            guard value.withCString({ inet_pton(AF_INET, $0, &bytes) }) == 1 else { throw failure("Enter a valid IPv4 address", "请输入有效 IPv4 地址", chinese: chinese) }
        }
        return value
    }
    static func label(_ raw: String, required: Bool = false, chinese: Bool = false) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!required || !value.isEmpty), !containsControl(raw) else { throw failure("Enter a name without control characters", "请输入不含控制字符的名称", chinese: chinese) }
        return value
    }
    static func keyPath(_ raw: String, required: Bool, chinese: Bool = false) throws -> String {
        guard !containsControl(raw), !required || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("Choose a private key file; its path cannot contain control characters", "请选择私钥文件；路径不能包含控制字符", chinese: chinese)
        }
        // Spaces can be part of a real filename. Existence/readability is checked
        // when the key file is opened, without changing the user's chosen path.
        return raw
    }
    static func credential(_ original: VaultCredential, chinese: Bool = false) throws -> VaultCredential {
        var value = original
        value.name = try label(value.name, required: true, chinese: chinese)
        value.username = try username(value.username, chinese: chinese)
        try authentication(value.auth, source: value.keySource, path: value.keyPath, chinese: chinese)
        return value
    }
    private static func authentication(_ auth: String, source: String?, path: String, chinese: Bool) throws {
        guard auth == "password" || auth == "key" else { throw failure("Select password or private-key authentication", "请选择密码或私钥认证", chinese: chinese) }
        if auth == "key" {
            guard source == nil || source == "file" || source == "text" else { throw failure("Select a private-key file or pasted text", "请选择私钥文件或粘贴文本", chinese: chinese) }
            if source != "text" { _ = try keyPath(path, required: true, chinese: chinese) }
        }
    }
    static func host(_ original: Host, workspace: Workspace, chinese: Bool = false) throws -> Host {
        if let name = original.persistentSessionName, !name.isEmpty { _ = try PersistentSession.validatedName(name) }
        if original.groupInheritance?.authentication == true,
           let base = GroupDefaults.group(named: original.group, workspace: workspace), let id = base.credentialID,
           !workspace.credentials.contains(where: { $0.id == id }) {
            throw failure("The group's shared identity no longer exists", "分组的共享凭据已不存在", chinese: chinese)
        }
        var host = GroupDefaults.resolved(original, workspace: workspace)
        host.name = try label(host.name, chinese: chinese)
        host.group = try label(host.group, chinese: chinese)
        host.tags = try label(host.tags, chinese: chinese)
        host.address = try address(host.address, chinese: chinese)
        guard (1...65535).contains(host.port) else { throw failure("Port must be an integer from 1 to 65535", "端口必须是 1–65535 的整数", chinese: chinese) }
        if let id = host.credentialID {
            guard let shared = workspace.credentials.first(where: { $0.id == id }) else { throw failure("Shared identity no longer exists", "共享凭据已不存在", chinese: chinese) }
            // Display labels are not authentication inputs. Existing identities
            // may have an empty legacy label, while new identity saves require one.
            host.username = try username(shared.username, chinese: chinese)
            try authentication(shared.auth, source: shared.keySource, path: shared.keyPath, chinese: chinese)
            host.auth = shared.auth; host.keyPath = shared.keyPath; host.keySource = shared.keySource
        } else {
            host.username = try username(host.username, chinese: chinese)
            try authentication(host.auth, source: host.keySource, path: host.keyPath, chinese: chinese)
        }
        var seen: Set<UUID> = [host.id]
        var next = host.jumpHostID
        while let id = next {
            guard seen.insert(id).inserted else { throw failure("Jump hosts cannot contain a cycle", "跳板主机不能形成循环", chinese: chinese) }
            guard let jump = workspace.hosts.first(where: { $0.id == id }) else { throw failure("Jump host no longer exists", "跳板主机已不存在", chinese: chinese) }
            next = GroupDefaults.resolved(jump, workspace: workspace).jumpHostID
        }
        return host
    }
    static func forward(_ original: PortForwardRule, workspace: Workspace? = nil, chinese: Bool = false) throws -> PortForwardRule {
        var rule = original
        rule.name = try label(rule.name, required: true, chinese: chinese)
        guard let id = rule.hostID, ["local", "remote", "dynamic"].contains(rule.kind) else { throw failure("Select an SSH host and forwarding type", "请选择 SSH 主机和转发类型", chinese: chinese) }
        if let workspace, !workspace.hosts.contains(where: { $0.id == id }) { throw failure("SSH host no longer exists", "SSH 主机已不存在", chinese: chinese) }
        rule.bindHost = try address(rule.bindHost, chinese: chinese, allowWildcard: rule.kind == "remote")
        guard (1...65535).contains(rule.bindPort) else { throw failure("Ports must be integers from 1 to 65535", "端口必须是 1–65535 的整数", chinese: chinese) }
        if rule.isDynamic {
            guard rule.bindHost == "127.0.0.1" || rule.bindHost == "::1" else {
                throw failure("SOCKS5 must listen on 127.0.0.1 or ::1", "SOCKS5 仅支持监听 127.0.0.1 或 ::1", chinese: chinese)
            }
        } else {
            rule.targetHost = try address(rule.targetHost, chinese: chinese)
            guard (1...65535).contains(rule.targetPort) else { throw failure("Ports must be integers from 1 to 65535", "端口必须是 1–65535 的整数", chinese: chinese) }
        }
        return rule
    }
}
