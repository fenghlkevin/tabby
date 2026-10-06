import Foundation
import NIO
import NIOSSH

/// A connection-scoped allowlist. Remote peers can only list or sign with the explicitly selected identity.
struct AgentForwardingPolicy {
    let identities: [AgentIdentity]
    func request(_ data: Data, path: String) throws -> Data {
        var packet = AgentPacket(data: data)
        switch try packet.byte() {
        case 11:
            guard packet.cursor == data.count else { throw AgentWire.failure }
            var reply = AgentPacket(data: Data([12])); reply.put(UInt32(identities.count))
            for identity in identities { reply.put(identity.blob); reply.put(Data(identity.comment.utf8)) }
            return reply.data
        case 13:
            let blob = try packet.string(), payload = try packet.string(), flags = try packet.uint32()
            guard packet.cursor == data.count, [UInt32(0), 2, 4].contains(flags), identities.contains(where: { $0.blob == blob && ($0.algorithm == "ssh-rsa" ? flags == 2 || flags == 4 : flags == 0) }) else { throw AgentWire.failure }
            return try AgentWire.request(data, socketPath: path)
        default: throw AgentWire.failure
        }
    }
}

final class AgentForwardingHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let path: String
    let policy: AgentForwardingPolicy
    private var buffer = ByteBuffer()
    private var busy = false
    private var requests = 0
    init(path: String, identities: [AgentIdentity]) { self.path = path; policy = .init(identities: identities) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data, buffer.readableBytes + bytes.readableBytes <= 1024 * 1024 + 4 else { context.close(promise: nil); return }
        buffer.writeBuffer(&bytes); process(context)
    }
    private func process(_ context: ChannelHandlerContext) {
        guard !busy, let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return }
        guard length > 0, length <= 1024 * 1024, requests < 10000 else { context.close(promise: nil); return }
        guard buffer.readableBytes >= Int(length) + 4 else { return }
        buffer.moveReaderIndex(forwardBy: 4)
        let request = Data(buffer.readBytes(length: Int(length))!)
        buffer.discardReadBytes(); busy = true; requests += 1
        let path = self.path, policy = self.policy
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = (try? policy.request(request, path: path)) ?? Data([5])
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                var frame = ByteBuffer(); frame.writeInteger(UInt32(reply.count)); frame.writeBytes(reply)
                context.writeAndFlush(self.wrapOutboundOut(.init(type: .channel, data: .byteBuffer(frame))), promise: nil)
                self.busy = false; self.process(context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
