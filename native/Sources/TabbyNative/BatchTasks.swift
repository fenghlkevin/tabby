import Foundation
import SwiftUI
import AppKit
import Citadel
import NIO

struct BatchResult: Codable, Identifiable {
    var id = UUID()
    var hostID: UUID
    var hostName: String
    var state = "queued"
    var started: Date?
    var finished: Date?
    var exitCode: Int?
    var output = ""
    var error = ""
}

enum BatchCommand {
    static func wrapped(_ command: String, timeout: Int, marker: String) throws -> String {
        try SnippetInput.validate(command, chinese: false)
        guard (1...3600).contains(timeout), marker.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { throw AppFailure.message("Invalid task settings") }
        // No stdin means interactive sudo/read cannot hang silently. GNU timeout
        // owns the process group and terminates descendants, not just the channel.
        let quoted = SnippetParameters.shellArgument(command)
        return "if command -v timeout >/dev/null 2>&1; then _axon_timeout=timeout; elif command -v gtimeout >/dev/null 2>&1; then _axon_timeout=gtimeout; else printf '%s\\n' 'GNU timeout is required for bounded batch tasks / 批量任务需要 GNU timeout'; printf '\\n\(marker):125\\n'; exit 0; fi; _axon_dir=/tmp/axon-task-\(marker); umask 077; mkdir \"$_axon_dir\" || exit 125; trap 'if [ -n \"${_axon_pid-}\" ]; then kill -TERM \"$_axon_pid\" 2>/dev/null; fi; rm -f \"$_axon_dir/pid\"; rmdir \"$_axon_dir\" 2>/dev/null' EXIT; trap 'exit 143' HUP INT TERM; \"$_axon_timeout\" -k 5 \(timeout) sh -c \(quoted) </dev/null & _axon_pid=$!; printf '%s' \"$_axon_pid\" >\"$_axon_dir/pid\"; wait \"$_axon_pid\"; _axon_status=$?; _axon_pid=; printf '\\n\(marker):%s\\n' \"$_axon_status\""
    }
    static func result(_ output: String, marker: String) -> (String, Int)? {
        guard let range = output.range(of: "\n" + marker + ":", options: .backwards),
              let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (String(output[..<range.lowerBound]), code)
    }
}

@MainActor final class BatchTaskCenter: ObservableObject {
    unowned let store: AppStore
    let archive: BatchArchive
    private var currentRun: BatchRun?
    private var archiveTask: Task<Void, Never>?
    @Published var results: [BatchResult] = []
    @Published var command = ""
    @Published var concurrency = 3
    @Published var timeout = 60
    @Published var running = false
    @Published var error = ""
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var hosts: [UUID: Host] = [:]
    private var commandSnapshot = ""
    private var timeoutSnapshot = 60
    private var concurrencySnapshot = 3
    init(store: AppStore) {
        self.store = store
        archive = BatchArchive(fileURL: store.fileURL.deletingLastPathComponent().appendingPathComponent("batch-history.json"))
    }
    func archiveCurrent() {
        guard var run = currentRun else { return }
        run.results = results; if !running { run.finished = Date() }
        currentRun = run
        do { try archive.save(run) } catch { self.error = store.text("Could not save task history: ", "任务历史保存失败：") + error.localizedDescription }
    }
    private func queueArchive() {
        guard archiveTask == nil else { return }
        archiveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self else { return }; self.archiveTask = nil; self.archiveCurrent()
        }
    }
    func retry(_ run: BatchRun) throws {
        guard !running else { throw AppFailure.message(store.text("Wait for the current task", "请等待当前任务结束")) }
        let failed = run.results.filter { ["failed", "timeout", "cancelled", "interrupted"].contains($0.state) }
        guard !failed.isEmpty else { return }
        var targets: [Host] = []
        for result in failed {
            guard let host = store.workspace.hosts.first(where: { $0.id == result.hostID }),
                  let snapshot = run.targets.first(where: { $0.id == host.id }), snapshot.matches(host, workspace: store.workspace) else {
                throw AppFailure.message(store.text("A target was removed or its endpoint changed. Load as a new task and review the targets.", "目标已删除或连接地址、账号、跳板发生变化。请载入为新任务，重新检查目标。"))
            }
            targets.append(host)
        }
        concurrency = run.concurrency; timeout = run.timeout; command = run.command
        try start(hosts: targets, command: run.command)
        currentRun?.parentID = run.id; archiveCurrent()
    }

    func start(hosts selected: [Host], command: String) throws {
        guard !running, !selected.isEmpty, Set(selected.map(\.id)).count == selected.count, selected.count <= 256, (1...16).contains(concurrency), (1...3600).contains(timeout) else { throw AppFailure.message("Choose 1–256 hosts, concurrency 1–16 and timeout 1–3600 / 请选择 1–256 台主机、并发 1–16、超时 1–3600 秒") }
        try SnippetInput.validate(command, chinese: store.chinese)
        self.hosts = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        commandSnapshot = command; timeoutSnapshot = timeout; concurrencySnapshot = concurrency
        results = selected.map { BatchResult(hostID: $0.id, hostName: $0.name.isEmpty ? $0.address : $0.name) }
        error = ""; running = true
        currentRun = BatchRun(title: String(command.split(separator: "\n").first ?? "Task").prefix(100).description,
                              command: command, concurrency: concurrency, timeout: timeout,
                              targets: selected.map { BatchTargetSnapshot($0, workspace: store.workspace) }, results: results)
        archiveCurrent(); schedule()
    }
    var retryPreview: String {
        (currentRun?.command ?? "") + "\n\n" + results.filter { ["failed", "timeout", "cancelled"].contains($0.state) }.map(\.hostName).joined(separator: "\n")
    }
    func retryFailed() {
        guard !running else { return }
        if var run = currentRun {
            run.results = results
            do { try retry(run) } catch { self.error = error.localizedDescription }
        }
    }
    func cancel(_ id: UUID) {
        guard let i = results.firstIndex(where: { $0.id == id }), ["queued", "running"].contains(results[i].state) else { return }
        tasks[id]?.cancel()
        if results[i].state == "queued" { results[i].state = "cancelled"; results[i].finished = Date() }
    }
    func cancelAll() { for result in results { cancel(result.id) }; schedule() }
    private func update(_ id: UUID, _ edit: (inout BatchResult) -> Void) { if let index = results.firstIndex(where: { $0.id == id }) { edit(&results[index]); queueArchive() } }
    private func schedule() {
        while tasks.count < concurrencySnapshot, let result = results.first(where: { $0.state == "queued" }) {
            update(result.id) { $0.state = "running"; $0.started = Date() }
            tasks[result.id] = Task { [weak self] in
                guard let self else { return }
                await self.execute(result)
                self.tasks.removeValue(forKey: result.id); self.schedule()
            }
        }
        running = !tasks.isEmpty || results.contains { $0.state == "queued" }
        if !running { archiveCurrent() }
    }
    private func execute(_ result: BatchResult) async {
        guard !Task.isCancelled else { update(result.id) { $0.state = "cancelled"; $0.finished = Date() }; return }
        let store = self.store
        var clients: [SSHClient] = []
        var needsRemoteCleanup = true
        let marker = "AXON_RESULT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            guard let host = hosts[result.hostID], !store.deletedHostIDs.contains(host.id) else { throw AppFailure.message("Host removed / 主机已移除") }
            let authentication = TerminalSession(host: host, store: store)
            var chain: [Host] = [], current: Host? = host, seen = Set<UUID>()
            while let value = current {
                guard seen.insert(value.id).inserted, chain.count < 16 else { throw AppFailure.message("Invalid jump route") }
                chain.insert(value, at: 0)
                current = store.resolvedHost(value).jumpHostID.flatMap { id in store.workspace.hosts.first { $0.id == id } }
                if store.resolvedHost(value).jumpHostID != nil, current == nil { throw AppFailure.message("Jump host removed") }
            }
            for hop in chain {
                try Task.checkCancellation()
                let settings = try authentication.settings(for: hop)
                let client: SSHClient
                if let parent = clients.last { client = try await parent.jump(to: settings) } else { client = try await SSHClient.connect(to: settings) }
                clients.append(client); try Task.checkCancellation()
            }
            guard let client = clients.last else { throw AppFailure.message("No connection") }
            let wrapped = try BatchCommand.wrapped(commandSnapshot, timeout: timeoutSnapshot, marker: marker)
            let clock = Task { try? await Task.sleep(for: .seconds(timeoutSnapshot + 25)); if !Task.isCancelled { try? await client.close() } }
            defer { clock.cancel() }
            var stdout = Data(), stderr = Data(), finished = false
            do { try await client.withExec(wrapped) { inbound, _ in
                for try await event in inbound {
                    try Task.checkCancellation()
                    switch event {
                    case .stdout(let data): stdout.append(contentsOf: data.readableBytesView)
                    case .stderr(let data): stderr.append(contentsOf: data.readableBytesView)
                    }
                    guard stdout.count + stderr.count <= 1024 * 1024 else { throw AppFailure.message("Output exceeds 1 MB / 输出超过 1 MB") }
                    let text = String(decoding: stdout, as: UTF8.self) + "\n" + String(decoding: stderr, as: UTF8.self)
                    update(result.id) { $0.output = text }
                }
                try Task.checkCancellation(); finished = true
            } } catch let e as ChannelError where e == .alreadyClosed && finished {}
            try Task.checkCancellation()
            guard let (output, code) = BatchCommand.result(String(decoding: stdout, as: UTF8.self), marker: marker) else { throw AppFailure.message("No exit status received / 未收到退出状态，任务可能超时或连接中断") }
            needsRemoteCleanup = false
            update(result.id) { $0.output = output + (stderr.isEmpty ? "" : "\n" + String(decoding: stderr, as: UTF8.self)); $0.exitCode = code; $0.state = code == 0 ? "success" : code == 124 || code == 137 ? "timeout" : "failed" }
        } catch {
            update(result.id) { $0.state = Task.isCancelled ? "cancelled" : "failed"; $0.error = error.localizedDescription }
        }
        if needsRemoteCleanup, let client = clients.last {
            let cleanup = Task { try? await MonitoringSSHExecutor.execute(client: client, command: "_axon_file=/tmp/axon-task-\(marker)/pid; if [ -f \"$_axon_file\" ]; then read -r _axon_pid <\"$_axon_file\"; case \"$_axon_pid\" in ''|*[!0-9]*) exit 0;; esac; kill -TERM \"$_axon_pid\" 2>/dev/null; fi", maximumBytes: 4096) }
            _ = await cleanup.value
        }
        for client in clients.reversed() { try? await client.close() }
        update(result.id) { $0.finished = Date() }
    }
    func export() throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Axon-task-results.json"
        if panel.runModal() == .OK, let url = panel.url { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(results).write(to: url, options: .atomic) }
    }
}

struct BatchTasksView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: BatchTaskCenter
    @State private var selected = Set<UUID>()
    @State private var library = "task"
    @State private var editingTemplate: BatchTemplate?
    @State private var selectedTemplate: BatchTemplate?
    @State private var search = ""
    @State private var showSelected = false
    @State private var hostPage = 0
    @State private var group = ""
    @State private var tag = ""
    @State private var snippetID: UUID?
    @State private var values: [String: String] = [:]
    @State private var confirming = false
    @State private var confirmingRetry = false
    @State private var selectedResult: UUID?
    @State private var resultFilter = "all"
    @State private var timeoutValid = true
    private var hosts: [Host] {
        if showSelected { return store.workspace.hosts.filter { displayedSelection.contains($0.id) } }
        return store.workspace.hosts.filter { (group.isEmpty || $0.group == group) && (tag.isEmpty || TagTokens.parse($0.tags).contains(tag)) && (search.isEmpty || ($0.name + " " + $0.address + " " + $0.tags).localizedCaseInsensitiveContains(search)) }
    }
    private var hostPageCount: Int { max(1, (hosts.count + 11) / 12) }
    private var currentHostPage: Int { min(hostPage, hostPageCount - 1) }
    private var pagedHosts: [Host] { Array(hosts.dropFirst(currentHostPage * 12).prefix(12)) }
    private var snippet: CommandSnippet? { store.workspace.snippets.first { $0.id == snippetID } }
    private var commandSnippet: CommandSnippet { var value = snippet ?? CommandSnippet(); value.body = center.command; value.parameters = selectedTemplate?.parameters ?? value.parameters; return value }
    private var expanded: String { (try? SnippetParameters.expanded(commandSnippet, values: values, chinese: store.chinese)) ?? center.command }
    private var displayedSelection: Set<UUID> { center.running ? Set(center.results.map(\.hostID)) : selected }
    private var selectedHosts: [Host] { store.workspace.hosts.filter { selected.contains($0.id) } }
    private var canRun: Bool { !center.running && timeoutValid && (1...16).contains(center.concurrency) && !selectedHosts.isEmpty && !center.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var retryable: Bool { center.results.contains { ["failed", "timeout", "cancelled"].contains($0.state) } }
    private var visibleResults: [BatchResult] { center.results.filter { matches($0, filter: resultFilter) } }
    private var displayedResult: BatchResult? { visibleResults.first { $0.id == selectedResult } ?? visibleResults.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                libraryNavigation
                if !center.error.isEmpty {
                    Label(center.error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.danger).textSelection(.enabled)
                }
                if library == "task" {
                targetPanel
                commandPanel
                resultsPanel
                } else {
                    BatchLibraryView(center: center, mode: library, load: load, edit: { editingTemplate = $0 })
                }
            }.frame(maxWidth: 1250, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.background).foregroundStyle(Palette.text).font(.system(size: 12))
        .sheet(item: $editingTemplate) { template in
            BatchTemplateEditor(value: template) { saved in
                if let i = store.workspace.batchTemplates.firstIndex(where: { $0.id == saved.id }) { store.workspace.batchTemplates[i] = saved }
                else { store.workspace.batchTemplates.insert(saved, at: 0) }
                store.save(); editingTemplate = nil
            }.environmentObject(store)
        }
        .onChange(of: store.workspace.hosts.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .appAlert(store.text("Retry failed targets?", "重试失败目标？"), isPresented: $confirmingRetry) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
            AppAlertButton(store.text("Run", "执行")) { center.retryFailed() }
        } message: { Text(center.retryPreview) }
        .appAlert(store.text("Run on selected hosts?", "在所选主机上执行？"), isPresented: $confirming) {
            AppAlertButton(store.text("Run", "执行")) {
                do {
                    let command = try SnippetParameters.expanded(commandSnippet, values: values, chinese: store.chinese)
                    try center.start(hosts: selectedHosts, command: command)
                    selectedResult = nil; resultFilter = "all"
                } catch { center.error = error.localizedDescription }
            }
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}.accessibilityIdentifier("axon-batch-confirm-cancel")
        } message: { Text("\(selectedHosts.count) " + store.text("hosts", "台主机") + "\n" + expanded) }
    }
    private func load(_ template: BatchTemplate) {
        guard !center.running else { return }
        selected = Set(template.hostIDs.filter { id in store.workspace.hosts.contains { $0.id == id } })
        selectedTemplate = template; snippetID = nil; values = [:]
        center.command = template.command; center.timeout = template.timeout; center.concurrency = template.concurrency
        timeoutValid = true; library = "task"; search = ""; group = ""; tag = ""; hostPage = 0
        let missing = template.hostIDs.count - selected.count
        center.error = missing > 0 ? store.text("\(missing) saved targets are unavailable. Review the selection before running.", "\(missing) 台保存的目标已不存在，请检查主机选择后再执行。") : ""
    }
    private var libraryNavigation: some View {
        HStack(spacing: 8) {
            ForEach([("task", store.text("Current task", "当前任务")), ("history", store.text("History", "执行历史")), ("templates", store.text("Templates", "任务模板"))], id: \.0) { item in
                Button(item.1) { library = item.0 }.buttonStyle(ChromeButtonStyle(prominent: library == item.0))
                    .accessibilityIdentifier("axon-batch-library-" + item.0)
            }
            Spacer()
            action(store.text("Save template", "保存模板"), id: "save-template", enabled: !center.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !center.running, width: 110) {
                var value = selectedTemplate ?? BatchTemplate()
                value.command = center.command; value.hostIDs = selectedHosts.map(\.id); value.concurrency = center.concurrency; value.timeout = center.timeout
                value.parameters = (try? SnippetParameters.synchronized(commandSnippet.parameters, body: value.command, chinese: store.chinese)) ?? []
                editingTemplate = value
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            PaneHeading(title: store.text("Batch tasks", "批量任务"), subtitle: store.text("Choose hosts, write a command and review results together.", "选择主机，编写命令，统一查看执行结果。"))
            Spacer(minLength: 8)
            if center.running {
                ProgressView().controlSize(.small)
                action(store.text("Cancel all", "取消全部"), id: "cancel-all", enabled: true, run: center.cancelAll)
            } else {
                action(store.text("Run task", "执行任务"), id: "run", prominent: true, enabled: canRun) { confirming = true }
            }
        }
    }
    private var targetPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.text("Target hosts", "目标主机"), systemImage: "server.rack").font(.system(size: 13, weight: .semibold))
                Spacer()
                action(showSelected ? store.text("Back to all", "返回全部") : store.text("Selected", "查看已选") + " (\(displayedSelection.count))", id: "show-selected", prominent: showSelected, enabled: true, width: 120) { showSelected.toggle() }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { targetSearch.frame(width: 260); targetFilters.frame(width: 320); targetActions; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 10) {
                    targetSearch
                    HStack(spacing: 10) { targetFilters; targetActions }
                }
            }
            Text(showSelected ? store.text("All selected hosts, regardless of search and filters", "全部已选主机，不受搜索和筛选影响") : "\(hosts.count) " + store.text("matching hosts", "台匹配主机"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            Group {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], alignment: .leading, spacing: 10) {
                    if hosts.isEmpty {
                        emptyState(store.workspace.hosts.isEmpty ? store.text("No hosts yet", "尚未添加主机") : store.text("No matching hosts", "没有匹配的主机"), symbol: "server.rack")
                    }
                    ForEach(pagedHosts) { host in
                        Button {
                            if selected.contains(host.id) { selected.remove(host.id) } else { selected.insert(host.id) }
                        } label: {
                            HStack(spacing: 9) {
                                AxonSelectionMark(selected: displayedSelection.contains(host.id))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.name.isEmpty ? host.address : host.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(RecentTargets.effectiveUsername(host, workspace: store.workspace) + "@" + host.address)
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 78)
                                .background(displayedSelection.contains(host.id) ? Palette.selected : Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                        }.buttonStyle(AxonSurfaceButtonStyle()).disabled(center.running).help(host.name + " · " + host.address)
                            .accessibilityLabel((host.name.isEmpty ? host.address : host.name) + (displayedSelection.contains(host.id) ? store.text(", selected", "，已选") : ""))
                            .accessibilityIdentifier("axon-batch-host-" + host.id.uuidString)
                    }
                    if hostPageCount > 1 {
                        ForEach(pagedHosts.count..<12, id: \.self) { _ in
                            Color.clear.frame(height: 78).accessibilityHidden(true).allowsHitTesting(false)
                        }
                    }
                }
            }
            if hostPageCount > 1 {
                HStack(spacing: 10) {
                    Text(store.text("12 hosts per page · Select all includes every matching host", "每页 12 台 · 全选包含全部匹配主机")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    action(store.text("Previous", "上一页"), id: "hosts-previous", enabled: currentHostPage > 0, width: 80) { hostPage = currentHostPage - 1 }
                    Text("\(currentHostPage + 1) / \(hostPageCount)").monospacedDigit().foregroundStyle(Palette.muted)
                    action(store.text("Next", "下一页"), id: "hosts-next", enabled: currentHostPage + 1 < hostPageCount, width: 80) { hostPage = currentHostPage + 1 }
                }
            }
        }.padding(16).batchPanel()
            .onChange(of: search) { _, _ in hostPage = 0 }
            .onChange(of: group) { _, _ in hostPage = 0 }
            .onChange(of: tag) { _, _ in hostPage = 0 }
            .onChange(of: showSelected) { _, _ in hostPage = 0 }
    }
    private var targetSearch: some View {
        VaultSearchField(placeholder: store.text("Search name or address", "搜索名称或地址"), text: $search).disabled(showSelected)
    }
    private var targetFilters: some View {
        HStack(spacing: 8) {
            filterMenu(title: group, choices: store.groups, selection: $group, all: store.text("All groups", "全部分组"))
            filterMenu(title: tag, choices: store.tags, selection: $tag, all: store.text("All tags", "全部标签"))
        }.disabled(showSelected)
    }
    private var targetActions: some View {
        HStack(spacing: 8) {
            action(store.text("Select all", "全选"), id: "select-all", enabled: !center.running && !hosts.isEmpty, width: 70) { selected.formUnion(hosts.map(\.id)) }
            action(store.text("Clear", "清空"), id: "clear", enabled: !center.running && !selected.isEmpty, width: 60) { selected.removeAll() }
        }.fixedSize()
    }
    private var commandPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.text("Command", "执行命令"), systemImage: "terminal").font(.system(size: 13, weight: .semibold))
                Spacer()
                AxonChoiceField(selection: $snippetID, choices: [(nil, store.text("Custom command", "自定义命令"))] + store.workspace.snippets.map { (Optional($0.id), $0.name) }, placeholder: store.text("Snippets", "代码片段"), symbol: "curlybraces", identifier: "axon-batch-snippet").frame(width: 220).disabled(center.running)
                    .onChange(of: snippetID) { _, id in
                        if let item = store.workspace.snippets.first(where: { $0.id == id }) { selectedTemplate = nil; values = [:]; center.command = item.body }
                    }
            }
            ZStack(alignment: .topLeading) {
                SnippetTextEditor(text: $center.command).disabled(center.running)
                if center.command.isEmpty {
                    Text(store.text("Enter a shell command…\nFor example: hostname && uptime", "输入 Shell 命令…\n例如：hostname && uptime"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).padding(12).allowsHitTesting(false)
                }
            }.frame(height: 180).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border.opacity(0.7), lineWidth: 1))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { taskSettings; Spacer(minLength: 0); selectedCaption }
                VStack(alignment: .leading, spacing: 10) { taskSettings; selectedCaption }
            }
            Text(store.text("Non-interactive commands · GNU timeout required on the server", "仅执行非交互命令 · 服务器需有 GNU timeout"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            if let parameters = try? SnippetParameters.synchronized(commandSnippet.parameters, body: center.command, chinese: store.chinese), !parameters.isEmpty {
                DisclosureGroup(store.text("Command parameters", "命令参数")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(parameters) { parameter in
                            HStack { Text(parameter.name).frame(width: 100, alignment: .leading); TextField(parameter.defaultValue, text: Binding(get: { values[parameter.name] ?? parameter.defaultValue }, set: { values[parameter.name] = $0 })).appInput() }
                        }
                        Text(expanded).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.padding(.top, 8)
                }.disabled(center.running)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).batchPanel()
    }
    private var taskSettings: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(store.text("Parallel", "并发数")).foregroundStyle(Palette.muted)
                AxonChoiceField(selection: $center.concurrency, choices: (1...16).map { ($0, String($0)) }, placeholder: store.text("Parallel", "并发数"), symbol: "square.stack.3d.up", identifier: "axon-batch-parallel").frame(width: 100).disabled(center.running)
            }
            HStack(spacing: 6) {
                Text(store.text("Timeout", "超时")).foregroundStyle(Palette.muted)
                IntegerInput(value: $center.timeout, valid: $timeoutValid, range: 1...3600, placeholder: "60", label: store.text("Timeout in seconds", "超时秒数"))
                    .frame(width: 84).disabled(center.running)
                Text(store.text("sec", "秒")).foregroundStyle(Palette.muted)
            }.help(store.text("1–3600 seconds", "1–3600 秒"))
        }.fixedSize()
    }
    private var selectedCaption: some View {
        Text(center.running ? store.text("Processing \(center.results.count) hosts", "正在处理 \(center.results.count) 台主机") : store.text("Run on \(selectedHosts.count) hosts", "将在 \(selectedHosts.count) 台主机上执行"))
            .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize()
    }
    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.text("Task results", "任务结果"), systemImage: "list.bullet.rectangle").font(.system(size: 13, weight: .semibold))
                Spacer()
                action(store.text("Export", "导出结果"), id: "export", enabled: !center.results.isEmpty, run: { do { try center.export() } catch { center.error = error.localizedDescription } })
                action(store.text("Retry failed", "重试失败项"), id: "retry", enabled: !center.running && retryable, run: { confirmingRetry = true })
            }
            HStack(spacing: 8) {
                resultChip("all", title: store.text("All", "全部"), color: Palette.accent)
                resultChip("success", title: store.text("Success", "成功"), color: .green)
                resultChip("failed", title: store.text("Failed", "失败"), color: Palette.danger)
                resultChip("active", title: store.text("In progress", "进行中"), color: Palette.muted)
            }
            if center.results.isEmpty {
                emptyState(store.text("Results appear here after you run a task", "执行任务后，在这里查看各主机的状态与输出"), symbol: "terminal")
            } else if visibleResults.isEmpty {
                emptyState(store.text("No results in this state", "暂无此状态的任务"), symbol: "line.3.horizontal.decrease.circle")
            } else {
                VStack(spacing: 0) {
                    resultColumns(name: store.text("Host", "主机"), status: Text(store.text("State", "状态")), duration: store.text("Time", "耗时"), code: store.text("Exit", "退出码"), action: AnyView(Text(store.text("Output", "输出"))))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.vertical, 9).background(Palette.sidebar)
                    ForEach(visibleResults) { result in
                        Divider()
                        Button { selectedResult = result.id } label: {
                            resultColumns(name: result.hostName, status: status(result), duration: duration(result), code: result.exitCode.map(String.init) ?? "—", action: AnyView(Image(systemName: "chevron.right").foregroundStyle(Palette.muted)))
                                .padding(.horizontal, 10).frame(minHeight: 42)
                                .background(displayedResult?.id == result.id ? Palette.selected.opacity(0.7) : .clear).contentShape(Rectangle())
                        }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-batch-output-" + result.id.uuidString)
                            .accessibilityLabel(result.hostName + " · " + store.text("View output", "查看输出"))

                    }
                }.clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border.opacity(0.7), lineWidth: 1))
                if let result = displayedResult { outputPanel(result) }
            }
        }.padding(16).batchPanel()
    }
    private func resultColumns<S: View>(name: String, status: S, duration: String, code: String, action: AnyView) -> some View {
        HStack(spacing: 10) {
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(name)
            status.frame(width: 88, alignment: .leading)
            Text(duration).monospacedDigit().frame(width: 60, alignment: .leading)
            Text(code).monospacedDigit().frame(width: 48, alignment: .leading)
            action.frame(width: 110, alignment: .trailing)
        }
    }
    private func outputPanel(_ result: BatchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(result.hostName + " · " + store.text("Command output", "命令输出")).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                if ["queued", "running"].contains(result.state) {
                    Button(store.text("Cancel", "取消")) { center.cancel(result.id) }.buttonStyle(ChromeButtonStyle())
                }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.output + (result.error.isEmpty ? "" : "\n" + result.error), forType: .string) } label: { Label(store.text("Copy", "复制"), systemImage: "doc.on.doc") }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-batch-copy")
            }.foregroundStyle(Color(hex: store.workspace.preferences.foreground)).padding(.horizontal, 12).padding(.vertical, 10)
            Divider().overlay(Palette.border.opacity(0.15))
            GeometryReader { geometry in
              ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    if !result.error.isEmpty { Text(result.error).foregroundStyle(.red) }
                    Text(result.output.isEmpty ? store.text("No output yet", "暂无输出") : result.output).foregroundStyle(Color(hex: store.workspace.preferences.foreground))
                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
              }
            }.frame(height: 145)
        }.background(Color(hex: store.workspace.preferences.background)).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func resultChip(_ filter: String, title: String, color: Color) -> some View {
        Button { resultFilter = filter } label: {
            HStack(spacing: 5) { Text(title); Text(String(center.results.filter { matches($0, filter: filter) }.count)).monospacedDigit() }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
                .background(color.opacity(resultFilter == filter ? 0.14 : 0.05)).clipShape(RoundedRectangle(cornerRadius: AxonButtonMetrics.radius))
                .overlay(RoundedRectangle(cornerRadius: AxonButtonMetrics.radius).stroke(color.opacity(resultFilter == filter ? 0.4 : 0), lineWidth: 1)).contentShape(Rectangle())
        }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-batch-filter-" + filter)
    }
    private func matches(_ result: BatchResult, filter: String) -> Bool {
        switch filter { case "success": return result.state == "success"; case "failed": return ["failed", "timeout", "cancelled"].contains(result.state); case "active": return ["queued", "running"].contains(result.state); default: return true }
    }
    private func status(_ result: BatchResult) -> some View {
        let color: Color = result.state == "success" ? .green : ["failed", "timeout"].contains(result.state) ? Palette.danger : Palette.muted
        let symbol = result.state == "success" ? "checkmark.circle.fill" : ["failed", "timeout"].contains(result.state) ? "exclamationmark.circle.fill" : result.state == "running" ? "arrow.triangle.2.circlepath" : "clock"
        return Label(store.text(result.state.capitalized, ["queued": "排队", "running": "执行中", "success": "成功", "failed": "失败", "timeout": "超时", "cancelled": "已取消"][result.state] ?? result.state), systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
    }
    private func duration(_ result: BatchResult) -> String {
        guard let start = result.started else { return "—" }
        return String(format: "%.1f s", max(0, (result.finished ?? Date()).timeIntervalSince(start)))
    }
    private func emptyState(_ title: String, symbol: String) -> some View {
        VStack(spacing: 8) { Image(systemName: symbol).font(.system(size: 22)); Text(title).font(.system(size: 11)).multilineTextAlignment(.center) }
            .foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
    }
    private func action(_ title: String, id: String, prominent: Bool = false, enabled: Bool, width: CGFloat = 100, run: @escaping () -> Void) -> some View {
        PreferencesActionButton(title: title, identifier: "axon-batch-" + id, prominent: prominent, enabled: enabled, action: run).frame(width: width, height: 30).disabled(!enabled)
    }
    private func filterMenu(title: String, choices: [String], selection: Binding<String>, all: String) -> some View {
        AxonChoiceField(selection: selection, choices: [("", all)] + choices.map { ($0, $0) }, placeholder: all,
                        symbol: all == store.text("All groups", "全部分组") ? "folder" : "tag",
                        identifier: all == store.text("All groups", "全部分组") ? "axon-batch-group" : "axon-batch-tag")
            .frame(maxWidth: .infinity).disabled(center.running)
    }
}
private extension View {
    func batchPanel() -> some View {
        background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.opacity(0.7), lineWidth: 1))
    }
}
