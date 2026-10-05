import Foundation
import SwiftUI
import Citadel

/// A literal tmux name, never a shell fragment or tmux target expression.
enum PersistentSession {
    static func validatedName(_ name: String) throws -> String {
        guard name.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw AppFailure.message("tmux name: 1–80 letters, digits, _ or - / tmux 名称须为 1–80 个字母、数字、下划线或连字符") }
        return name
    }
    static func defaultName(_ id: UUID) -> String { "axon-" + id.uuidString.lowercased() }
    static func token(_ name: String) -> String { "tmux_" + name }
    static func preparation(name: String) throws -> String {
        let name = try validatedName(name)
        var hooks = ShellCommandIntegration.script(token: token(name))
        // tmux passthrough escapes the inner ESC. The option is set only on
        // this Axon window; global server options and dotfiles stay untouched.
        hooks = hooks.replacingOccurrences(of: #"printf '\033]7;axon-command;"#, with: #"printf '\033Ptmux;\033\033]7;axon-command;"#)
            .replacingOccurrences(of: #";%s\007' "$1""#, with: #";%s\007\033\\' "$1""#)
        let rc = #"rm -f -- "${BASH_SOURCE[0]}"; if [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi"# + "\n" + hooks
        return "command -v tmux >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || { printf '%s' 'missing-tmux-or-bash'; exit 0; }; if tmux has-session -t =\(name) 2>/dev/null; then [ \"$(tmux show-option -v -t =\(name): @axon-managed 2>/dev/null)\" = 1 ] || { printf '%s' 'unmanaged-session-use-another-name'; exit 0; }; _axon_created=existing; else _axon_rc=$(mktemp /tmp/axon-shell.XXXXXX) || exit 1; chmod 600 \"$_axon_rc\"; printf '%s' \(SnippetParameters.shellArgument(rc)) >\"$_axon_rc\"; tmux new-session -d -s \(name) \"exec bash --rcfile $_axon_rc -i\" || { rm -f -- \"$_axon_rc\"; exit 1; }; tmux set-option -t =\(name): @axon-managed 1; _axon_created=created; fi; tmux set-option -w -t =\(name): allow-passthrough on >/dev/null 2>&1 || { printf '%s' 'tmux-3.3-required'; exit 0; }; printf '%s' \"$_axon_created\""
    }
    static func attach(name: String) throws -> String { "tmux attach-session -t =" + (try validatedName(name)) + "; exit\r" }
    static func end(name: String) throws -> String { "tmux kill-session -t =" + (try validatedName(name)) }
}

@MainActor extension TerminalSession {
    var usesPersistentSession: Bool { host != nil && (persistentOverride ?? host?.persistentSession ?? false) }
    var persistentName: String {
        if let persistentNameOverride, !persistentNameOverride.isEmpty { return persistentNameOverride }
        if let name = host?.persistentSessionName, !name.isEmpty { return name }
        return host.map { PersistentSession.defaultName($0.id) } ?? ""
    }
    func preparePersistentSession(_ client: SSHClient) async throws {
        let command = try PersistentSession.preparation(name: persistentName)
        let result = try await MonitoringSSHExecutor.execute(client: client, command: command, maximumBytes: 4096)
        guard result == "created" || result == "existing" else { throw AppFailure.message(store.text("Persistent sessions require tmux 3.3+ and Bash. Server response: ", "持久会话需要 tmux 3.3+ 与 Bash，服务器响应：") + result) }
        persistentSessionWasCreated = result == "created"
        commandHistoryToken = PersistentSession.token(persistentName); commandHistoryReady = true
    }
    func endPersistentSession() async throws {
        guard usesPersistentSession, let client, connected else { throw AppFailure.message("Connect before ending this session / 请先连接后结束持久会话") }
        _ = try await MonitoringSSHExecutor.execute(client: client, command: PersistentSession.end(name: persistentName), maximumBytes: 4096)
        disconnect()
    }
}

struct PersistentSessionControls: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: TerminalSession
    @State private var confirming = false
    @State private var error = ""
    var body: some View {
        if session.usesPersistentSession {
            VStack(alignment: .leading, spacing: 8) {
                Text("tmux · " + session.persistentName).font(.caption).textSelection(.enabled)
                Text(store.text("Closing this tab detaches. Remote tasks continue until the session is ended.", "关闭标签只断开连接，远端任务继续运行；结束会话才会关闭远端程序。" )).font(.caption).foregroundStyle(TerminalChrome.muted)
                Button(store.text("End remote session", "结束远端会话"), role: .destructive) { confirming = true }.disabled(!session.connected)
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            }.appAlert(store.text("End the tmux session?", "结束 tmux 会话？"), isPresented: $confirming) {
                Button(store.text("End session", "结束会话"), role: .destructive) { Task { do { try await session.endPersistentSession() } catch { self.error = error.localizedDescription } } }
                Button(store.text("Cancel", "取消"), role: .cancel) {}
            } message: { Text(store.text("All programs in this remote tmux session will be terminated.", "此远端 tmux 会话中的全部程序都会被终止。")) }
        }
    }
}
