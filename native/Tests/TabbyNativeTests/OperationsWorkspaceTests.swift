import XCTest
import Foundation
import AppKit
import SwiftTerm
import Citadel
import NIOSSH
@testable import TabbyNative

@MainActor final class OperationsWorkspaceTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("axon-operations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testHistoryReopensInterruptedRecordsAndRejectsChangedEndpoints() throws {
        let root = try temporary(), store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "prod-api"; host.address = "192.0.2.10"; host.username = "deploy"
        store.workspace.hosts = [host]
        var result = BatchResult(hostID: host.id, hostName: host.name); result.state = "running"; result.output = String(repeating: "中", count: 60000)
        let run = BatchRun(title: "health", command: "uptime", concurrency: 3, timeout: 60, targets: [BatchTargetSnapshot(host, workspace: store.workspace)], results: [result])
        let url = root.appendingPathComponent("batch-history.json"), archive = BatchArchive(fileURL: url)
        try archive.save(run)
        let reopened = BatchArchive(fileURL: url), saved = try XCTUnwrap(reopened.runs.first)
        XCTAssertEqual(saved.results.first?.state, "interrupted"); XCTAssertTrue(saved.interrupted); XCTAssertTrue(saved.truncated)
        XCTAssertLessThanOrEqual(saved.results.first?.output.utf8.count ?? 0, 128 * 1024 + 2)
        XCTAssertEqual(saved.command, "uptime"); XCTAssertEqual(saved.targets.first?.username, "deploy")
        var renamed = host; renamed.name = "renamed"
        XCTAssertTrue(saved.targets[0].matches(renamed, workspace: store.workspace))
        store.workspace.hosts[0].address = "192.0.2.11"
        XCTAssertThrowsError(try store.batchTasks.retry(saved)); XCTAssertFalse(store.batchTasks.running)
        XCTAssertEqual(reopened.runs.count, 1)
        try reopened.remove(saved.id); XCTAssertTrue(BatchArchive(fileURL: url).runs.isEmpty)
    }
    func testTemplatesRoundTripAndQuoteParametersWithoutSavingSecrets() throws {
        let root = try temporary(), store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var template = BatchTemplate(name: "查看日志", command: "tail -n {{count}} {{path}}", timeout: 90)
        template.parameters = [.init(name: "count", type: .number, defaultValue: "30"), .init(name: "path", type: .path)]
        template = try template.validated(chinese: true); store.workspace.batchTemplates = [template]; store.save()
        let reopened = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(reopened.workspace.batchTemplates, [template])
        var snippet = CommandSnippet(); snippet.body = template.command; snippet.parameters = template.parameters
        let expanded = try SnippetParameters.expanded(snippet, values: ["path": "/tmp/a'; touch bad"], chinese: true)
        XCTAssertEqual(expanded, "tail -n '30' '/tmp/a'\\''; touch bad'")
        XCTAssertThrowsError(try SnippetParameters.expanded(snippet, values: ["count": "x", "path": "/tmp/log"], chinese: true))
        var invalid = template; invalid.timeout = 0; XCTAssertThrowsError(try invalid.validated(chinese: false))
        let legacy = try JSONDecoder().decode(Workspace.self, from: Data("{}".utf8)); XCTAssertTrue(legacy.batchTemplates.isEmpty)
    }
    func testTranscriptPreservesFragmentedUTF8StripsControlPayloadsAndLocatesCommand() throws {
        let root = try temporary(), store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); session.connected = true
        let logs = store.sessionLogs; let id = try logs.begin(session: session)
        let command = "printf hello", token = "token"
        let report = "axon-command;\(token);" + Data(command.utf8).base64EncodedString()
        let bytes = Array(("开始\u{1b}[31m红色\u{1b}[0m\n\u{1b}]7;" + report + "\u{7}hello\n\u{1b}]52;c;c2VjcmV0\u{7}").utf8)
        for byte in bytes { logs.append([byte], id: id) }
        let entry = ExecutedCommand(hostID: nil, hostName: "Local", sessionID: session.id, command: command)
        logs.marker(entry, report: report, id: id); logs.stop(id)
        XCTAssertEqual(String(decoding: try logs.content(id), as: UTF8.self), "开始红色\nhello\n")
        XCTAssertEqual(logs.records.first?.markers.first?.offset, "开始红色\n".utf8.count)
        XCTAssertTrue(logs.locate(entry)); XCTAssertEqual(logs.selectedMarker, entry.id)
        let reopened = SessionLogStore(root: logs.root); XCTAssertEqual(reopened.records.first?.markers.first?.id, entry.id)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: logs.url(id).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try logs.remove(id); XCTAssertTrue(logs.records.isEmpty)
    }
    func testFourPaneGroupsPersistLayoutAndCloseWithoutClosingOtherTabs() throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: try temporary().appendingPathComponent("workspace.json"))
        store.connect(); let first = try XCTUnwrap(store.activeSession)
        store.split(); store.split(); store.split()
        XCTAssertEqual(store.visiblePaneIDs.count, 4); XCTAssertEqual(store.terminalTabs.count, 1)
        let all = store.visiblePaneIDs; store.split(); XCTAssertEqual(store.sessions.count, 4)
        let frames = TerminalPaneLayout.frames(count: 4, size: CGSize(width: 1000, height: 800))
        XCTAssertEqual(frames.count, 4); XCTAssertEqual(frames[0].width, 497); XCTAssertEqual(frames[2].minY, 403)
        let scene = store.captureScene(); XCTAssertEqual(scene.paneGroups, [[0, 1, 2, 3]])
        XCTAssertNoThrow(try scene.validated(workspace: store.workspace))
        store.separateSession(all[1]); XCTAssertEqual(store.terminalTabs.count, 2)
        store.close(all[2]); XCTAssertEqual(store.paneIDs(containing: first).count, 2)
        store.closeTerminalTab(first); XCTAssertEqual(store.sessions.map(\.id), [all[1]])
        store.close(all[1])
    }
    func testRealLocalPTYBroadcastPauseRepliesAndTranscript() async throws {
        _ = NSApplication.shared
        let root = try temporary(), store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let history = CommandHistoryStore(fileURL: root.appendingPathComponent("commands.json"))
        store.connect(); store.split()
        for session in store.sessions { session.commandHistoryStore = history; _ = session.makeView() }
        defer { for id in store.sessions.map(\.id) { store.close(id) } }
        for _ in 0..<200 { if store.sessions.allSatisfy({ $0.commandHistoryReady }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.sessions.allSatisfy { $0.commandHistoryReady })
        let first = store.sessions[0], second = store.sessions[1]
        first.startTranscript(); second.startTranscript()
        let logs = try XCTUnwrap(first.transcriptID)
        store.synchronizedTargets = Set(store.sessions.map(\.id)); store.synchronizationEnabled = true
        XCTAssertTrue(store.synchronizationReady)
        first.terminal?.send(data: Array("printf AXON_BROADCAST\\n\r".utf8)[...])
        for _ in 0..<100 { if history.entries.filter({ $0.command.contains("AXON_BROADCAST") }).count >= 2 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.entries.filter { $0.command.contains("AXON_BROADCAST") }.count, 2)
        first.writeInput(Array("printf ONLY_FIRST\r".utf8))
        for _ in 0..<100 { if history.entries.contains(where: { $0.command == "printf ONLY_FIRST" }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.entries.filter { $0.command == "printf ONLY_FIRST" }.count, 1)
        store.section = "hosts"; XCTAssertFalse(store.synchronizationReady)
        store.section = "terminal"; second.connected = false; XCTAssertFalse(store.synchronizationReady); second.connected = true
        try store.sendComposed("printf COMPOSED", targets: [first.id, second.id], run: true)
        for _ in 0..<100 { if history.entries.filter({ $0.command == "printf COMPOSED" }).count == 2 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.entries.filter { $0.command == "printf COMPOSED" }.count, 2)
        first.stopTranscript(); second.stopTranscript()
        XCTAssertTrue(String(decoding: try store.sessionLogs.content(logs), as: UTF8.self).contains("AXON_BROADCAST"))
        XCTAssertTrue(store.sessionLogs.records.contains { $0.markers.contains { $0.command == "printf COMPOSED" } })
    }
    func testIsolatedRealSSHAgentSignsAndAuthenticatesLoopbackSFTP() async throws {
        let root = try temporary(), socket = root.appendingPathComponent("agent.sock").path
        let agent = Process(); agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent"); agent.arguments = ["-D", "-a", socket]; agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run(); defer { agent.terminate(); agent.waitUntilExit() }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: socket) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let fixturePath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"]
        let fixture = try fixturePath.map { try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: $0))) as! [String: Any] }
        let keyPath: String
        if let fixture { keyPath = try XCTUnwrap(fixture["clientKey"] as? String) }
        else {
            keyPath = root.appendingPathComponent("key").path
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", keyPath])
        }
        try run("/usr/bin/ssh-add", [keyPath], environment: ["SSH_AUTH_SOCK": socket])
        let identities = try await Task.detached { try AgentWire.identities(path: socket) }.value
        let identity = try XCTUnwrap(identities.first)
        let signature = try await Task.detached { try AgentWire.sign(Data("axon-test".utf8), identity: identity, path: socket) }.value
        XCTAssertEqual(signature.count, 64)
        if let fixture {
            let port = try XCTUnwrap(fixture["port"] as? Int), hostKey = try XCTUnwrap(fixture["hostKey"] as? String)
            let settings = SSHClientSettings(host: "127.0.0.1", port: port, authenticationMethod: { .custom(AgentAuthentication(username: "test", path: socket, fingerprint: identity.fingerprint)) }, hostKeyValidator: .trustedKeys([try NIOSSHPublicKey(openSSHPublicKey: hostKey)]))
            let client = try await SSHClient.connect(to: settings)
            let sftp = try await client.openSFTP(); let files = RemoteFiles(sftp)
            let entries = try await files.list("/"); XCTAssertFalse(entries.isEmpty)
            try await client.close()
        }
        XCTAssertThrowsError(try AgentWire.decodeIdentities(Data([12, 0, 0, 0, 65])))
        var host = TabbyNative.Host(); host.address = "192.0.2.2"; host.auth = "agent"; host.agentSocketPath = socket
        XCTAssertNoThrow(try ConnectionValidation.host(host, workspace: Workspace()))
        XCTAssertTrue(SSHConnectionDiagnostics.command(host, workspace: Workspace()).contains("IdentityAgent="))
    }
    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new }); task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit(); XCTAssertEqual(task.terminationStatus, 0)
    }
}
