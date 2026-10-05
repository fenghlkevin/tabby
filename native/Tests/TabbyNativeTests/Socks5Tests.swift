import XCTest
import Darwin
import NIO
import NIOSSH
import Citadel
@testable import TabbyNative

final class Socks5Tests: XCTestCase {
    private static func domainRequest(_ host: String, port: Int) -> [UInt8] {
        [5, 1, 0, 3, UInt8(host.utf8.count)] + Array(host.utf8) + [UInt8(port >> 8), UInt8(port & 255)]
    }

    func testSOCKSAllHandshakeFragmentBoundariesAndCoalescedPayload() {
        let request = Self.domainRequest("axon-socks.test", port: 443)
        let message = [UInt8]([5, 2, 2, 0]) + request + [0, 13, 255, 42]
        let expected: [Socks5HandshakeEvent] = [.reply([5, 0]), .connect(.init(host: "axon-socks.test", port: 443))]
        for cut in 0...message.count {
            var parser = Socks5Handshake()
            let events = parser.receive(Array(message.prefix(cut))) + parser.receive(Array(message.dropFirst(cut)))
            XCTAssertEqual(events, expected, "cut \(cut)")
            XCTAssertEqual(parser.takePendingData(), [0, 13, 255, 42], "cut \(cut)")
        }
        var parser = Socks5Handshake()
        XCTAssertEqual(message.flatMap { parser.receive([$0]) }, expected)
        XCTAssertEqual(parser.takePendingData(), [0, 13, 255, 42])
    }

    func testSOCKSIPv4AndIPv6AddressDecoding() {
        var ipv4 = Socks5Handshake()
        XCTAssertEqual(ipv4.receive([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 4, 56]), [.reply([5, 0]), .connect(.init(host: "127.0.0.1", port: 1080))])
        var ipv6 = Socks5Handshake()
        let address: [UInt8] = [0x20, 1, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1]
        XCTAssertEqual(ipv6.receive([5, 1, 0, 5, 1, 0, 4] + address + [0, 80]), [.reply([5, 0]), .connect(.init(host: "2001:db8:0:0:0:0:0:1", port: 80))])
    }

    func testSOCKSRejectsUnsupportedAndMalformedRequests() {
        var unsupportedAuth = Socks5Handshake()
        XCTAssertEqual(unsupportedAuth.receive([5, 1, 2]), [.rejected([5, 255])])
        XCTAssertTrue(unsupportedAuth.receive([5, 1, 0]).isEmpty)
        var invalidVersion = Socks5Handshake()
        XCTAssertEqual(invalidVersion.receive([4, 1, 0]), [.rejected([5, 255])])
        for command: UInt8 in [2, 3] {
            var parser = Socks5Handshake()
            XCTAssertEqual(parser.receive([5, 1, 0, 5, command, 0, 1]), [.reply([5, 0]), .rejected(Socks5Handshake.reply(7))])
        }
        for request: [UInt8] in [[5, 1, 0, 9], [5, 1, 0, 3, 0], [5, 1, 0, 3, 1, 0, 0, 80]] {
            var parser = Socks5Handshake()
            _ = parser.receive([5, 1, 0])
            XCTAssertEqual(parser.receive(request), [.rejected(Socks5Handshake.reply(8))])
        }
        var zeroPort = Socks5Handshake()
        _ = zeroPort.receive([5, 1, 0])
        XCTAssertEqual(zeroPort.receive(Self.domainRequest("example.com", port: 0)), [.rejected(Socks5Handshake.reply(1))])
    }

    func testSOCKSPendingDataIsBoundedAndTimeoutDependsOnPhase() {
        var parser = Socks5Handshake()
        XCTAssertEqual(parser.timeoutReply, [5, 255])
        _ = parser.receive([5, 1, 0])
        XCTAssertEqual(parser.timeoutReply, Socks5Handshake.reply(6))
        _ = parser.receive(Self.domainRequest("example.com", port: 80))
        XCTAssertTrue(parser.receive(Array(repeating: 1, count: Socks5Handshake.maximumPendingBytes)).isEmpty)
        XCTAssertEqual(parser.receive([2]), [.rejected(Socks5Handshake.reply(1))])
        XCTAssertTrue(parser.takePendingData().isEmpty)
    }

    func testSOCKSRejectedSSHChildCannotCloseSocketBeforeFailureReply() throws {
        let localLoop = EmbeddedEventLoop(), sshLoop = EmbeddedEventLoop()
        let child = EmbeddedChannel(loop: sshLoop)
        let opened = localLoop.makePromise(of: Channel.self)
        let handler = Socks5Handler { _, socket in
            LocalForwardEngine.prepareDynamicRemote(child, socket: socket).flatMap { opened.futureResult }
        }
        let socket = EmbeddedChannel(handler: handler, loop: localLoop)
        defer { _ = try? socket.finish(acceptAlreadyClosed: true); _ = try? child.finish(acceptAlreadyClosed: true) }
        try socket.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1080)).wait()
        try child.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait()
        try socket.writeInbound(socket.allocator.buffer(bytes: [5, 1, 0] + Self.domainRequest("unavailable.invalid", port: 80)))
        localLoop.run(); sshLoop.run()
        XCTAssertEqual(try socket.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, [5, 0])
        // NIOSSH fires errorCaught/channelInactive on its initialized child
        // before createDirectTCPIPChannel's failure reaches the local loop.
        // Force that exact ordering instead of relying on thread scheduling.
        let rejection = AppFailure.message("SSH open administratively prohibited")
        child.pipeline.fireErrorCaught(rejection)
        XCTAssertThrowsError(try child.throwIfErrorCaught())
        try child.close().wait()
        sshLoop.run(); localLoop.run()
        XCTAssertTrue(socket.isActive, "An unconfirmed child cannot close the SOCKS handshake socket")
        opened.fail(rejection)
        localLoop.run(); sshLoop.run(); localLoop.run()
        XCTAssertEqual(try socket.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, Socks5Handshake.reply(1))
        XCTAssertFalse(socket.isActive, "Failure reply is flushed before the local socket closes")
    }

    func testSOCKSAlreadyClosedDestinationReturnsFailureReply() throws {
        let loop = EmbeddedEventLoop()
        let child = EmbeddedChannel(loop: loop)
        try child.close().wait(); loop.run()
        let handler = Socks5Handler { _, socket in socket.eventLoop.makeSucceededFuture(child as Channel) }
        let socket = EmbeddedChannel(handler: handler, loop: loop)
        defer { _ = try? socket.finish(acceptAlreadyClosed: true); _ = try? child.finish(acceptAlreadyClosed: true) }
        try socket.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1080)).wait()
        try socket.writeInbound(socket.allocator.buffer(bytes: [5, 1, 0] + Self.domainRequest("closed.invalid", port: 80)))
        loop.run()
        XCTAssertEqual(try socket.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, [5, 0])
        XCTAssertEqual(try socket.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, Socks5Handshake.reply(1))
        XCTAssertFalse(socket.isActive)
    }

    func testSOCKSLateConnectorCompletionAfterSocketTeardownClosesChild() throws {
        let localLoop = EmbeddedEventLoop(), sshLoop = EmbeddedEventLoop()
        let child = EmbeddedChannel(loop: sshLoop)
        let opened = sshLoop.makePromise(of: Channel.self)
        let handler = Socks5Handler { _, socket in
            LocalForwardEngine.prepareDynamicRemote(child, socket: socket).flatMap { opened.futureResult }
        }
        let socket = EmbeddedChannel(handler: handler, loop: localLoop)
        defer { _ = try? socket.finish(acceptAlreadyClosed: true); _ = try? child.finish(acceptAlreadyClosed: true) }
        try socket.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1080)).wait()
        try child.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait()
        try socket.writeInbound(socket.allocator.buffer(bytes: [5, 1, 0] + Self.domainRequest("late.invalid", port: 80)))
        localLoop.run(); sshLoop.run()
        XCTAssertEqual(try socket.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, [5, 0])
        try socket.close().wait()
        localLoop.run(); sshLoop.run()
        // A connector result from the other loop can arrive after the local
        // pipeline's contexts have already been removed.
        opened.succeed(child)
        sshLoop.run(); localLoop.run(); sshLoop.run()
        XCTAssertFalse(socket.isActive)
        XCTAssertFalse(child.isActive)
        XCTAssertNil(try socket.readOutbound(as: ByteBuffer.self))
    }

    @MainActor func testSOCKSRuleValidationPersistenceAndFixedRuleCompatibility() throws {
        var rule = PortForwardRule(); rule.kind = "dynamic"; rule.name = "Browser"; rule.hostID = UUID(); rule.bindPort = 1080
        rule.targetHost = ""; rule.targetPort = 0
        XCTAssertNoThrow(try rule.validate())
        rule.bindHost = "::1"; XCTAssertNoThrow(try rule.validate())
        XCTAssertEqual(rule.listeningAddress, "[::1]:1080")
        for address in ["0.0.0.0", "::", "192.168.1.1", "localhost"] {
            rule.bindHost = address; XCTAssertThrowsError(try rule.validate())
        }
        rule.bindHost = "127.0.0.1"
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: encoded)
        XCTAssertEqual(decoded.kind, "dynamic"); XCTAssertEqual(decoded.bindPort, 1080)
        rule.kind = "local"; XCTAssertThrowsError(try rule.validate())
        rule.targetHost = "127.0.0.1"; rule.targetPort = 80; XCTAssertNoThrow(try rule.validate())
        rule.kind = "remote"; XCTAssertNoThrow(try rule.validate())
        rule.kind = "future"; XCTAssertThrowsError(try rule.validate())
    }

    @MainActor func testSOCKSRuleRemovalUpdatesScenesAndRollsBackFailedSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var rule = PortForwardRule(); rule.kind = "dynamic"; rule.name = "Proxy"; rule.hostID = UUID()
        var scene = WorkScene(); scene.name = "Work"; scene.forwardIDs = [rule.id]
        store.workspace.forwards = [rule]; store.workspace.workScenes = [scene]
        try store.removeForward(rule.id)
        XCTAssertTrue(store.workspace.forwards.isEmpty)
        XCTAssertTrue(store.workspace.workScenes[0].forwardIDs.isEmpty)
        XCTAssertTrue(AppStore(fileURL: store.fileURL).workspace.workScenes[0].forwardIDs.isEmpty)
        // A directory cannot be atomically replaced by a workspace JSON file.
        let blocked = AppStore(fileURL: root)
        blocked.workspace.forwards = [rule]; blocked.workspace.workScenes = [scene]
        XCTAssertThrowsError(try blocked.removeForward(rule.id))
        XCTAssertEqual(blocked.workspace.forwards.first?.id, rule.id)
        XCTAssertEqual(blocked.workspace.workScenes[0].forwardIDs, [rule.id])
    }

    private static func connectedSocket(_ port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure.message("socket failed") }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw AppFailure.message("connect failed") }
        return fd
    }

    private static func write(_ bytes: [UInt8], fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { throw AppFailure.message("socket write failed") }
                offset += count
            }
        }
    }

    private static func read(_ count: Int, fd: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: max(1, min(count, 8192)))
        while result.count < count {
            let received = Darwin.recv(fd, &buffer, min(buffer.count, count - result.count), 0)
            guard received > 0 else { throw AppFailure.message("socket closed or timed out") }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    func testSOCKSProxyOverSSHAndCleanup() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback SSH fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let key = try NIOSSHPublicKey(openSSHPublicKey: info["hostKey"] as! String)
        let client = try await SSHClient.connect(to: SSHClientSettings(host: "127.0.0.1", port: info["port"] as! Int, authenticationMethod: { .passwordBased(username: "test", password: "test-password") }, hostKeyValidator: .trustedKeys([key])))
        let engine = LocalForwardEngine()
        var rule = PortForwardRule(); rule.kind = "dynamic"; rule.bindPort = 0
        do {
            let port = try await engine.startDynamic(rule, client: client)
            let echoPort = info["echoPort"] as! Int
            try await Task.detached {
                for domain in [false, true] {
                    let fd = try Self.connectedSocket(port); defer { Darwin.close(fd) }
                    let request = domain ? Self.domainRequest("axon-socks.test", port: echoPort) : [5, 1, 0, 1, 127, 0, 0, 1, UInt8(echoPort >> 8), UInt8(echoPort & 255)]
                    let initial: [UInt8] = [0, 1, 255, 13, 10]
                    // Negotiation, request and binary data coalesced in one write.
                    try Self.write([5, 1, 0] + request + initial, fd: fd)
                    XCTAssertEqual(try Self.read(2, fd: fd), [5, 0])
                    XCTAssertEqual(try Self.read(10, fd: fd), Socks5Handshake.reply(0))
                    XCTAssertEqual(try Self.read(initial.count, fd: fd), initial)
                    let payload = (0..<65536).map { UInt8($0 & 255) }
                    try Self.write(payload, fd: fd)
                    XCTAssertEqual(try Self.read(payload.count, fd: fd), payload)
                }
                let rejected = try Self.connectedSocket(port); defer { Darwin.close(rejected) }
                try Self.write([5, 1, 0, 5, 3, 0, 1], fd: rejected)
                XCTAssertEqual(try Self.read(2, fd: rejected), [5, 0])
                XCTAssertEqual(try Self.read(10, fd: rejected), Socks5Handshake.reply(7))
                for attempt in 0..<20 {
                    let failed = try Self.connectedSocket(port); defer { Darwin.close(failed) }
                    try Self.write([5, 1, 0] + Self.domainRequest("unavailable.invalid", port: 80), fd: failed)
                    XCTAssertEqual(try Self.read(2, fd: failed), [5, 0], "Rejected SSH open \(attempt)")
                    XCTAssertEqual(try Self.read(10, fd: failed), Socks5Handshake.reply(1), "Rejected SSH open \(attempt)")
                    var byte: UInt8 = 0
                    XCTAssertEqual(Darwin.recv(failed, &byte, 1, 0), 0, "Failure reply precedes closure \(attempt)")
                }
            }.value
            let occupied = LocalForwardEngine(); var collision = rule; collision.bindPort = port
            do { _ = try await occupied.startDynamic(collision, client: client); XCTFail("Occupied listening port must fail") } catch {}
            occupied.stop()
            let stalledEngine = LocalForwardEngine()
            let stalledPort = try await stalledEngine.startDynamic(rule, client: client, handshakeTimeout: .milliseconds(200))
            try await Task.detached {
                let fd = try Self.connectedSocket(stalledPort); defer { Darwin.close(fd) }
                XCTAssertEqual(try Self.read(2, fd: fd), [5, 255])
                var byte: UInt8 = 0; XCTAssertEqual(Darwin.recv(fd, &byte, 1, 0), 0)
            }.value
            stalledEngine.stop()
            engine.stop()
            try await Task.sleep(for: .milliseconds(100))
            try await Task.detached { XCTAssertThrowsError(try Self.connectedSocket(port)) }.value
            XCTAssertTrue(client.isConnected, "Stopping a rule must preserve the SSH session")
            try await client.close()
        } catch { engine.stop(); try? await client.close(); throw error }
    }
}
