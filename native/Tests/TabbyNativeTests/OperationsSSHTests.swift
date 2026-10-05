import XCTest
import Foundation
import Citadel
import NIOSSH
@testable import TabbyNative

final class OperationsSSHTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback SSH/SFTP server required") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }
    private func client() async throws -> SSHClient {
        let info = try fixture(), port = try XCTUnwrap(info["port"] as? Int), publicKey = try XCTUnwrap(info["hostKey"] as? String)
        let settings = SSHClientSettings(host: "127.0.0.1", port: port, authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .trustedKeys([try NIOSSHPublicKey(openSSHPublicKey: publicKey)]))
        return try await SSHClient.connect(to: settings)
    }
    @MainActor func testRealSFTPEditUploadsExactContentKeepsOriginalAndRejectsConcurrentChange() async throws {
        let client = try await client()
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP(), backend = RemoteFiles(sftp)
        let path = "/external-edit-" + UUID().uuidString + ".conf"
        let initial = Data("server=原始\n".utf8); try await backend.write(path, offset: 0, bytes: initial)
        try await backend.chmod(path, 0o640)
        let entry = try await backend.stat(path)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-editor-working-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edit = try await ExternalEdit.prepare(entry: entry, backend: backend, directory: directory)
        try Data("server=修改\n".utf8).write(to: edit.localURL)
        try await edit.upload()
        let saved = try await backend.stat(path), data = try await backend.read(path, offset: 0, count: Int(saved.size))
        XCTAssertEqual(data, Data("server=修改\n".utf8)); XCTAssertEqual(saved.permissions & 0o777, 0o640)
        let backups = try await backend.list("/").filter { $0.path.hasPrefix(path + ".backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try await backend.read(backups[0].path, offset: 0, count: Int(backups[0].size)); XCTAssertEqual(backup, initial)
        try await backend.write(path, offset: 0, bytes: Data("changed elsewhere".utf8))
        try Data("my change".utf8).write(to: edit.localURL)
        do { try await edit.upload(); XCTFail("Concurrent write must be rejected") } catch {}
        let conflict = try await backend.read(path, offset: 0, count: 100); XCTAssertEqual(conflict, Data("changed elsewhere".utf8))
        try await backend.delete(try await backend.stat(path))
        for backup in backups { try await backend.removeStagingFile(backup) }
    }
    @MainActor func testRealBatchConcurrencyFailureRetryAndTimeout() async throws {
        let info = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-batch-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let port = try XCTUnwrap(info["port"] as? Int), key = try XCTUnwrap(info["hostKey"] as? String)
        store.workspace.trustedKeys["127.0.0.1:\(port)"] = key
        var hosts: [TabbyNative.Host] = []
        for i in 0..<4 {
            var host = TabbyNative.Host(); host.address = "127.0.0.1"; host.port = port; host.username = "test"; host.name = "Batch \(i)"
            try Secrets.save("test-password", id: host.id); hosts.append(host)
        }
        defer { hosts.forEach { try? Secrets.save("", id: $0.id) }; store.batchTasks.cancelAll() }
        store.workspace.hosts = hosts
        let center = store.batchTasks; center.concurrency = 2; center.timeout = 5
        try center.start(hosts: hosts, command: "printf '中文 output'; printf 'diagnostic' >&2; sleep 0.2; exit 7")
        var maximum = 0
        for _ in 0..<300 {
            maximum = max(maximum, center.results.filter { $0.state == "running" }.count)
            if !center.running { break }; try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(center.running); XCTAssertEqual(maximum, 2)
        XCTAssertTrue(center.results.allSatisfy { $0.state == "failed" && $0.exitCode == 7 && $0.output.contains("中文 output") && $0.output.contains("diagnostic") }, String(describing: center.results))
        center.command = "printf SHOULD_NOT_RUN"; center.retryFailed(); try await wait(center)
        XCTAssertTrue(center.results.allSatisfy { $0.exitCode == 7 && !$0.output.contains("SHOULD_NOT_RUN") })
        center.timeout = 1
        try center.start(hosts: [hosts[0]], command: "sleep 5; printf SHOULD_NOT_RUN")
        try await wait(center)
        XCTAssertEqual(center.results.first?.state, "timeout"); XCTAssertEqual(center.results.first?.exitCode, 124)
        XCTAssertFalse(center.results.first?.output.contains("SHOULD_NOT_RUN") ?? true)
    }
    @MainActor func testBatchCancellationTerminatesRemoteSupervisor() async throws {
        let info = try fixture(), port = try XCTUnwrap(info["port"] as? Int)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-batch-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "127.0.0.1"; host.port = port; host.username = "test"; host.name = "Cancel fixture"
        try Secrets.save("test-password", id: host.id)
        defer { try? Secrets.save("", id: host.id); store.batchTasks.cancelAll() }
        store.workspace.hosts = [host]; store.workspace.trustedKeys["127.0.0.1:\(port)"] = try XCTUnwrap(info["hostKey"] as? String)
        let path = root.appendingPathComponent("must-not-be-written").path
        store.batchTasks.timeout = 20
        try store.batchTasks.start(hosts: [host], command: "printf RUNNING; sleep 2; printf BAD >" + SnippetParameters.shellArgument(path))
        for _ in 0..<200 { if store.batchTasks.results.first?.output.contains("RUNNING") == true { break }; try await Task.sleep(for: .milliseconds(20)) }
        store.batchTasks.cancelAll(); try await wait(store.batchTasks)
        XCTAssertEqual(store.batchTasks.results.first?.state, "cancelled")
        try await Task.sleep(for: .seconds(2)); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    @MainActor func testTmuxSessionSurvivesDetachAndRefusesUnmanagedSessions() async throws {
        // The server fixture executes on this machine. It must have tmux 3.3+.
        let client = try await client()
        defer { Task { try? await client.close() } }
        let name = "axon-test-" + UUID().uuidString.lowercased()
        defer { Task { _ = try? await MonitoringSSHExecutor.execute(client: client, command: try PersistentSession.end(name: name), maximumBytes: 4096) } }
        let first = try await MonitoringSSHExecutor.execute(client: client, command: PersistentSession.preparation(name: name), maximumBytes: 4096)
        XCTAssertEqual(first, "created")
        try await Task.sleep(for: .milliseconds(300))
        let liveFile = FileManager.default.temporaryDirectory.appendingPathComponent("axon-tmux-survival-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: liveFile) }
        let command = "sleep 0.4; printf SURVIVED >" + SnippetParameters.shellArgument(liveFile.path)
        _ = try await MonitoringSSHExecutor.execute(client: client, command: "tmux send-keys -t =\(name): -l " + SnippetParameters.shellArgument(command) + "; tmux send-keys -t =\(name): Enter", maximumBytes: 4096)
        try? await client.close()
        try await Task.sleep(for: .milliseconds(600))
        let reopened = try await self.client()
        let second = try await MonitoringSSHExecutor.execute(client: reopened, command: PersistentSession.preparation(name: name), maximumBytes: 4096)
        XCTAssertEqual(second, "existing"); XCTAssertEqual(try String(contentsOf: liveFile, encoding: .utf8), "SURVIVED")
        _ = try await MonitoringSSHExecutor.execute(client: reopened, command: "tmux set-option -t =\(name): @axon-managed 0", maximumBytes: 4096)
        let refusal = try await MonitoringSSHExecutor.execute(client: reopened, command: PersistentSession.preparation(name: name), maximumBytes: 4096)
        XCTAssertEqual(refusal, "unmanaged-session-use-another-name")
        _ = try await MonitoringSSHExecutor.execute(client: reopened, command: PersistentSession.end(name: name), maximumBytes: 4096)
        try? await reopened.close()
    }
    @MainActor private func wait(_ center: BatchTaskCenter) async throws {
        for _ in 0..<500 { if !center.running { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Batch execution did not finish")
    }
}
