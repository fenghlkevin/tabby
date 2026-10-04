import XCTest
import SwiftTerm
@testable import TabbyNative

final class SnippetTests: XCTestCase {
    func testLegacyWorkspaceAndPartialSnippetDecode() throws {
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data("{}".utf8))
        XCTAssertTrue(workspace.snippets.isEmpty)
        let snippet = try JSONDecoder().decode(CommandSnippet.self, from: Data("{\"name\":\"Disk usage\",\"body\":\"df -h\"}".utf8))
        XCTAssertEqual(snippet.name, "Disk usage"); XCTAssertEqual(snippet.group, ""); XCTAssertEqual(snippet.notes, "")
        XCTAssertEqual(try JSONDecoder().decode(CommandSnippet.self, from: JSONEncoder().encode(snippet)), snippet)
    }
    @MainActor func testSnippetCRUDGroupsAndDuplicatesPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let store = AppStore(fileURL: file)
        var snippet = CommandSnippet(); snippet.name = "  Check disk  "; snippet.group = " Diagnostics "; snippet.body = "df -h\r\nprintf '%s' done"; snippet.notes = "Read disk usage"
        try store.saveSnippet(snippet)
        XCTAssertEqual(store.workspace.snippets[0].name, "Check disk")
        XCTAssertEqual(store.workspace.snippets[0].body, "df -h\nprintf '%s' done")
        XCTAssertEqual(store.snippetGroups, ["Diagnostics"])
        snippet = store.workspace.snippets[0]; snippet.notes = "Updated"; try store.saveSnippet(snippet)
        XCTAssertEqual(store.workspace.snippets.count, 1)
        let duplicate = try store.duplicateSnippet(snippet)
        XCTAssertNotEqual(duplicate.id, snippet.id); XCTAssertEqual(duplicate.body, snippet.body)
        try store.renameSnippetGroup("Diagnostics", to: "Maintenance")
        XCTAssertEqual(store.snippetGroups, ["Maintenance"])
        XCTAssertTrue(store.workspace.snippets.allSatisfy { $0.group == "Maintenance" })
        let loaded = AppStore(fileURL: file)
        XCTAssertEqual(loaded.workspace.snippets, store.workspace.snippets)
        try store.ungroupSnippets("Maintenance")
        XCTAssertTrue(store.snippetGroups.isEmpty)
        try store.removeSnippet(duplicate.id)
        XCTAssertEqual(store.workspace.snippets.map(\.id), [snippet.id])
        XCTAssertEqual(AppStore(fileURL: file).workspace.snippets[0].notes, "Updated")
    }
    @MainActor func testInvalidSnippetAndGroupChangesLeaveExistingDataUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var first = CommandSnippet(); first.name = "one"; first.group = "A"; first.body = "pwd"; try store.saveSnippet(first)
        var second = CommandSnippet(); second.name = "two"; second.group = "B"; second.body = "date"; try store.saveSnippet(second)
        let before = store.workspace.snippets
        XCTAssertThrowsError(try store.renameSnippetGroup("A", to: " B "))
        XCTAssertThrowsError(try store.renameSnippetGroup("A", to: " "))
        first.name = " "; XCTAssertThrowsError(try store.saveSnippet(first))
        first.name = "one"; first.body = "\n\t "; XCTAssertThrowsError(try store.saveSnippet(first))
        first.body = "pwd\u{1b}[201~\rwhoami"; XCTAssertThrowsError(try store.saveSnippet(first))
        XCTAssertEqual(store.workspace.snippets, before)
        XCTAssertEqual(AppStore(fileURL: store.fileURL).workspace.snippets, before)
    }
    @MainActor func testSaveFailureRollsBackSnippetMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var value = CommandSnippet(); value.name = "fixture"; value.body = "pwd"
        XCTAssertThrowsError(try store.saveSnippet(value))
        XCTAssertTrue(store.workspace.snippets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root), Data("occupied".utf8))
    }
    @MainActor func testUnreadableWorkspacePreservesFileWhenSavingSnippet() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("not json".utf8); try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(fileURL: file)
        var value = CommandSnippet(); value.name = "fixture"; value.body = "pwd"
        XCTAssertThrowsError(try store.saveSnippet(value))
        XCTAssertTrue(store.workspace.snippets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testInsertNeverAddsSubmissionAndRequiresSafeMultilineMode() throws {
        let single = try SnippetInput.bytes("pwd\r\n", action: .insert, bracketedPaste: false)
        XCTAssertEqual(single, Array("pwd".utf8))
        XCTAssertThrowsError(try SnippetInput.bytes("pwd\nwhoami", action: .insert, bracketedPaste: false))
        XCTAssertThrowsError(try SnippetInput.bytes("printf\tfixture", action: .insert, bracketedPaste: false))
        let multiline = "printf '你好'\r\nprintf 'done'\r\n"
        let safe = try SnippetInput.bytes(multiline, action: .insert, bracketedPaste: true)
        XCTAssertEqual(safe, Array("\u{1b}[200~printf '你好'\nprintf 'done'\u{1b}[201~".utf8))
        XCTAssertFalse(safe.contains(13))
    }
    func testExplicitRunIncludesSingleFinalSubmissionAndRejectsControlSequences() throws {
        XCTAssertEqual(try SnippetInput.bytes("pwd\nwhoami\n\n", action: .run, bracketedPaste: false), Array("pwd\rwhoami\r".utf8))
        XCTAssertEqual(try SnippetInput.bytes("pwd\nwhoami\n", action: .run, bracketedPaste: true), Array("\u{1b}[200~pwd\nwhoami\u{1b}[201~\r".utf8))
        for text in ["echo ok\u{1b}[201~", "echo ok\0", "echo ok\u{7}", "echo ok\u{7f}", "\n ", String(repeating: "a", count: 256 * 1024 + 1)] {
            XCTAssertThrowsError(try SnippetInput.bytes(text, action: .run, bracketedPaste: true))
        }
    }
    @MainActor func testSendPreflightRejectsMissingDisconnectedAndUnsafeTargets() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var value = CommandSnippet(); value.name = "fixture"; value.body = "pwd"
        XCTAssertThrowsError(try store.sendSnippet(value, to: [], action: .insert))
        XCTAssertThrowsError(try store.sendSnippet(value, to: [UUID()], action: .run))
        let session = TerminalSession(host: nil, store: store)
        store.sessions = [session]
        XCTAssertThrowsError(try store.sendSnippet(value, to: [session.id], action: .insert))
        session.connected = true
        XCTAssertThrowsError(try store.sendSnippet(value, to: [session.id], action: .insert))
        session.terminal = TerminalView(frame: .zero)
        value.body = "pwd\nwhoami"
        XCTAssertThrowsError(try store.sendSnippet(value, to: [session.id], action: .insert))
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.section, "hosts")
    }
    @MainActor func testSelectedTerminalsReceiveSnippetAndPreflightSendsNothingOnPartialFailure() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let captures = (0..<3).map { _ in SnippetInputCapture() }
        let sessions = captures.map { capture -> TerminalSession in
            let session = TerminalSession(host: nil, store: store)
            let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
            terminal.terminalDelegate = capture; session.terminal = terminal; session.connected = true
            return session
        }
        store.sessions = sessions
        sessions[0].terminal!.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(sessions[0].terminal!.terminalStateSnapshot().bracketedPasteMode)
        var value = CommandSnippet(); value.name = "fixture"; value.body = "printf fixture"
        let targets: Set<UUID> = [sessions[0].id, sessions[1].id]
        try store.sendSnippet(value, to: targets, action: .run)
        XCTAssertEqual(captures[0].received, [Array("\u{1b}[200~printf fixture\u{1b}[201~\r".utf8)])
        XCTAssertEqual(captures[1].received, [Array("printf fixture\r".utf8)])
        XCTAssertTrue(captures[2].received.isEmpty)
        captures.forEach { $0.received = [] }
        value.body = "printf one\nprintf two"
        XCTAssertThrowsError(try store.sendSnippet(value, to: targets, action: .insert))
        XCTAssertTrue(captures.allSatisfy { $0.received.isEmpty })
        value.body = "printf fixture"
        sessions[1].connected = false
        XCTAssertThrowsError(try store.sendSnippet(value, to: targets, action: .run))
        XCTAssertTrue(captures.allSatisfy { $0.received.isEmpty })
        try store.sendSnippet(value, to: [sessions[0].id], action: .insert)
        XCTAssertEqual(captures[0].received, [Array("\u{1b}[200~printf fixture\u{1b}[201~".utf8)])
        XCTAssertTrue(captures[1].received.isEmpty); XCTAssertTrue(captures[2].received.isEmpty)
        XCTAssertEqual(store.activeSession, sessions[0].id); XCTAssertEqual(store.section, "terminal")
    }
}

@MainActor private final class SnippetInputCapture: TerminalViewDelegate {
    var received: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}
