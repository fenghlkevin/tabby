import XCTest
import Darwin
import Citadel
import NIOSSH
import NIO
@testable import TabbyNative

final class ForwardTests: XCTestCase {
    static func roundtrip(_ port: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure.message("socket failed") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw AppFailure.message("connect failed: \(errno)") }
        let bytes = [UInt8](repeating: 67, count: 65536)
        try bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count { let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0); guard n > 0 else { throw AppFailure.message("send failed") }; sent += n }
        }
        var received = [UInt8](); var buffer = [UInt8](repeating: 0, count: 8192)
        while received.count < bytes.count {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { throw AppFailure.message("receive failed: \(errno)") }
            received.append(contentsOf: buffer.prefix(n))
        }
        XCTAssertEqual(received, bytes)
    }
    func testLocalAndRemoteForwarding() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let key = try NIOSSHPublicKey(openSSHPublicKey: info["hostKey"] as! String)
        let client = try await SSHClient.connect(to: SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .trustedKeys([key])))
        let engine = LocalForwardEngine()
        var rule = PortForwardRule(); rule.bindPort = 0; rule.targetPort = info["echoPort"] as! Int
        do {
            let port = try await engine.start(rule, client: client)
            try await Task.detached { try Self.roundtrip(port) }.value
            let occupied = LocalForwardEngine(); var collision = rule; collision.bindPort = port
            do { _ = try await occupied.start(collision, client: client); XCTFail("Occupied port must fail") } catch {}
            occupied.stop(); engine.stop()
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var bind = sockaddr_in(); bind.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); bind.sin_family = sa_family_t(AF_INET); bind.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &bind) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }; XCTAssertEqual(bound, 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bind) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            rule.bindPort = Int(UInt16(bigEndian: bind.sin_port)); Darwin.close(fd)
            let remoteRule = rule
            let remoteEngine = LocalForwardEngine(); defer { remoteEngine.stop() }
            let (ports, continuation) = AsyncStream<Int>.makeStream()
            let remote = Task {
                defer { continuation.finish() }
                try await remoteEngine.startRemote(remoteRule, client: client) { opened in continuation.yield(opened.boundPort) }
            }
            var iterator = ports.makeAsyncIterator()
            guard let port = await iterator.next() else { throw AppFailure.message("remote bind failed") }
            do { try await Task.detached { try Self.roundtrip(port) }.value } catch { remote.cancel(); throw error }
            remote.cancel(); _ = try? await remote.value
            try await client.close()
        } catch { engine.stop(); try? await client.close(); throw error }
    }
    @MainActor func testRulesAndBoundedLogsPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json"); let store = AppStore(fileURL: url)
        var rule = PortForwardRule(); rule.name = "fixture"; rule.hostID = UUID(); try rule.validate()
        store.workspace.forwards = [rule]
        store.workspace.logs = (0..<501).map { ActivityLog(category: "fixture", event: "\($0)", host: "", failed: false) }
        store.record("ssh", "connected", host: "fixture")
        XCTAssertEqual(store.workspace.logs.count, 500)
        let loaded = AppStore(fileURL: url)
        XCTAssertEqual(loaded.workspace.forwards.first?.id, rule.id)
        XCTAssertEqual(loaded.workspace.logs.last?.event, "connected")
        XCTAssertTrue(loaded.forwardTasks.isEmpty)
        rule.bindPort = -1; XCTAssertThrowsError(try rule.validate())
    }
}
