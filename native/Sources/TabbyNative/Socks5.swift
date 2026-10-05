import Foundation
import NIO

struct Socks5Request: Equatable {
    let host: String
    let port: Int
}

enum Socks5HandshakeEvent: Equatable {
    case reply([UInt8])
    case connect(Socks5Request)
    case rejected([UInt8])
}

/// Incremental SOCKS5 negotiation. A domain stays a domain until the SSH server
/// receives the direct-tcpip request; this parser never performs a DNS lookup.
struct Socks5Handshake {
    static let maximumPendingBytes = 64 * 1024
    private enum Phase: Equatable { case greeting, request, opening, closed }
    private var phase = Phase.greeting
    private var bytes: [UInt8] = []
    var timeoutReply: [UInt8] { phase == .greeting ? [5, 255] : Self.reply(6) }

    static func reply(_ code: UInt8) -> [UInt8] {
        // SSH does not expose the destination socket's bound address.
        [5, code, 0, 1, 0, 0, 0, 0, 0, 0]
    }

    mutating func receive(_ input: [UInt8]) -> [Socks5HandshakeEvent] {
        guard phase != .closed else { return [] }
        guard input.count <= Self.maximumPendingBytes - bytes.count else {
            return reject(phase == .greeting ? [5, 255] : Self.reply(1))
        }
        bytes.append(contentsOf: input)
        var events: [Socks5HandshakeEvent] = []
        if phase == .greeting {
            guard bytes.count >= 2 else { return events }
            guard bytes[0] == 5, bytes[1] > 0 else { return reject([5, 255]) }
            let length = 2 + Int(bytes[1])
            guard bytes.count >= length else { return events }
            guard bytes[2..<length].contains(0) else { return reject([5, 255]) }
            bytes.removeFirst(length)
            phase = .request
            events.append(.reply([5, 0]))
        }
        guard phase == .request, bytes.count >= 4 else { return events }
        guard bytes[0] == 5, bytes[2] == 0 else { return events + reject(Self.reply(1)) }
        guard bytes[1] == 1 else { return events + reject(Self.reply(7)) }
        let addressLength: Int
        let start: Int
        switch bytes[3] {
        case 1: addressLength = 4; start = 4
        case 4: addressLength = 16; start = 4
        case 3:
            guard bytes.count >= 5 else { return events }
            addressLength = Int(bytes[4]); start = 5
            guard addressLength > 0 else { return events + reject(Self.reply(8)) }
        default: return events + reject(Self.reply(8))
        }
        let end = start + addressLength
        guard bytes.count >= end + 2 else { return events }
        let address = Array(bytes[start..<end])
        let host: String
        switch bytes[3] {
        case 1: host = address.map(String.init).joined(separator: ".")
        case 4:
            host = stride(from: 0, to: 16, by: 2).map {
                String(UInt16(address[$0]) << 8 | UInt16(address[$0 + 1]), radix: 16)
            }.joined(separator: ":")
        default:
            // SOCKS domain names are supplied by clients as ASCII/IDNA. Reject
            // controls, whitespace and ambiguous path/user delimiters.
            guard address.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 47 && $0 != 64 }),
                  let domain = String(bytes: address, encoding: .ascii) else {
                return events + reject(Self.reply(8))
            }
            host = domain
        }
        let port = Int(bytes[end]) << 8 | Int(bytes[end + 1])
        guard port > 0 else { return events + reject(Self.reply(1)) }
        bytes.removeFirst(end + 2)
        phase = .opening
        events.append(.connect(Socks5Request(host: host, port: port)))
        return events
    }

    mutating func takePendingData() -> [UInt8] {
        let pending = bytes
        bytes.removeAll(keepingCapacity: false)
        return pending
    }

    private mutating func reject(_ response: [UInt8]) -> [Socks5HandshakeEvent] {
        phase = .closed
        bytes.removeAll(keepingCapacity: false)
        return [.rejected(response)]
    }
}

/// All handler state is confined to the accepted socket's event loop. The
/// connector may use the SSH client's different loop and completes back here.
final class Socks5Handler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias Connector = (Socks5Request, Channel) -> EventLoopFuture<Channel>
    private let connector: Connector
    private let timeout: TimeAmount
    private var handshake = Socks5Handshake()
    private var timer: Scheduled<Void>?
    private var peer: Channel?
    private var closed = false

    init(timeout: TimeAmount = .seconds(30), connector: @escaping Connector) {
        self.timeout = timeout
        self.connector = connector
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let socket = context.channel
        timer = socket.eventLoop.scheduleTask(in: timeout) { [weak self] in
            guard let self else { return }
            self.reject(self.handshake.timeoutReply, socket: socket)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closed else { return }
        let socket = context.channel
        let loop = socket.eventLoop
        let buffer = unwrapInboundIn(data)
        if let peer {
            peer.writeAndFlush(buffer).whenFailure { _ in socket.close(promise: nil) }
            return
        }
        for event in handshake.receive(Array(buffer.readableBytesView)) {
            switch event {
            case .reply(let response): write(response, socket: socket)
            case .rejected(let response): reject(response, socket: socket)
            case .connect(let request):
                // Only an already-delivered read can add pending bytes now.
                socket.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in socket.close(promise: nil) }
                connector(request, socket).whenComplete { [weak self] result in
                    // ChannelHandlerContext.channel itself asserts its owning
                    // loop. Capture Channel/EventLoop before crossing loops.
                    guard socket.isActive else {
                        if case .success(let channel) = result { channel.close(promise: nil) }
                        return
                    }
                    loop.execute {
                        guard let self else {
                            if case .success(let channel) = result { channel.close(promise: nil) }
                            return
                        }
                        self.connected(result, socket: socket)
                    }
                }
            }
        }
    }

    private func connected(_ result: Result<Channel, Error>, socket: Channel) {
        guard !closed, socket.isActive else {
            if case .success(let channel) = result { channel.close(promise: nil) }
            return
        }
        switch result {
        case .failure: reject(Socks5Handshake.reply(1), socket: socket)
        case .success(let channel):
            guard channel.isActive else {
                channel.close(promise: nil)
                reject(Socks5Handshake.reply(1), socket: socket)
                return
            }
            peer = channel
            timer?.cancel(); timer = nil
            let pending = handshake.takePendingData()
            let response = socket.allocator.buffer(bytes: Socks5Handshake.reply(0))
            socket.writeAndFlush(response).whenComplete { result in
                guard case .success = result, socket.isActive else { channel.close(promise: nil); socket.close(promise: nil); return }
                // Relay lifecycle events and destination data only after the
                // reply reaches the SOCKS client. Rejected SSH opens have no
                // relay capable of prematurely closing this local socket.
                // closeFuture also covers a destination that closes before
                // the new relay receives its channelInactive event.
                channel.closeFuture.whenComplete { _ in if socket.isActive { socket.close(promise: nil) } }
                channel.pipeline.addHandler(ForwardRelay(socket)).flatMap {
                    if pending.isEmpty { return channel.eventLoop.makeSucceededVoidFuture() }
                    return channel.writeAndFlush(channel.allocator.buffer(bytes: pending))
                }.flatMap {
                    channel.setOption(ChannelOptions.autoRead, value: true)
                }.whenComplete { result in
                    switch result {
                    // NIOSSH's option setter updates the flag without issuing
                    // a read. Explicitly wake its queued destination data.
                    case .success:
                        channel.read()
                        if socket.isActive { socket.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in socket.close(promise: nil) } }
                    case .failure: channel.close(promise: nil); if socket.isActive { socket.close(promise: nil) }
                    }
                }
            }
        }
    }

    private func write(_ bytes: [UInt8], socket: Channel) {
        socket.writeAndFlush(socket.allocator.buffer(bytes: bytes), promise: nil)
    }

    private func reject(_ bytes: [UInt8], socket: Channel) {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        socket.writeAndFlush(socket.allocator.buffer(bytes: bytes)).whenComplete { _ in socket.close(promise: nil) }
        peer?.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if let peer {
            let socket = context.channel
            let resume = socket.isWritable
            peer.setOption(ChannelOptions.autoRead, value: resume).whenComplete { result in
                switch result {
                case .success: if resume { peer.read() }
                case .failure: if socket.isActive { socket.close(promise: nil) }
                }
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        timer?.cancel(); timer = nil
        peer?.close(promise: nil); peer = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if peer == nil { reject(Socks5Handshake.reply(1), socket: context.channel) }
        else { context.channel.close(promise: nil); peer?.close(promise: nil) }
    }
}
