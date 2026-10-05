import XCTest
import Foundation
import AppKit
import SwiftUI
import SwiftTerm
import Citadel
import NIOSSH
@testable import TabbyNative

final class OperationsFeatureTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axon-operations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testOldPreferencesAndProfilesDecodeWithoutEnablingNewFeatures() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(preferences.keywordRules.isEmpty); XCTAssertFalse(preferences.commandCompletionNotifications)
        let host = TabbyNative.Host()
        let encoded = try JSONEncoder().encode(host)
        let restored = try JSONDecoder().decode(TabbyNative.Host.self, from: encoded)
        XCTAssertNil(restored.persistentSession)
        let scene = try JSONDecoder().decode(WorkSceneTerminal.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"directory\":\"\"}".utf8))
        XCTAssertNil(scene.persistentSession)
    }
    func testKeywordScopePrecedenceRegexValidationAndUnicodeRanges() throws {
        var host = TabbyNative.Host(); host.group = "Production"
        var global = KeywordRule(); global.pattern = "ERROR"; global.foreground = "#FF0000"
        var group = global; group.id = UUID(); group.scope = "group"; group.group = "Production"; group.foreground = "#FFFF00"
        var individual = global; individual.id = UUID(); individual.scope = "host"; individual.hostID = host.id; individual.foreground = "#00FF00"
        let text = "中文 ERROR warning"
        let rules = KeywordMatching.effective([global, group, individual], host: host)
        let matches = KeywordMatching.matches(text, rules: rules)
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches[0].range, (text as NSString).range(of: "ERROR")); XCTAssertEqual(matches[0].rule.id, individual.id)
        individual.enabled = false
        XCTAssertEqual(KeywordMatching.matches(text, rules: KeywordMatching.effective([global, group, individual], host: host)).first?.rule.id, group.id)
        var bad = global; bad.regex = true; bad.pattern = "["; XCTAssertThrowsError(try bad.expression())
        bad.regex = false; XCTAssertNoThrow(try bad.expression())
        bad.foreground = "red"; XCTAssertThrowsError(try bad.expression())
        XCTAssertEqual(KeywordMatching.matches("error", rules: [global]).count, 1)
        global.caseSensitive = true; XCTAssertTrue(KeywordMatching.matches("error", rules: [global]).isEmpty)
    }
    func testKeywordZeroWidthAndPathologicalPatternsAreBounded() {
        var rule = KeywordRule(); rule.regex = true; rule.pattern = "^"
        XCTAssertTrue(KeywordMatching.matches("text", rules: [rule]).isEmpty)
        rule.pattern = "(a+)+$"
        let start = Date()
        _ = KeywordMatching.matches(String(repeating: "a", count: 2000) + "!", rules: [rule])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testTmuxNamesRejectShellAndTargetInjectionAndPreparationParses() throws {
        for value in ["name; rm -rf /", "a.b", "a:0", "$(id)", "", "a\n", String(repeating: "a", count: 81)] { XCTAssertThrowsError(try PersistentSession.validatedName(value)) }
        let command = try PersistentSession.preparation(name: "axon-test_01")
        XCTAssertTrue(command.contains("allow-passthrough")); XCTAssertTrue(command.contains("unmanaged-session")); XCTAssertTrue(command.contains("@axon-managed"))
        XCTAssertTrue(command.contains("\\033Ptmux;"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-n", "-c", command]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try PersistentSession.attach(name: "name"), "tmux attach-session -t =name; exit\r")
    }
    func testBatchCommandStatusFramingAndPrerequisiteFailureDoNotExecutePayload() throws {
        let command = try BatchCommand.wrapped("printf AXON_PAYLOAD_EXECUTED; exit 9", timeout: 1, marker: "AXON_RESULT_TEST")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        let result = try XCTUnwrap(BatchCommand.result(text, marker: "AXON_RESULT_TEST"))
        XCTAssertEqual(result.1, 125); XCTAssertFalse(result.0.contains("AXON_PAYLOAD_EXECUTED"))
        XCTAssertNil(BatchCommand.result("AXON_RESULT_TEST:0", marker: "AXON_RESULT_TEST"))
        XCTAssertThrowsError(try BatchCommand.wrapped("ls", timeout: 0, marker: "marker"))
        XCTAssertThrowsError(try BatchCommand.wrapped("ls", timeout: 1, marker: "$(id)"))
    }
    @MainActor func testExternalEditRoundTripKeepsBackupAndPermissionsAndDetectsConflict() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.ini")
        try Data("unchanged\nold=value\nfooter\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let backend = LocalFiles(), entry = try await backend.stat(url.path)
        let edit = try await ExternalEdit.prepare(entry: entry, backend: backend, directory: root.appendingPathComponent("work"))
        try Data("unchanged\nnew=value\nfooter\n".utf8).write(to: edit.localURL, options: .atomic)
        edit.checkChanges(); XCTAssertTrue(edit.changed); XCTAssertTrue(edit.preview.contains("− old=value")); XCTAssertFalse(edit.preview.contains("− unchanged"))
        try await edit.upload()
        XCTAssertFalse(edit.changed); XCTAssertEqual(try Data(contentsOf: url), Data("unchanged\nnew=value\nfooter\n".utf8))
        let saved = try await backend.stat(url.path); XCTAssertEqual(saved.permissions & 0o777, 0o640)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("config.ini.backup-") })
        // Same length and mtime intentionally defeat metadata-only conflict checks.
        let current = try await backend.stat(url.path)
        try Data("unchanged\nxxx=value\nfooter\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: current.modified], ofItemAtPath: url.path)
        try Data("unchanged\nmyy=value\nfooter\n".utf8).write(to: edit.localURL)
        do { try await edit.upload(); XCTFail("Must reject concurrent remote modification") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("unchanged\nxxx=value\nfooter\n".utf8)); XCTAssertTrue(edit.changed)
    }
    @MainActor func testExternalEditRejectsSymlinkAndOversize() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = LocalFiles()
        var entry = FileEntry(name: "link", path: "/link", directory: false, symlink: true)
        do { _ = try await ExternalEdit.prepare(entry: entry, backend: backend, directory: root); XCTFail() } catch {}
        entry.symlink = false; entry.size = UInt64(ExternalEdit.maximumBytes + 1)
        do { _ = try await ExternalEdit.prepare(entry: entry, backend: backend, directory: root); XCTFail() } catch {}
    }
    @MainActor func testInterruptedTransferResumesVerifiedPrefixAndCommitsExactBytes() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.dat"), output = root.appendingPathComponent("output.dat")
        let bytes = Data((0..<700000).map { UInt8($0 % 251) }); try bytes.write(to: input)
        let source = LocalFiles(), target = FailingWriteEndpoint()
        let queue = TransferQueue()
        try queue.enqueue(try await source.stat(input.path), destination: output.path, source: source, target: target, direction: "copy")
        let job = try XCTUnwrap(queue.jobs.first)
        try await wait(job, states: ["failed"])
        let partial = try XCTUnwrap(job.partials[output.path]); let partialEntry = try await target.stat(partial.path); XCTAssertEqual(partialEntry.size, 256 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        queue.retry(job); try await wait(job, states: ["completed", "failed"])
        XCTAssertEqual(job.state, "completed", job.error); XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(job.partials.isEmpty); XCTAssertEqual(job.completed, UInt64(bytes.count))
    }
    @MainActor func testTamperedPartialCannotResume() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let source = LocalFiles(), target = LocalFiles()
        let input = root.appendingPathComponent("in"), partial = root.appendingPathComponent("out.tabby-" + UUID().uuidString)
        try Data("original".utf8).write(to: input); try Data("bad".utf8).write(to: partial)
        do { _ = try await TransferResume.validatedOffset(entry: source.stat(input.path), partial: target.stat(partial.path), source: source, target: target); XCTFail("Must reject damaged prefix") } catch {}
    }
    @MainActor func testHistoryMetadataExitDurationAndExclusionArePersisted() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")), history = CommandHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let session = TerminalSession(host: nil, store: store); session.commandHistoryStore = history; session.commandHistoryToken = "token"
        _ = session.receiveCommandHistory("axon-command;token;ready")
        _ = session.receiveCommandHistory("axon-command;token;" + Data("false".utf8).base64EncodedString())
        _ = session.receiveCommandHistory("axon-command;token;meta;" + Data("/tmp/中文".utf8).base64EncodedString())
        _ = session.receiveCommandHistory("axon-command;token;end;1;12")
        XCTAssertEqual(history.entries.first?.exitCode, 1); XCTAssertEqual(history.entries.first?.duration, 12); XCTAssertEqual(history.entries.first?.directory, "/tmp/中文")
        XCTAssertEqual(CommandHistoryStore(fileURL: history.fileURL).entries, history.entries)
        store.workspace.preferences.commandHistoryExclusions = "private-command"
        _ = session.receiveCommandHistory("axon-command;token;" + Data("private-command".utf8).base64EncodedString())
        XCTAssertEqual(history.entries.count, 1)
    }
    func testBashAndZshReportActualFailureStatusAndDirectory() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-i"] : ["-f", "-i"]
            var environment = ProcessInfo.processInfo.environment; environment["HISTFILE"] = "/dev/null"; environment["TERM"] = "dumb"; environment["PS1"] = ""; process.environment = environment
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            input.fileHandleForWriting.write(Data((ShellCommandIntegration.script(token: "test") + "\nfalse\npwd\nexit\n").utf8)); try input.fileHandleForWriting.close()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(text.contains("axon-command;test;end;1;"), shell + text)
            XCTAssertTrue(text.contains("axon-command;test;meta;"), shell)
        }
    }
    @MainActor func testOperationViewsRenderAndKeywordOverlayPreservesOriginalBuffer() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.keywordRules = KeywordRule.presets
        let session = TerminalSession(host: TabbyNative.Host(), store: store); store.sessions = [session]
        let terminal = RemoteTerminal(frame: NSRect(x: 0, y: 0, width: 1000, height: 400), font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular))
        terminal.terminalDelegate = session; session.terminal = terminal
        TerminalAppearance.apply(store.workspace.preferences, to: terminal)
        try terminal.setUseMetal(false)
        terminal.feed(text: "中文 ERROR connection failed\r\nWARN disk space\r\nplain text\r\n")
        KeywordOverlay.attach(to: terminal, store: store, sessionID: session.id)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        defer { window.close(); session.disconnect() }
        try await Task.sleep(for: .milliseconds(250))
        let before = terminal.getBufferAsData(kind: .normal)
        try screenshot(terminal, path: "/private/tmp/axon-keywords-preview.png")
        XCTAssertEqual(terminal.getBufferAsData(kind: .normal), before)
        let batch = NSHostingView(rootView: BatchTasksView(center: store.batchTasks).environmentObject(store)); batch.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.setContentSize(batch.frame.size); window.contentView = batch
        try await Task.sleep(for: .milliseconds(150)); try screenshot(batch, path: "/private/tmp/axon-batch-preview.png")
        let keywords = NSHostingView(rootView: KeywordRulesPane(draft: .constant(store.workspace.preferences)).environmentObject(store)); keywords.frame = batch.frame
        window.contentView = keywords; try await Task.sleep(for: .milliseconds(150)); try screenshot(keywords, path: "/private/tmp/axon-keyword-settings-preview.png")
    }
    @MainActor private func screenshot(_ view: NSView, path: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    @MainActor private func wait(_ job: TransferJob, states: Set<String>) async throws {
        for _ in 0..<200 { if states.contains(job.state) { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for transfer: " + job.state)
    }
}

actor FailingWriteEndpoint: FileEndpoint {
    let files = LocalFiles()
    var failed = false
    func stat(_ path: String) async throws -> FileEntry { try await files.stat(path) }
    func list(_ path: String) async throws -> [FileEntry] { try await files.list(path) }
    func mkdir(_ path: String) async throws { try await files.mkdir(path) }
    func rename(_ a: String, _ b: String) async throws { try await files.rename(a, b) }
    func delete(_ entry: FileEntry) async throws { try await files.delete(entry) }
    func removeStagingFile(_ entry: FileEntry) async throws { try await files.removeStagingFile(entry) }
    func chmod(_ path: String, _ mode: UInt32) async throws { try await files.chmod(path, mode) }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data { try await files.read(path, offset: offset, count: count) }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws {
        if offset >= 256 * 1024, !failed { failed = true; throw AppFailure.message("Injected connection interruption") }
        try await files.write(path, offset: offset, bytes: bytes)
    }
}
