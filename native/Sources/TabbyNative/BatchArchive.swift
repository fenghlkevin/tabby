import Foundation
import SwiftUI

struct BatchTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var notes = ""
    var command = ""
    var hostIDs: [UUID] = []
    var concurrency = 3
    var timeout = 60
    var parameters: [SnippetParameter] = []
    var updated = Date()
    func validated(chinese: Bool) throws -> Self {
        var value = self
        value.name = try ConnectionValidation.label(name, required: true, chinese: chinese)
        try SnippetInput.validate(command, chinese: chinese)
        guard (1...16).contains(concurrency), (1...3600).contains(timeout), hostIDs.count <= 256,
              Set(hostIDs).count == hostIDs.count else { throw AppFailure.message(chinese ? "请检查目标主机、并发数与超时。" : "Check targets, parallelism and timeout.") }
        value.parameters = try SnippetParameters.synchronized(parameters, body: command, chinese: chinese)
        value.updated = Date(); return value
    }
}
struct BatchTargetSnapshot: Codable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let port: Int
    let username: String
    let route: [MonitoringRouteHopSnapshot]
    init(_ host: Host, workspace: Workspace) {
        let resolved = GroupDefaults.resolved(host, workspace: workspace)
        id = host.id; name = host.name; address = resolved.address; port = resolved.port; username = resolved.username
        var hops: [MonitoringRouteHopSnapshot] = [], next = resolved.jumpHostID, seen: Set<UUID> = [host.id]
        while let key = next, seen.insert(key).inserted, let raw = workspace.hosts.first(where: { $0.id == key }) {
            let hop = GroupDefaults.resolved(raw, workspace: workspace)
            hops.insert(.init(address: hop.address, port: hop.port, username: hop.username), at: 0); next = hop.jumpHostID
        }
        route = hops
    }
    func matches(_ host: Host, workspace: Workspace) -> Bool { {
        let other = Self(host, workspace: workspace)
        return id == other.id && address == other.address && port == other.port && username == other.username && route == other.route
    }() }
}
struct MonitoringRouteHopSnapshot: Codable, Equatable { let address: String; let port: Int; let username: String }
struct BatchRun: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var finished: Date?
    var title: String
    var command: String
    var concurrency: Int
    var timeout: Int
    var targets: [BatchTargetSnapshot]
    var results: [BatchResult]
    var parentID: UUID?
    var truncated = false
    var interrupted = false
}
@MainActor final class BatchArchive: ObservableObject {
    @Published private(set) var runs: [BatchRun] = []
    @Published var error: String?
    let fileURL: URL
    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            runs = try JSONDecoder().decode([BatchRun].self, from: Data(contentsOf: fileURL))
            for index in runs.indices where runs[index].finished == nil {
                runs[index].interrupted = true; runs[index].finished = Date()
                for i in runs[index].results.indices where ["queued", "running"].contains(runs[index].results[i].state) {
                    runs[index].results[i].state = "interrupted"; runs[index].results[i].finished = Date()
                }
            }
            try persist()
        } catch { self.error = error.localizedDescription }
    }
    func save(_ source: BatchRun) throws {
        guard error == nil else { throw AppFailure.message("Cannot overwrite unreadable task history / 任务历史读取失败，不能覆盖") }
        var run = source
        for index in run.results.indices {
            let output = run.results[index].output
            let diagnostic = run.results[index].error
            if output.utf8.count > 128 * 1024 || diagnostic.utf8.count > 16 * 1024 { run.truncated = true }
            run.results[index].output = String(decoding: output.utf8.prefix(128 * 1024), as: UTF8.self)
            run.results[index].error = String(decoding: diagnostic.utf8.prefix(16 * 1024), as: UTF8.self)
        }
        let old = runs
        runs.removeAll { $0.id == run.id }; runs.insert(run, at: 0); runs = Array(runs.prefix(100))
        while runs.count > 1 {
            if try JSONEncoder().encode(runs).count <= 50 * 1024 * 1024 { break }
            runs.removeLast()
        }
        do { try persist() } catch { runs = old; self.error = error.localizedDescription; throw error }
    }
    func remove(_ id: UUID) throws {
        guard error == nil else { throw AppFailure.message("Task history is unavailable / 任务历史不可用") }
        let old = runs; runs.removeAll { $0.id == id }
        do { try persist() } catch { runs = old; self.error = error.localizedDescription; throw error }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(runs).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum BatchStatus {
    static func title(_ state: String, chinese: Bool) -> String {
        chinese ? ["queued": "排队", "running": "执行中", "success": "成功", "failed": "失败", "timeout": "超时", "cancelled": "已取消", "interrupted": "中断，结果未知"][state] ?? state : state.capitalized
    }
}
