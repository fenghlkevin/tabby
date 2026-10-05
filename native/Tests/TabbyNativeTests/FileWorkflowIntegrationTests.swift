import XCTest
import Foundation
import Citadel
import NIOSSH
@testable import TabbyNative

final class FileWorkflowIntegrationTests: XCTestCase {
    @MainActor func testRemoteExactComparisonUploadsFixedDifferencesAndSecondComparisonIsIdentical() async throws {
        let client = try await connectWorkflowFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-workflow-local-" + UUID().uuidString)
        let remoteRoot = "/workflow-" + UUID().uuidString
        var remote: RemoteFiles?
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("same".utf8).write(to: root.appendingPathComponent("same.txt"))
            try Data("new!".utf8).write(to: root.appendingPathComponent("changed.txt"))
            let unicodeBytes = Data(String(repeating: "中文日志内容\n", count: 25_000).utf8)
            try unicodeBytes.write(to: root.appendingPathComponent("nested/新增中文.txt"))
            let backend = RemoteFiles(try await client.openSFTP()); remote = backend
            try await backend.mkdir(remoteRoot)
            try await backend.write(remoteRoot + "/same.txt", offset: 0, bytes: Data("same".utf8))
            try await backend.write(remoteRoot + "/changed.txt", offset: 0, bytes: Data("old!".utf8))
            try await backend.write(remoteRoot + "/keep.txt", offset: 0, bytes: Data("target-only".utf8))
            let sourcePane = FilePane(path: root.path, backend: LocalFiles())
            let targetPane = FilePane(path: remoteRoot, backend: backend)
            let queue = TransferQueue()
            let comparison = DirectoryComparisonModel(source: sourcePane, target: targetPane, queue: queue, direction: "upload")
            defer { comparison.close() }
            comparison.start()
            for _ in 0..<3_000 where comparison.scanning { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(comparison.complete, comparison.error)
            XCTAssertEqual(comparison.rows.first { $0.id == "same.txt" }?.difference, .same)
            XCTAssertEqual(comparison.rows.first { $0.id == "changed.txt" }?.difference, .changed)
            XCTAssertEqual(comparison.rows.first { $0.id == "nested/新增中文.txt" }?.difference, .added)
            XCTAssertEqual(comparison.rows.first { $0.id == "keep.txt" }?.difference, .targetOnly)
            XCTAssertEqual(comparison.overwriteCount, 1)
            let approvedCount = comparison.selectedRows.count
            try comparison.submit()
            await queue.runner?.value
            XCTAssertEqual(queue.jobs.count, approvedCount)
            XCTAssertTrue(queue.jobs.allSatisfy { $0.state == "completed" }, queue.jobs.map { $0.state + ": " + $0.error }.joined(separator: "\n"))
            XCTAssertTrue(queue.jobs.allSatisfy { $0.expectation != nil })
            let uploaded = try await readWorkflowFile(remoteRoot + "/nested/新增中文.txt", backend: backend)
            XCTAssertEqual(uploaded, unicodeBytes)
            let replacement = try await readWorkflowFile(remoteRoot + "/changed.txt", backend: backend)
            XCTAssertEqual(replacement, Data("new!".utf8))
            let kept = try await readWorkflowFile(remoteRoot + "/keep.txt", backend: backend)
            XCTAssertEqual(kept, Data("target-only".utf8))
            let empty = try await backend.stat(remoteRoot + "/empty")
            XCTAssertTrue(empty.directory)

            let second = try await comparison.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
            XCTAssertTrue(second.filter { $0.source != nil }.allSatisfy { $0.difference == .same }, second.map { $0.id + ": " + $0.difference.rawValue }.joined(separator: "\n"))
            XCTAssertEqual(second.first { $0.id == "keep.txt" }?.difference, .targetOnly)
            XCTAssertEqual(second.filter { $0.difference == .targetOnly }.map(\.id), ["keep.txt"])
            comparison.close()
            try await backend.delete(try await backend.stat(remoteRoot))
            try await backend.close(); try await client.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            if let remote {
                if let entry = try? await remote.stat(remoteRoot) { try? await remote.delete(entry) }
                try? await remote.close()
            }
            try? await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor func testRemoteLogReadsUTF8AppendsAndResumesAfterTruncation() async throws {
        let client = try await connectWorkflowFixture()
        let remoteRoot = "/workflow-" + UUID().uuidString
        var remote: RemoteFiles?
        var viewer: LogViewerModel?
        do {
            let backend = RemoteFiles(try await client.openSFTP()); remote = backend
            try await backend.mkdir(remoteRoot)
            let path = remoteRoot + "/应用.log"
            let initial = Data((0..<300).map { "原始日志 \($0)" }.joined(separator: "\n").appending("\n").utf8)
            try await backend.write(path, offset: 0, bytes: initial)
            let entry = try await backend.stat(path)
            let model = LogViewerModel(pane: FilePane(path: remoteRoot, backend: backend), entry: entry, title: "fixture log")
            viewer = model
            await model.pollOnce()
            XCTAssertTrue(model.error.isEmpty, model.error)
            XCTAssertEqual(model.lines.count, 200)
            XCTAssertEqual(model.lines.first?.text, "原始日志 100")

            let appended = Data("中文新增行\nerror: remote fixture\n".utf8)
            let first = Data(appended.prefix(2)), remaining = Data(appended.dropFirst(2))
            try await backend.write(path, offset: UInt64(initial.count), bytes: first)
            await model.pollOnce()
            try await backend.write(path, offset: UInt64(initial.count + first.count), bytes: remaining)
            await model.pollOnce()
            XCTAssertTrue(model.error.isEmpty, model.error)
            XCTAssertEqual(model.lines.suffix(2).map(\.text), ["中文新增行", "error: remote fixture"])
            XCTAssertTrue(model.lines.last?.isError == true)
            model.search = "中文新增"
            XCTAssertEqual(model.searchMatches.count, 1)

            try await backend.write(path, offset: 0, bytes: Data("重启后的日志\n".utf8))
            await model.pollOnce()
            XCTAssertEqual(model.status, "rotated")
            XCTAssertTrue(model.lines.contains { $0.text.contains("truncated or replaced") })
            XCTAssertEqual(model.lines.last?.text, "重启后的日志")
            XCTAssertTrue(model.exportedText.contains("原始日志 100"))
            XCTAssertTrue(model.exportedText.contains("重启后的日志"))
            model.close()
            try await backend.delete(try await backend.stat(remoteRoot))
            try await backend.close(); try await client.close()
        } catch {
            viewer?.close()
            if let remote {
                if let entry = try? await remote.stat(remoteRoot) { try? await remote.delete(entry) }
                try? await remote.close()
            }
            try? await client.close()
            throw error
        }
    }

    @MainActor private func connectWorkflowFixture() async throws -> SSHClient {
        guard let infoPath = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Set TABBY_TEST_SERVER to the loopback fixture") }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: infoPath)))
        guard let info = raw as? [String: Any], let port = info["port"] as? Int, (1...65_535).contains(port), let publicKey = info["hostKey"] as? String else {
            throw AppFailure.message("Invalid loopback fixture metadata")
        }
        let key = try NIOSSHPublicKey(openSSHPublicKey: publicKey)
        let settings = SSHClientSettings(host: "127.0.0.1", port: port,
            authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .trustedKeys([key]))
        return try await SSHClient.connect(to: settings)
    }

    @MainActor private func readWorkflowFile(_ path: String, backend: any FileEndpoint) async throws -> Data {
        let entry = try await backend.stat(path)
        var data = Data(), offset: UInt64 = 0
        while offset < entry.size {
            let bytes = try await backend.read(path, offset: offset, count: Int(min(256 * 1024, entry.size - offset)))
            guard !bytes.isEmpty else { throw AppFailure.message("Unexpected fixture EOF") }
            data.append(bytes); offset += UInt64(bytes.count)
        }
        return data
    }
}
