import Foundation
import SwiftUI
import AppKit
import NIO
import NIOSSH
import Citadel

struct PortForwardRule: Codable, Identifiable {
    var id = UUID()
    var name = ""
    var hostID: UUID?
    var kind = "local"
    var bindHost = "127.0.0.1"
    var bindPort = 8080
    var targetHost = "127.0.0.1"
    var targetPort = 80
    var isDynamic: Bool { kind == "dynamic" }
    var listeningAddress: String { (bindHost.contains(":") ? "[\(bindHost)]" : bindHost) + ":\(bindPort)" }
    func validate() throws {
        _ = try ConnectionValidation.forward(self)
    }
}

enum ForwardStartOrigin {
    case manual, scene
}

struct ActivityLog: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var category: String
    var event: String
    var host: String
    var failed: Bool
}

final class ForwardRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    init(_ peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let local = context.channel
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer).whenFailure { _ in if local.isActive { local.close(promise: nil) } }
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let local = context.channel
        let peer = self.peer
        let resume = local.isWritable
        peer.setOption(ChannelOptions.autoRead, value: resume).whenComplete { result in
            switch result {
            case .success: if resume { peer.read() }
            case .failure: if local.isActive { local.close(promise: nil) }
            }
        }
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.channel.close(promise: nil); peer.close(promise: nil) }
}

private final class ForwardSSHCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        if case .byteBuffer(let bytes) = value.data { context.fireChannelRead(wrapInboundOut(bytes)) }
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

final class LocalForwardEngine: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channels: [Channel] = []
    private var stopped = false
    private func keep(_ channel: Channel) {
        lock.lock(); let closed = stopped; if !closed { channels.append(channel) }; lock.unlock()
        if closed { channel.close(promise: nil) }
        else { channel.closeFuture.whenComplete { [weak self, weak channel] _ in
            guard let self, let channel else { return }; self.lock.lock(); self.channels.removeAll { $0 === channel }; self.lock.unlock()
        } }
    }
    func start(_ rule: PortForwardRule, client: SSHClient) async throws -> Int {
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [weak self] local in
                self?.keep(local)
                let promise = local.eventLoop.makePromise(of: Void.self)
                Task {
                    do {
                        let channel = try await client.createDirectTCPIPChannel(using: .init(targetHost: rule.targetHost, targetPort: rule.targetPort, originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))) { remote in
                            self?.keep(remote)
                            return remote.pipeline.addHandler(ForwardRelay(local))
                        }
                        try await local.pipeline.addHandler(ForwardRelay(channel)).get()
                        try await local.setOption(ChannelOptions.autoRead, value: true).get()
                        promise.succeed(())
                    } catch { local.close(promise: nil); promise.fail(error) }
                }
                return promise.futureResult
            }.bind(host: rule.bindHost, port: rule.bindPort).get()
        keep(listener)
        return listener.localAddress?.port ?? rule.bindPort
    }
    func startDynamic(_ rule: PortForwardRule, client: SSHClient, handshakeTimeout: TimeAmount = .seconds(30)) async throws -> Int {
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { [weak self] local in
                self?.keep(local)
                let handler = Socks5Handler(timeout: handshakeTimeout) { request, socket in
                    let promise = socket.eventLoop.makePromise(of: Channel.self)
                    Task {
                        do {
                            let origin = try socket.remoteAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                            let remote = try await client.createDirectTCPIPChannel(using: .init(targetHost: request.host, targetPort: request.port, originatorAddress: origin)) { remote in
                                self?.keep(remote)
                                return Self.prepareDynamicRemote(remote, socket: socket)
                            }
                            promise.succeed(remote)
                        } catch { promise.fail(error) }
                    }
                    return promise.futureResult
                }
                return local.pipeline.addHandler(handler)
            }.bind(host: rule.bindHost, port: rule.bindPort).get()
        keep(listener)
        return listener.localAddress?.port ?? rule.bindPort
    }
    static func prepareDynamicRemote(_ remote: Channel, socket: Channel) -> EventLoopFuture<Void> {
        // An unconfirmed SSH child can fail before createDirectTCPIPChannel
        // returns. Its errors/inactivity must not close the SOCKS socket before
        // Socks5Handler flushes the failure reply. The relay is installed only
        // after the success reply has been flushed.
        socket.closeFuture.whenComplete { [weak remote] _ in remote?.close(promise: nil) }
        return remote.setOption(ChannelOptions.autoRead, value: false)
    }
    func startRemote(_ rule: PortForwardRule, client: SSHClient, onOpen: @escaping @Sendable (SSHRemotePortForward) async throws -> Void) async throws {
        try await client.withRemotePortForward(host: rule.bindHost, port: rule.bindPort, onOpen: onOpen) { [weak self] remote, _ in
            self?.keep(remote)
            return remote.pipeline.addHandler(ForwardSSHCodec()).flatMap {
                ClientBootstrap(group: remote.eventLoop).channelOption(ChannelOptions.autoRead, value: false).connect(host: rule.targetHost, port: rule.targetPort)
            }.flatMap { local in
                self?.keep(local)
                return remote.pipeline.addHandler(ForwardRelay(local)).flatMap { local.pipeline.addHandler(ForwardRelay(remote)) }.flatMap { local.setOption(ChannelOptions.autoRead, value: true) }
            }
        }
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; let active = channels; channels = []; lock.unlock()
        for channel in active { channel.close(promise: nil) }
        group.shutdownGracefully { _ in }
    }
    deinit { stop() }
}

extension AppStore {
    func removeForward(_ id: UUID) throws {
        let previous = workspace
        workspace.forwards.removeAll { $0.id == id }
        for index in workspace.workScenes.indices { workspace.workScenes[index].forwardIDs.removeAll { $0 == id } }
        guard save() else {
            workspace = previous
            throw AppFailure.message(error ?? text("Could not save workspace", "无法保存配置"))
        }
        for scene in openScenes { scene.definition.forwardIDs.removeAll { $0 == id } }
        sceneManagedForwardIDs.remove(id)
        if forwardTasks[id] != nil { stopForward(id) }
        forwardStatus.removeValue(forKey: id)
    }
    func saveForward(_ original: PortForwardRule) throws {
        let rule = try ConnectionValidation.forward(original, workspace: workspace, chinese: chinese)
        let previous = workspace
        if let index = workspace.forwards.firstIndex(where: { $0.id == rule.id }) { workspace.forwards[index] = rule }
        else { workspace.forwards.append(rule) }
        guard save() else { workspace = previous; throw AppFailure.message(error ?? text("Could not save workspace", "无法保存配置")) }
    }
    func record(_ category: String, _ event: String, host: String = "", failed: Bool = false) {
        workspace.logs.append(ActivityLog(category: category, event: event, host: host, failed: failed))
        if workspace.logs.count > 500 { workspace.logs.removeFirst(workspace.logs.count - 500) }
        save()
    }
    func startForward(_ original: PortForwardRule, origin: ForwardStartOrigin = .manual) {
        guard forwardTasks[original.id] == nil else { return }
        sceneManagedForwardIDs.remove(original.id)
        let rule: PortForwardRule
        let host: Host
        do {
            rule = try ConnectionValidation.forward(original, workspace: workspace, chinese: chinese)
            guard let saved = workspace.hosts.first(where: { $0.id == rule.hostID }) else { throw AppFailure.message(text("Host not found", "主机不存在")) }
            _ = try ConnectionValidation.host(saved, workspace: workspace, chinese: chinese)
            // Keep the raw profile so group/shared secret ownership survives.
            host = saved
        } catch { self.error = error.localizedDescription; return }
        if case .scene = origin { sceneManagedForwardIDs.insert(rule.id) }
        forwardStatus[rule.id] = text("Connecting…", "正在连接…")
        forwardTasks[rule.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var session = sessions.first {
                    $0.matchesEndpoint(host) && $0.connected && $0.client?.isConnected == true
                } ?? sessions.first {
                    $0.matchesEndpoint(host) && ($0.connectionInProgress || (!$0.connected && ($0.terminal == nil || $0.task != nil)))
                }
                if session == nil {
                    let created = TerminalSession(host: host, store: self)
                    sessions.append(created); session = created
                }
                if let session { forwardSessionIDs[rule.id] = session.id }
                _ = session?.makeView()
                let waitLimit = max(30, workspace.preferences.sshConnectTimeout)
                for _ in 0..<(waitLimit * 10) {
                    try Task.checkCancellation()
                    if session?.connected == true { break }
                    if let session, session.terminal != nil, session.task == nil, !session.connectionInProgress { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard let client = session?.client, client.isConnected else { throw AppFailure.message("SSH connection unavailable") }
                switch rule.kind {
                case "local", "dynamic":
                    let engine = LocalForwardEngine(); forwardEngines[rule.id] = engine
                    do {
                        if rule.isDynamic { _ = try await engine.startDynamic(rule, client: client) }
                        else { _ = try await engine.start(rule, client: client) }
                    } catch let bindError as IOError where bindError.errnoCode == EADDRINUSE {
                        throw AppFailure.message(text("Listening port \(rule.listeningAddress) is already in use. Edit the rule or stop the other listener.", "监听端口 \(rule.listeningAddress) 已被占用，请修改规则或停止其他监听。"))
                    }
                    try Task.checkCancellation()
                    forwardStatus[rule.id] = text("Running", "运行中"); record("forward", rule.isDynamic ? "started SOCKS5" : "started local", host: rule.name)
                    while client.isConnected { try await Task.sleep(for: .seconds(1)) }
                    throw AppFailure.message(text("SSH disconnected", "SSH 已断开"))
                case "remote":
                    let engine = LocalForwardEngine(); forwardEngines[rule.id] = engine
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await engine.startRemote(rule, client: client) { _ in
                                await MainActor.run { self.forwardStatus[rule.id] = self.text("Running", "运行中"); self.record("forward", "started remote", host: rule.name) }
                            }
                        }
                        group.addTask {
                            while client.isConnected { try await Task.sleep(for: .seconds(1)) }
                            throw AppFailure.message("SSH disconnected")
                        }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                default: throw AppFailure.message(text("Unsupported forwarding type", "不支持的转发类型"))
                }
            } catch {
                if !(error is CancellationError) { forwardStatus[rule.id] = error.localizedDescription; record("forward", "start or connection failed", host: rule.name, failed: true) }
            }
            forwardEngines.removeValue(forKey: rule.id)?.stop()
            forwardSessionIDs.removeValue(forKey: rule.id)
            forwardTasks.removeValue(forKey: rule.id)
            sceneManagedForwardIDs.remove(rule.id)
            if Task.isCancelled || forwardStatus[rule.id] == text("Running", "运行中") { forwardStatus[rule.id] = text("Stopped", "已停止") }
        }
    }
    func stopForward(_ id: UUID) {
        forwardTasks[id]?.cancel(); forwardEngines.removeValue(forKey: id)?.stop()
        forwardSessionIDs.removeValue(forKey: id)
        sceneManagedForwardIDs.remove(id)
        forwardStatus[id] = text("Stopped", "已停止")
        record("forward", "stopped", host: workspace.forwards.first(where: { $0.id == id })?.name ?? "")
    }
}
