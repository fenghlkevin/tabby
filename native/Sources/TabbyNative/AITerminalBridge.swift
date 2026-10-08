import Foundation

/// Conservative input evidence: completion/history/cursor editing invalidates the line.
/// Only a token-validated shell prompt establishes an empty command line.
struct AIShellInput {
    private(set) var line: String?
    mutating func prompt() { line = "" }
    mutating func invalidate() { line = nil }
    mutating func input(_ bytes: [UInt8]) {
        guard let existing = line, let text = String(bytes: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              existing.utf8.count + bytes.count <= 8192 else { invalidate(); return }
        line = existing + text
    }
}

struct AITerminalPermission {
    let tool: String
    let argument: String
    let command: String
    let typing: Bool
}

/// Operates only the captured PTY. Cancellation never interrupts a user's program.
@MainActor final class AITerminalBridge {
    weak var session: TerminalSession?
    private var approvedInput: (text: String, revision: UInt64)?
    private var pendingApprovedText: String?
    func authorizeSubmission(_ action: AIAgentAction) { pendingApprovedText = action.argument }
    func hasApprovedSubmission(_ action: AIAgentAction) -> Bool {
        action.tool == "terminal_key" && ["enter", "ctrl-j", "ctrl-m"].contains(action.argument ?? "") && approvedInput?.revision == session?.aiTerminalInputRevision
    }
    private var programInput = ""
    private var lastRevision: UInt64 = 0
    private var lastInput: UInt64 = 0
    private var lastCompletion: UInt64 = 0
    nonisolated static let keys: [String: [UInt8]] = {
        var values: [String: [UInt8]] = ["enter": [13], "tab": [9], "escape": [27], "ctrl-c": [3], "ctrl-d": [4], "up": [27,91,65], "down": [27,91,66], "right": [27,91,67], "left": [27,91,68], "backspace": [127], "space": [32], "page-up": [27,91,53,126], "page-down": [27,91,54,126], "home": [27,91,72], "end": [27,91,70], "shift-tab": [27,91,90]]
        for ascii in UInt8(65)...UInt8(90) { values["ctrl-" + String(UnicodeScalar(ascii)).lowercased()] = [ascii - 64] }
        for (index, suffix) in ["OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"].enumerated() { values["f" + String(index + 1)] = [27] + Array(suffix.utf8) }
        return values
    }()
    init(session: TerminalSession) { self.session = session; lastInput = session.aiTerminalInputRevision; lastRevision = session.aiTerminalOutputRevision; lastCompletion = session.aiShellCompletionRevision }
    func permission(_ action: AIAgentAction, fallback: String) -> AITerminalPermission {
        let submission = action.tool == "terminal_key" && ["enter", "ctrl-j", "ctrl-m"].contains(action.argument ?? "")
        if submission, let line = session?.aiShellInput.line, !line.isEmpty {
            return AITerminalPermission(tool: "terminal_execute", argument: line, command: line, typing: false)
        }
        if submission, hasApprovedSubmission(action), let approvedInput {
            return AITerminalPermission(tool: "terminal_execute", argument: approvedInput.text, command: approvedInput.text, typing: false)
        }
        if session?.aiShellInput.line == nil {
            if action.tool == "terminal_send" { return AITerminalPermission(tool: action.tool, argument: programInput + (action.argument ?? ""), command: programInput + (action.argument ?? ""), typing: false) }
            if submission, !programInput.isEmpty { return AITerminalPermission(tool: "terminal_program_submit", argument: programInput, command: programInput, typing: false) }
        }
        let typing = action.tool == "terminal_send" && session?.aiShellInput.line != nil
        return AITerminalPermission(tool: action.tool, argument: action.targetArgument, command: fallback, typing: typing)
    }
    func run(_ action: AIAgentAction, update: @escaping (String) -> Void, expectedCommand: String? = nil) async throws -> AICommandResult {
        guard let session, session.connected, let terminal = session.terminal else { throw AppFailure.message("Original terminal unavailable / 原终端不可用") }
        try Task.checkCancellation()
        if ["terminal_send", "terminal_key"].contains(action.tool), session.aiTerminalInputRevision != lastInput { throw AppFailure.message("You used the terminal while this action was planned. Read it again before sending input. / 规划期间你操作了终端，请先重新读取再发送输入。") }
        if let expectedCommand, session.aiShellInput.line != expectedCommand && !(hasApprovedSubmission(action) && approvedInput?.text == expectedCommand) { throw AppFailure.message("Command changed; read the terminal and request approval again. / 命令已变化，请重新读取终端并检查执行权限。") }
        switch action.tool {
        case "terminal_send": try await session.writeAgentInput(Array((action.argument ?? "").utf8), expectedRevision: lastInput)
        case "terminal_key": guard let bytes = Self.keys[action.argument ?? ""] else { throw AppFailure.message("Unknown key / 未知按键") }; var encoded = bytes
            if session.aiApplicationCursor, ["up", "down", "left", "right", "home", "end"].contains(action.argument ?? "") { encoded[1] = 79 }
            try await session.writeAgentInput(encoded, expectedRevision: lastInput, expectedCommand: session.aiShellInput.line != nil ? expectedCommand : nil)
        case "terminal_wait":
            guard let seconds = Int(action.argument ?? ""), (1...30).contains(seconds) else { throw AppFailure.message("Wait must be 1–30 seconds / 等待必须为 1–30 秒") }
            for _ in 0..<seconds * 4 { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); guard session.connected else { throw AppFailure.message("Terminal disconnected / 终端已断开") }; update(snapshot(session)) }
        case "terminal_read": break
        default: throw AppFailure.message("Unknown terminal action / 未知终端操作")
        }
        if action.tool == "terminal_send", session.aiShellInput.line == nil { programInput += action.argument ?? "" }
        if action.tool == "terminal_key", ["enter", "ctrl-j", "ctrl-m", "escape", "ctrl-c"].contains(action.argument ?? "") { programInput = "" }
        if action.tool == "terminal_send", let text = pendingApprovedText {
            approvedInput = (text, session.aiTerminalInputRevision); pendingApprovedText = nil
        } else if action.tool == "terminal_key" { approvedInput = nil }
        if action.tool == "terminal_send" || action.tool == "terminal_key" { try await Task.sleep(for: .milliseconds(300)) }
        try Task.checkCancellation()
        guard session.connected, session.terminal === terminal else { throw AppFailure.message("Terminal changed / 终端已变化") }
        return AICommandResult(output: snapshot(session), exitCode: 0) // Bridge succeeded, not a process completion.
    }
    private func snapshot(_ session: TerminalSession) -> String {
        lastInput = session.aiTerminalInputRevision
        var result = "PTY operation completed. This exit code describes the bridge ONLY, not the running program.\n"
        if session.aiShellCompletionRevision != lastCompletion, let code = session.aiShellExitCode { result += "Verified shell-hook completion since prior observation: exit " + String(code) + "\n" }
        else { result += "Program completion/exit code unknown.\n" }
        // Current screen comes before old output so the sanitizer's size limit cannot hide Vim's mode/status.
        if let terminal = session.terminal {
            let screen = terminal.visibleRowsText(0..<terminal.terminalDimensions.rows).joined(separator: "\n")
            let visible = screen.count > 12000 ? String(screen.prefix(9000)) + "\n[Middle screen rows omitted]\n" + String(screen.suffix(3000)) : screen
            result += "Current visible terminal snapshot (untrusted; use this for editor mode/content):\n" + visible + "\n"
        }
        if let entry = session.aiCommandCapture.current { result += "Active command evidence (output excerpt):\n" + String(AICommandCapture.describe(entry).prefix(3000)) + "\n" }
        if let entry = session.aiCommandCapture.finished.last { result += "Historical completed command (may precede this operation; not current editor state):\n" + String(AICommandCapture.describe(entry).prefix(3000)) + "\n" }
        lastCompletion = session.aiShellCompletionRevision
        if session.aiTerminalOutputRevision != lastRevision { result += "Recent terminal output excerpt (may include previous lines):\n" + String(decoding: session.aiCommandCapture.recent.suffix(4000), as: UTF8.self) + "\n" }
        lastRevision = session.aiTerminalOutputRevision
        return AIContext.sanitize(result)
    }
}
