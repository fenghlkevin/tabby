import Foundation
import SwiftTerm

struct TerminalFileRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let host: Host?
    let path: String
    let isSelection: Bool
    let generation: Int
}

enum TerminalDirectoryBridge {
    static func normalizedPath(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), raw.utf8.count <= 32 * 1024,
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppFailure.message("Use an absolute path without terminal control characters. / 请使用不含终端控制字符的绝对路径。")
        }
        return (raw as NSString).standardizingPath
    }

    /// OSC 7 names its host explicitly. A nested SSH session's report must never
    /// navigate a file pane connected to the outer host.
    static func currentDirectory(_ report: String?, trustedHosts: Set<String>) -> String? {
        guard let report, report.utf8.count <= 64 * 1024,
              let url = URLComponents(string: report), url.scheme?.lowercased() == "file",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty,
              trustedHosts.map(normalizedHost).contains(normalizedHost(host)) else { return nil }
        return try? normalizedPath(url.path)
    }

    static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }

    static func selectedPath(_ selection: String?, directory: String?, trustedHosts: Set<String>) throws -> String {
        guard let selection else { throw AppFailure.message("Select a file path first. / 请先选择文件路径。") }
        let raw = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file:") {
            guard let path = currentDirectory(raw, trustedHosts: trustedHosts) else {
                throw AppFailure.message("The selected file URL belongs to another host or is invalid. / 所选文件地址无效或属于其他主机。")
            }
            return path
        }
        if raw.hasPrefix("/") { return try normalizedPath(raw) }
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let directory else {
            throw AppFailure.message("Select an absolute path, or report the shell's current directory first. / 请选择绝对路径，或先让 Shell 上报当前目录。")
        }
        return try normalizedPath((directory as NSString).appendingPathComponent(raw))
    }

    static func safeChangeDirectoryCommand(path: String) throws -> String {
        "cd -- " + SnippetParameters.shellArgument(try normalizedPath(path))
    }
}

@MainActor extension TerminalSession {
    var directoryTrustedHosts: Set<String> {
        if host != nil { return Set([authenticatedAddress].compactMap { $0 }) }
        var values: Set<String> = ["localhost", "127.0.0.1", "::1", ProcessInfo.processInfo.hostName]
        if let name = Foundation.Host.current().name { values.insert(name) }
        if let name = Foundation.Host.current().localizedName { values.insert(name); values.insert(name + ".local") }
        return values
    }

    func queueDirectoryInsertion(path: String, targetHost: Host?) throws {
        let command = try TerminalDirectoryBridge.safeChangeDirectoryCommand(path: path)
        pendingDirectoryInsertion = (command, targetHost)
        if connected { deliverPendingDirectoryInsertion() }
    }

    func deliverPendingDirectoryInsertion() {
        guard connected, let terminal, let pending = pendingDirectoryInsertion else { return }
        pendingDirectoryInsertion = nil
        guard (pending.host == nil && host == nil) || pending.host.map(matchesEndpoint) == true else {
            store.error = store.text("The connected identity or jump route changed. Choose the matching terminal again.", "连接身份或跳板路由已变化，请重新选择对应终端。")
            return
        }
        do {
            let bytes = try SnippetInput.bytes(pending.command, action: .insert, bracketedPaste: terminal.terminalStateSnapshot().bracketedPasteMode, chinese: store.chinese)
            terminal.send(data: bytes[...])
            terminal.window?.makeFirstResponder(terminal)
        } catch { store.error = error.localizedDescription }
    }
}

@MainActor extension AppStore {
    func openTerminalDirectoryInFiles(sessionID: UUID, path: String? = nil, isSelection: Bool = false, activate: Bool = true) throws {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.connected,
              session.host.map(session.matchesEndpoint) ?? true else {
            throw AppFailure.message(text("The terminal connection or identity has changed. Reconnect first.", "终端连接或身份已变化，请先重新连接。"))
        }
        let destination: String
        if isSelection {
            destination = try TerminalDirectoryBridge.selectedPath(path ?? session.terminal?.getSelection(), directory: session.currentDirectory, trustedHosts: session.directoryTrustedHosts)
        } else {
            guard let raw = path ?? session.currentDirectory else {
                throw AppFailure.message(text("The shell has not reported a current directory yet. Use Report current directory, or select an absolute path.", "Shell 尚未上报当前目录。请使用「上报当前目录」，或选择绝对路径。"))
            }
            destination = try TerminalDirectoryBridge.normalizedPath(raw)
        }
        terminalFileRequest = TerminalFileRequest(sessionID: session.id, host: session.host, path: destination, isSelection: isSelection, generation: session.generation)
        if activate { activeSession = session.id; showFileSection() }
    }

    /// The command is inserted without Return so users can inspect it in the
    /// terminal, including when opening a new connection is necessary.
    func insertChangeDirectory(path: String, host: Host?) throws {
        let normalized = try TerminalDirectoryBridge.normalizedPath(path)
        let existing = sessions.first { session in
            session.connected && session.terminal != nil && (host.map(session.matchesEndpoint) ?? (session.host == nil))
        }
        let session: TerminalSession
        if let existing { session = existing }
        else {
            if let host { _ = try ConnectionValidation.host(host, workspace: workspace, chinese: chinese) }
            connect(host)
            guard let opened = sessions.last else { return }
            session = opened
        }
        try session.queueDirectoryInsertion(path: normalized, targetHost: host)
        activeSession = session.id; showTerminalSection()
    }

    func insertDirectoryReport(sessionID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.connected, let terminal = session.terminal,
              let host = session.host == nil ? "localhost" : session.authenticatedAddress else {
            throw AppFailure.message(text("Choose a connected terminal first.", "请先选择已连接终端。"))
        }
        // $PWD is encoded by the shell helper, so spaces, Unicode, #, and ? are
        // legitimate path characters rather than URI delimiters. No output is
        // interpreted as a command, and this is inserted for review.
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let prefix = "file://" + authority
        let command = "printf '\\033]7;%s%s\\007' " + SnippetParameters.shellArgument(prefix) + " \"$(printf '%s' \"$PWD\" | LC_ALL=C od -An -v -tx1 | tr -d ' \\n' | sed 's/../%&/g')\""
        let bytes = try SnippetInput.bytes(command, action: .insert, bracketedPaste: terminal.terminalStateSnapshot().bracketedPasteMode, chinese: chinese)
        terminal.send(data: bytes[...])
        terminal.window?.makeFirstResponder(terminal)
    }
}
