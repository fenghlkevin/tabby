import Foundation
import SwiftUI
import AppKit

struct SessionLogMarker: Codable, Identifiable {
    var id: UUID
    var command: String
    var offset: Int
    var date: Date
    var origin: CommandOrigin?
}
struct SessionLogRecord: Codable, Identifiable {
    var id = UUID()
    var sessionID: UUID
    var hostID: UUID?
    var title: String
    var endpoint: String
    var started = Date()
    var finished: Date?
    var bytes = 0
    var limited = false
    var markers: [SessionLogMarker] = []
}
/// Streaming escape removal preserves split UTF-8 bytes and excludes OSC/DCS payloads.
/// This is a text transcript, not a replay of cursor movements or full-screen apps.
struct TranscriptDecoder {
    enum Mode { case text, escape, csi, osc, oscEscape, string, stringEscape }
    var mode = Mode.text
    var payload: [UInt8] = []
    var offset = 0
    var reports: [(String, Int)] = []
    mutating func append(_ bytes: [UInt8]) -> Data {
        var plain: [UInt8] = []
        for byte in bytes {
            switch mode {
            case .text:
                if byte == 27 { mode = .escape }
                else if byte == 10 || byte == 9 || byte >= 32 && byte != 127 { plain.append(byte); offset += 1 }
                else if byte == 13 { plain.append(10); offset += 1 }
            case .escape:
                if byte == 91 { mode = .csi }
                else if byte == 93 { mode = .osc; payload = [] }
                else if [80, 88, 94, 95].contains(byte) { mode = .string }
                else if byte >= 0x30 && byte <= 0x7e { mode = .text }
            case .csi: if byte >= 0x40 && byte <= 0x7e { mode = .text }
            case .osc:
                if byte == 7 { finishOSC() }
                else if byte == 27 { mode = .oscEscape }
                else if payload.count < 18000 { payload.append(byte) }
            case .oscEscape:
                if byte == 92 { finishOSC() } else { mode = .osc }
            case .string: if byte == 27 { mode = .stringEscape }
            case .stringEscape: mode = byte == 92 ? .text : .string
            }
        }
        return Data(plain)
    }
    private mutating func finishOSC() {
        if let value = String(bytes: payload, encoding: .utf8), value.hasPrefix("7;axon-command;") { reports.append((String(value.dropFirst(2)), offset)); reports = Array(reports.suffix(256)) }
        payload = []; mode = .text
    }
}
@MainActor final class SessionLogStore: ObservableObject {
    static let maximumBytes = 20 * 1024 * 1024
    @Published private(set) var records: [SessionLogRecord] = []
    @Published var error: String?
    @Published var selectedID: UUID?
    @Published var navigationRequest = UUID()
    @Published var selectedMarker: UUID?
    let root: URL
    private var handles: [UUID: FileHandle] = [:]
    private var decoders: [UUID: TranscriptDecoder] = [:]
    private var utf8Suffix: [UUID: Data] = [:]
    private var pendingAnnotations: [UUID: [String]] = [:]
    private var flushTask: Task<Void, Never>?
    init(root: URL) {
        self.root = root
        let index = root.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do {
                records = try JSONDecoder().decode([SessionLogRecord].self, from: Data(contentsOf: index))
                for i in records.indices where records[i].finished == nil { records[i].finished = Date() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".txt") }
    func begin(session: TerminalSession) throws -> UUID {
        guard error == nil else { throw AppFailure.message("Session log index unavailable / 会话日志索引不可用") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = SessionLogRecord(sessionID: session.id, hostID: session.host?.id, title: session.displayTitle,
                                      endpoint: session.host.map { "\(session.authenticatedUsername ?? $0.username)@\(session.authenticatedAddress ?? $0.address):\(session.authenticatedPort ?? $0.port)" } ?? session.store.text("Local shell", "本地 Shell"))
        guard FileManager.default.createFile(atPath: url(record.id).path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw AppFailure.message("Cannot create transcript / 无法创建日志文件") }
        do {
            handles[record.id] = try FileHandle(forWritingTo: url(record.id)); decoders[record.id] = TranscriptDecoder(); records.insert(record, at: 0)
            // Retain up to 25 completed logs (~500 MiB); never evict an active recorder.
            while records.filter({ $0.finished != nil }).count > 25, let old = records.last(where: { $0.finished != nil }) { try remove(old.id) }
            try persist(); return record.id
        } catch { handles[record.id] = nil; decoders[record.id] = nil; records.removeAll { $0.id == record.id }; try? FileManager.default.removeItem(at: url(record.id)); throw error }
    }
    func append(_ bytes: [UInt8], id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), let handle = handles[id], var decoder = decoders[id] else { return }
        let text = decoder.append(bytes); decoders[id] = decoder
        let remaining = Self.maximumBytes - records[i].bytes
        do {
            let content = text.prefix(max(0, remaining)); try handle.write(contentsOf: content); records[i].bytes += content.count
            utf8Suffix[id] = Data(((utf8Suffix[id] ?? Data()) + content).suffix(4))
            if content.count < text.count || records[i].bytes == Self.maximumBytes { records[i].limited = true; stop(id); return }
            if annotationBoundary(id) { let queued = pendingAnnotations.removeValue(forKey: id) ?? []; for value in queued { annotation(value, id: id) } }
            schedulePersist()
        } catch { self.error = error.localizedDescription; stop(id) }
    }
    func marker(_ entry: ExecutedCommand, report: String, id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), handles[id] != nil else { return }
        let offset = decoders[id]?.reports.first(where: { $0.0 == report })?.1 ?? records[i].bytes
        decoders[id]?.reports.removeAll { $0.0 == report }
        if records[i].markers.count < 10000 { records[i].markers.append(.init(id: entry.id, command: entry.command, offset: min(offset, records[i].bytes), date: entry.date, origin: entry.origin)); schedulePersist()
            if let origin = entry.origin { annotation("command source / 命令来源: " + origin.title(chinese: true), id: id) }
        }
    }
    private func annotationBoundary(_ id: UUID) -> Bool {
        let bytes = Array(utf8Suffix[id] ?? Data())
        guard let last = bytes.last, last >= 0x80 else { return true }
        var index = bytes.count - 1
        while index > 0 && bytes[index] & 0xc0 == 0x80 { index -= 1 }
        let first = bytes[index], expected = first & 0xe0 == 0xc0 ? 2 : first & 0xf0 == 0xe0 ? 3 : first & 0xf8 == 0xf0 ? 4 : 1
        return bytes.count - index >= expected
    }
    /// Attribution belongs only to the saved transcript, never bytes sent to the shell.
    func annotation(_ value: String, id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), let handle = handles[id] else { return }
        guard annotationBoundary(id) else { if (pendingAnnotations[id]?.count ?? 0) < 1000 { pendingAnnotations[id, default: []].append(value) }; return }
        let data = Data(("\n[Axon · " + value + "]\n").utf8)
        let content = data.prefix(max(0, Self.maximumBytes - records[i].bytes))
        do { try handle.write(contentsOf: content); records[i].bytes += content.count; decoders[id]?.offset += content.count
            if content.count < data.count || records[i].bytes == Self.maximumBytes { records[i].limited = true; stop(id) } else { schedulePersist() }
        } catch { self.error = error.localizedDescription; stop(id) }
    }
    func isRecording(_ id: UUID) -> Bool { handles[id] != nil }
    func stop(_ id: UUID) {
        try? handles.removeValue(forKey: id)?.close(); decoders[id] = nil; utf8Suffix[id] = nil; pendingAnnotations[id] = nil
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].finished = Date() }
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func remove(_ id: UUID) throws {
        guard handles[id] == nil else { throw AppFailure.message("Stop recording before deleting / 请先停止记录再删除") }
        try FileManager.default.removeItem(at: url(id)); records.removeAll { $0.id == id }; try persist()
    }
    func content(_ id: UUID) throws -> Data { try Data(contentsOf: url(id)) }
    func locate(_ entry: ExecutedCommand) -> Bool {
        guard let record = records.first(where: { $0.markers.contains { $0.id == entry.id } }) else { return false }
        selectedID = record.id; selectedMarker = entry.id; navigationRequest = UUID(); return true
    }
    private func schedulePersist() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750)); guard let self else { return }; self.flushTask = nil
            do { try self.persist() } catch { self.error = error.localizedDescription }
        }
    }
    private func persist() throws {
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("index.json").path)
    }
}
@MainActor extension TerminalSession {
    func recordInputOrigin(_ origin: CommandOrigin, bytes: [UInt8] = []) {
        if bytes.contains(3) { commandOriginTracker = CommandOriginTracker() } else { commandOriginTracker.input(origin) }
        if let id = transcriptID, lastTranscriptOrigin != origin {
            store.sessionLogs.annotation("source / 来源: " + origin.title(chinese: true) + " · terminal input / 终端输入", id: id)
            lastTranscriptOrigin = origin
        }
    }
    func startTranscript() {
        guard connected, transcriptID == nil else { return }
        do { transcriptID = try store.sessionLogs.begin(session: self); lastTranscriptOrigin = nil } catch { store.error = error.localizedDescription }
    }
    func stopTranscript() { if let id = transcriptID { store.sessionLogs.stop(id) }; transcriptID = nil }
    func captureOutput(_ bytes: [UInt8]) {
        aiCommandCapture.receive(bytes, token: commandHistoryToken)
        aiTerminalOutputRevision &+= 1
        // Track DEC cursor-key mode from the same bytes fed to SwiftTerm, including split CSI.
        let controls = String(decoding: aiCommandCapture.recent.suffix(max(256, bytes.count + 32)), as: UTF8.self)
        if let regex = AICommandCapture.cursorExpression {
            let ns = controls as NSString
            for match in regex.matches(in: controls, range: NSRange(location: 0, length: ns.length)) {
                if match.range(at: 1).location == NSNotFound { aiApplicationCursor = false }
                else if ns.substring(with: match.range(at: 1)).split(separator: ";").contains("1") { aiApplicationCursor = ns.substring(with: match.range(at: 2)) == "h" }
            }
        }
        guard let id = transcriptID else { return }
        store.sessionLogs.append(bytes, id: id)
        if !store.sessionLogs.isRecording(id) { transcriptID = nil }
    }
}
