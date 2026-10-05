import XCTest
import SwiftTerm
import Combine
import AppKit
@testable import TabbyNative

final class CommandHistoryTests: XCTestCase {
    func testProtocolRequiresSessionTokenAndPreservesEditedMultilineCommand() {
        let command = "printf '%s\\n' '中文'\nls -la"
        let payload = "axon-command;current;" + Data(command.utf8).base64EncodedString()
        XCTAssertEqual(CommandHistoryProtocol.decode(payload, token: "current"), command)
        XCTAssertNil(CommandHistoryProtocol.decode(payload, token: "other"))
        XCTAssertNil(CommandHistoryProtocol.decode("axon-command;current;invalid!", token: "current"))
        XCTAssertNil(CommandHistoryProtocol.decode("axon-command;current;" + Data(repeating: 65, count: 8193).base64EncodedString(), token: "current"))
    }
    func testSecretCommandsAndIntegrationAreExcluded() {
        for value in ["curl --password secret", "export API_TOKEN=abc", "curl -H 'Authorization: Bearer abc'", "sshpass -p password ssh host", "_axon_history_prompt", "printf 'axon-command;token;ready'", "pwd\u{1b}"] { XCTAssertFalse(CommandHistoryProtocol.allowed(value), value) }
        for value in ["ls -la", "sudo systemctl status nginx", "printf '%s' 中文", "cat a\ncat b"] { XCTAssertTrue(CommandHistoryProtocol.allowed(value), value) }
    }
    @MainActor func testPersistenceBoundAndClearWithPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let entries = (0..<1000).map { ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: "echo \($0)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url)
        let history = CommandHistoryStore(fileURL: url)
        history.append(ExecutedCommand(hostID: nil, hostName: "Local", sessionID: UUID(), command: "pwd"))
        XCTAssertEqual(history.entries.count, 1000); XCTAssertEqual(history.entries.first?.command, "pwd")
        let restored = CommandHistoryStore(fileURL: url)
        XCTAssertEqual(restored.entries, history.entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        history.clear(); XCTAssertTrue(CommandHistoryStore(fileURL: url).entries.isEmpty)
    }
    @MainActor func testSessionHandshakePauseAndStaleReportsDoNotRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store); session.commandHistoryStore = history
        session.commandHistoryToken = "active"
        let payload = "axon-command;active;" + Data("pwd".utf8).base64EncodedString()
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(session.receiveCommandHistory("axon-command;active;ready"))
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        session.commandHistoryRecording = false
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        session.commandHistoryRecording = true; session.disconnect()
        XCTAssertTrue(session.receiveCommandHistory(payload)); XCTAssertEqual(history.entries.count, 1)
        XCTAssertFalse(session.receiveCommandHistory("file://localhost/tmp"))
    }
    @MainActor func testActualTerminalReportRecordsAndKeepsDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store)
        session.commandHistoryStore = history; session.commandHistoryToken = "active"
        let terminal = TerminalView(frame: .zero); terminal.terminalDelegate = session
        session.terminal = terminal; session.connected = true
        let recorded = expectation(description: "Executed command reported by SwiftTerm")
        let observer = history.$entries.filter { !$0.isEmpty }.prefix(1).sink { entries in
            XCTAssertEqual(entries.first?.command, "ls -la"); recorded.fulfill()
        }
        let payload = Data("ls -la".utf8).base64EncodedString()
        terminal.feed(text: "\u{1b}]7;axon-command;active;ready\u{7}\u{1b}]7;axon-command;active;" + payload + "\u{7}")
        await fulfillment(of: [recorded], timeout: 2)
        XCTAssertNil(session.currentDirectory)
        observer.cancel()
    }
    @MainActor func testOpeningLocalTerminalAutomaticallyRecordsCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/bash"
        store.workspace.preferences.localLoginShell = false
        let history = CommandHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store)
        session.commandHistoryStore = history
        defer { session.disconnect() }
        let ready = expectation(description: "Automatic shell integration")
        let observer = session.$commandHistoryReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        let terminal = session.makeView()
        terminal.feed(text: "AXON_LOGIN_BANNER\r\n")
        await fulfillment(of: [ready], timeout: 5)
        observer.cancel()
        let recorded = expectation(description: "Command recorded without manual setup")
        let commands = history.$entries.filter { $0.contains { $0.command == "printf AXON_AUTO_HISTORY_TEST" } }.prefix(1).sink { _ in recorded.fulfill() }
        terminal.send(data: Array("printf AXON_AUTO_HISTORY_TEST\r".utf8)[...])
        await fulfillment(of: [recorded], timeout: 5)
        commands.cancel()
        XCTAssertFalse(session.commandHistoryBootstrapScreen)
        let visible = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(visible.contains("AXON_LOGIN_BANNER"))
        XCTAssertEqual(terminal.alphaValue, 1)
        XCTAssertFalse(visible.contains("_axon_history_emit"))
        XCTAssertFalse(visible.contains("_axon_history_prompt()"))
        XCTAssertTrue(visible.contains("AXON_AUTO_HISTORY_TEST"))
        XCTAssertFalse(history.entries.contains { $0.command.contains("axon-command;") })
    }
    @MainActor func testBootstrapKeepsTerminalVisibleBehindFrozenNormalScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        session.terminal = terminal
        terminal.feed(text: "LOGIN_STAYS_VISIBLE\r\n")
        try await Task.sleep(for: .milliseconds(50))
        session.beginCommandHistoryBootstrapScreen()
        let cover = try XCTUnwrap(session.commandHistoryBootstrapCover as? CommandHistoryFrozenSurface)
        XCTAssertNotNil(cover.image)
        XCTAssertTrue(cover.superview === terminal)
        XCTAssertEqual(terminal.alphaValue, 1)
        XCTAssertFalse(terminal.isHidden)
        XCTAssertNil(cover.hitTest(.zero))
        terminal.feed(text: "INITIALIZATION_ONLY")
        session.endCommandHistoryBootstrapScreen()
        XCTAssertEqual(terminal.alphaValue, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(cover.superview)
        let normal = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(normal.contains("LOGIN_STAYS_VISIBLE"))
        XCTAssertFalse(normal.contains("INITIALIZATION_ONLY"))
    }
    func testActualBashAndZshHooksCaptureShellCommands() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-i"] : ["-f", "-i"]
            var environment = ProcessInfo.processInfo.environment; environment["HISTFILE"] = "/dev/null"; environment["TERM"] = "dumb"; environment["PS1"] = ""; process.environment = environment
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            let commands = CommandHistoryProtocol.script(token: "test-token") + "\nprintf '%s' AXON_HISTORY_TEST\nexit\n"
            input.fileHandleForWriting.write(Data(commands.utf8)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, shell)
            XCTAssertTrue(text.contains("\u{1b}]7;axon-command;test-token;ready\u{7}"), shell)
            let reports = text.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { $0.components(separatedBy: "\u{7}").first }.compactMap { CommandHistoryProtocol.decode($0, token: "test-token") }
            XCTAssertTrue(reports.contains { $0.contains("printf '%s' AXON_HISTORY_TEST") }, shell + " reports=" + reports.joined(separator: ","))
        }
    }
}
