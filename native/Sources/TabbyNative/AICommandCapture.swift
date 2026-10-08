import Foundation

/// Incremental OSC framing runs before SwiftTerm receives the bytes. A marker and
/// its command output may arrive in one packet or across several packets.
struct AICommandCapture {
    static let cursorExpression = try? NSRegularExpression(pattern: "\\x1b\\[\\?([0-9;]+)([hl])|\\x1bc")
    struct Entry {
        let command: String
        var directory: String?
        var output = Data()
        var truncated = false
        var exitCode: Int?
    }
    private enum State { case normal, escape, osc, oscEscape }
    private var state = State.normal
    private var osc = Data()
    private var oscOversized = false
    private(set) var current: Entry?
    private(set) var finished: [Entry] = []
    private(set) var recent = Data()
    mutating func receive(_ bytes: [UInt8], token: String) {
        var visible = Data()
        func append(_ byte: UInt8) { visible.append(byte) }
        for byte in bytes {
            switch state {
            case .normal:
                if byte == 27 { state = .escape }
                else { append(byte); capture(byte) }
            case .escape:
                if byte == 93 { state = .osc; osc.removeAll(keepingCapacity: true); oscOversized = false }
                else { append(27); append(byte); capture(27); capture(byte); state = .normal }
            case .osc:
                if byte == 7 { report(token); state = .normal }
                else if byte == 27 { state = .oscEscape }
                else if osc.count < 16384 { osc.append(byte) } else { oscOversized = true }
            case .oscEscape:
                if byte == 92 { report(token); state = .normal }
                else { if osc.count + 2 < 16384 { osc.append(27); osc.append(byte) } else { oscOversized = true }; state = .osc }
            }
        }
        recent.append(visible)
        if recent.count > 64 * 1024 { recent.removeFirst(recent.count - 64 * 1024) }
    }
    private mutating func capture(_ byte: UInt8) {
        guard current != nil else { return }
        if current!.output.count < 64 * 1024 { current!.output.append(byte) } else { current!.truncated = true }
    }
    private mutating func report(_ token: String) {
        guard !oscOversized, !token.isEmpty, let text = String(data: osc, encoding: .utf8) else { return }
        let prefix = "7;axon-command;" + token + ";"
        guard text.hasPrefix(prefix) else { return }
        let payload = String(text.dropFirst(prefix.count))
        if payload.hasPrefix("end;") {
            let fields = payload.split(separator: ";")
            guard fields.count == 3, let code = Int(fields[1]), let seconds = Double(fields[2]), seconds.isFinite, seconds >= 0, var entry = current else { return }
            entry.exitCode = code; finished.append(entry); finished = Array(finished.suffix(4)); current = nil
        } else if payload.hasPrefix("meta;") {
            if let bytes = Data(base64Encoded: String(payload.dropFirst(5))), let path = String(data: bytes, encoding: .utf8), !path.unicodeScalars.contains(where: { $0.value < 32 }) { current?.directory = path }
        } else if !["ready", "unsupported"].contains(payload), let command = CommandHistoryProtocol.decode("axon-command;" + token + ";" + payload, token: token), CommandHistoryProtocol.allowed(command) {
            current = Entry(command: command)
        }
    }
    static func describe(_ entry: Entry) -> String {
        "Command: " + AIContext.sanitize(entry.command) + "\nDirectory: " + AIContext.sanitize(entry.directory ?? "unknown") + "\n" + (entry.exitCode.map { "Verified hook exit: " + String($0) } ?? "Command still active; exit unknown") + "\nCommand output range:\n" + AIContext.sanitize(String(decoding: entry.output, as: UTF8.self)) + (entry.truncated ? "\n[Command output truncated]" : "")
    }
}
