import SwiftUI
import AppKit

struct BatchLibraryView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: BatchTaskCenter
    @ObservedObject var archive: BatchArchive
    let mode: String
    let load: (BatchTemplate) -> Void
    let edit: (BatchTemplate) -> Void
    @State private var query = ""
    @State private var filter = "all"
    @State private var selectedID: UUID?
    @State private var retrying: BatchRun?
    @State private var deletingRun: BatchRun?
    @State private var deletingTemplate: BatchTemplate?
    init(center: BatchTaskCenter, mode: String, load: @escaping (BatchTemplate) -> Void, edit: @escaping (BatchTemplate) -> Void) {
        self.center = center; archive = center.archive; self.mode = mode; self.load = load; self.edit = edit
    }
    private var runs: [BatchRun] {
        archive.runs.filter { run in
            (query.isEmpty || (run.title + run.command + run.targets.map { $0.name + $0.address }.joined()).localizedCaseInsensitiveContains(query)) &&
            (filter == "all" || (filter == "failed" ? run.results.contains { $0.state != "success" } : run.results.allSatisfy { $0.state == "success" }))
        }
    }
    private var selected: BatchRun? { runs.first { $0.id == selectedID } ?? runs.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { search.frame(width: 330); if mode == "history" { statusFilter.frame(width: 180) }; Spacer() }
                VStack(alignment: .leading, spacing: 10) { search; if mode == "history" { statusFilter.frame(width: 180) } }
            }
            if let error = archive.error { Label(store.text("Task history is unavailable: ", "任务历史不可用：") + error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.danger).textSelection(.enabled) }
            if mode == "history" {
                Text(store.text("Up to 100 runs / 50 MiB locally; each target keeps 128 KiB of output. History is separate from workspace backups.", "本机最多保留 100 次／50 MiB，每台目标保存前 128 KiB 输出。执行历史独立于工作区备份。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if runs.isEmpty { empty("clock.arrow.circlepath", store.text("No task history", "暂无执行历史")) }
                else {
                    VStack(spacing: 0) {
                        ForEach(runs.prefix(100)) { run in
                            Button { selectedID = run.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: run.finished == nil ? "hourglass" : run.results.allSatisfy { $0.state == "success" } ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(run.results.allSatisfy { $0.state == "success" } ? Palette.accent : Palette.danger)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(run.date.formatted(date: .numeric, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    Text(store.text("\(run.results.filter { $0.state == "success" }.count)/\(run.results.count) succeeded", "\(run.results.filter { $0.state == "success" }.count)/\(run.results.count) 成功")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                                }.padding(12).background(selected?.id == run.id ? Palette.selected : Palette.card).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-history-run-" + run.id.uuidString)
                            Divider()
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                    if let run = selected {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                PaneHeading(title: store.text("Execution details", "执行详情"), subtitle: store.text("Saved endpoint snapshots · Current credentials used on retry", "保存执行时的地址快照 · 重试使用当前凭据"))
                                Spacer()
                                Button(store.text("Load as task", "载入为任务")) { load(template(run)) }.buttonStyle(ChromeButtonStyle()).disabled(center.running)
                                Button(store.text("Retry failed", "重试失败项")) { retrying = run }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(center.running || run.finished == nil || !run.results.contains { ["failed", "timeout", "cancelled", "interrupted"].contains($0.state) })
                                Button { deletingRun = run } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).disabled(center.running && run.finished == nil).help(store.text("Delete this record", "删除此记录"))
                            }
                            Text(run.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                            if run.interrupted { Label(store.text("The application closed before completion; remote outcome is unknown.", "应用在完成前退出，远端执行结果未知。"), systemImage: "exclamationmark.triangle").foregroundStyle(Palette.danger) }
                            if run.truncated { Label(store.text("Saved output was truncated. Export the live result for complete output.", "保存的输出已截断；完整输出请在当前任务中导出。"), systemImage: "text.badge.minus").foregroundStyle(Palette.muted) }
                            BatchSavedResults(run: run).id(run.id)
                        }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                Text(store.text("Templates save commands, parameter definitions and target references; they use current credentials when run.", "模板保存命令、参数定义与目标引用；执行时使用当前凭据。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                let templates = store.workspace.batchTemplates.filter { query.isEmpty || ($0.name + $0.notes + $0.command).localizedCaseInsensitiveContains(query) }
                if templates.isEmpty { empty("doc.on.doc", store.text("Save a current task as a template to reuse it", "将当前任务保存为模板，便于重复执行")) }
                ForEach(templates) { template in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(template.name, systemImage: "doc.text").font(.system(size: 14, weight: .semibold)); Spacer()
                            Button(store.text("Load", "载入")) { load(template) }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(center.running)
                            Button(store.text("Edit", "编辑")) { edit(template) }.buttonStyle(ChromeButtonStyle())
                            Button { deletingTemplate = template } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle())
                        }
                        if !template.notes.isEmpty { Text(template.notes).foregroundStyle(Palette.muted) }
                        Text(template.command).font(.system(size: 12, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                        Text(store.text("\(template.hostIDs.count) targets · parallel \(template.concurrency) · \(template.timeout)s · \(template.parameters.count) parameters", "\(template.hostIDs.count) 台目标 · 并发 \(template.concurrency) · \(template.timeout) 秒 · \(template.parameters.count) 个参数")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .appAlert(store.text("Retry failed targets?", "重试失败目标？"), isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } })) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { retrying = nil }
            AppAlertButton(store.text("Run", "执行")) { if let run = retrying { do { try center.retry(run) } catch { center.error = error.localizedDescription } }; retrying = nil }
        } message: { Text((retrying?.command ?? "") + "\n" + store.text("Creates a separate history record. Verify the command before running it again.", "将创建新的执行记录。请确认命令可再次执行。")) }
        .appAlert(store.text("Delete history record?", "删除执行记录？"), isPresented: Binding(get: { deletingRun != nil }, set: { if !$0 { deletingRun = nil } })) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { deletingRun = nil }
            AppAlertButton(store.text("Delete", "删除"), role: .destructive) { if let run = deletingRun { do { try archive.remove(run.id) } catch { center.error = error.localizedDescription } }; deletingRun = nil }
        } message: { Text(deletingRun?.title ?? "") }
        .appAlert(store.text("Delete template?", "删除任务模板？"), isPresented: Binding(get: { deletingTemplate != nil }, set: { if !$0 { deletingTemplate = nil } })) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { deletingTemplate = nil }
            AppAlertButton(store.text("Delete", "删除"), role: .destructive) { store.workspace.batchTemplates.removeAll { $0.id == deletingTemplate?.id }; store.save(); deletingTemplate = nil }
        } message: { Text(deletingTemplate?.name ?? "") }
    }
    private var search: some View { VaultSearchField(placeholder: store.text("Search command, name or target", "搜索命令、名称或目标"), text: $query) }
    private var statusFilter: some View { AxonChoiceField(selection: $filter, choices: [("all", store.text("All results", "全部结果")), ("success", store.text("All succeeded", "全部成功")), ("failed", store.text("Has incomplete targets", "包含未成功目标"))], placeholder: store.text("Result filter", "结果筛选"), symbol: "line.3.horizontal.decrease", identifier: "axon-history-filter") }
    private func template(_ run: BatchRun) -> BatchTemplate { BatchTemplate(name: run.title, command: run.command, hostIDs: run.targets.map(\.id), concurrency: run.concurrency, timeout: run.timeout) }
    private func empty(_ symbol: String, _ title: String) -> some View { VStack(spacing: 12) { Image(systemName: symbol).font(.system(size: 30)); Text(title) }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(40).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10)) }
}

struct BatchSavedResults: View {
    @EnvironmentObject var store: AppStore
    let run: BatchRun
    @State private var selectedID: UUID?
    private var selected: BatchResult? { run.results.first { $0.id == selectedID } ?? run.results.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(run.results) { result in
                let target = run.targets.first { $0.id == result.hostID }
                Button { selectedID = result.id } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.hostName).font(.system(size: 12, weight: .medium))
                            Text(target.map { "\($0.username)@\($0.address):\($0.port)" } ?? "").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }; Spacer()
                        Text(BatchStatus.title(result.state, chinese: store.chinese)).foregroundStyle(result.state == "success" ? Palette.accent : Palette.danger)
                        Text(result.exitCode.map { "exit \($0)" } ?? "—").frame(width: 64)
                        Image(systemName: "chevron.right")
                    }.padding(10).background(selected?.id == result.id ? Palette.selected : Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityIdentifier("axon-history-result-" + result.id.uuidString)
            }
            if let result = selected {
                HStack { Text(result.hostName).fontWeight(.medium); Spacer(); Button(store.text("Copy output", "复制输出")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.output + "\n" + result.error, forType: .string) }.buttonStyle(ChromeButtonStyle()) }
                ScrollView([.vertical, .horizontal]) {
                    Text(result.output + (result.error.isEmpty ? "" : "\n" + result.error)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }.frame(height: 220).foregroundStyle(Color(hex: store.workspace.preferences.foreground)).background(Color(hex: store.workspace.preferences.background)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct BatchTemplateEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var value: BatchTemplate
    let save: (BatchTemplate) -> Void
    @State private var error = ""
    @State private var timeoutValid = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "doc.text", size: 38)
                PaneHeading(title: store.text("Task template", "任务模板"), subtitle: store.text("Save reusable commands and target selection", "保存可复用命令与目标选择")); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(store.text("Name *", "名称 *")) { TextField(store.text("For example: production health check", "例如：生产环境健康检查"), text: $value.name).appInput() }
                    field(store.text("Description", "说明")) { TextField(store.text("Purpose and precautions", "用途与操作说明"), text: $value.notes).appInput() }
                    field(store.text("Command *", "命令 *")) { SnippetTextEditor(text: $value.command).frame(height: 160).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    HStack(spacing: 20) {
                        field(store.text("Parallel", "并发数")) { AxonChoiceField(selection: $value.concurrency, choices: (1...16).map { ($0, String($0)) }, placeholder: store.text("Parallel", "并发数"), symbol: "square.stack.3d.up", identifier: "axon-template-parallel") }.frame(width: 150)
                        field(store.text("Timeout (seconds)", "超时（秒）")) { IntegerInput(value: $value.timeout, valid: $timeoutValid, range: 1...3600, placeholder: "60", label: store.text("Timeout", "超时")) }.frame(width: 150)
                        Spacer()
                        Text(store.text("\(value.hostIDs.count) saved targets", "保存 \(value.hostIDs.count) 台目标")).foregroundStyle(Palette.muted)
                    }
                    DisclosureGroup(store.text("Saved targets", "保存的目标主机")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(value.hostIDs, id: \.self) { id in
                                if let host = store.workspace.hosts.first(where: { $0.id == id }) { Text((host.name.isEmpty ? host.address : host.name) + " · " + host.address).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                else { Label(store.text("Unavailable target", "目标已不存在"), systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger) }
                            }
                            Text(store.text("Load into the current task to change targets, then save the template again.", "如需调整目标，请载入当前任务，修改主机选择后重新保存模板。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.padding(.top, 8)
                    }
                    Text(store.text("Use {{name}} outside quotes for one shell argument. Configure defaults below; values are safely quoted on execution.", "在引号外使用 {{名称}} 表示一个 Shell 参数。下方可配置默认值，执行时自动安全引用。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    ForEach($value.parameters) { $parameter in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(parameter.name).fontWeight(.semibold); Spacer(); Toggle(store.text("Required", "必填"), isOn: $parameter.required).toggleStyle(AxonCheckboxStyle()) }
                            HStack(spacing: 12) {
                                AxonChoiceField(selection: $parameter.type, choices: SnippetParameterType.allCases.map { ($0, $0.title(chinese: store.chinese)) }, placeholder: store.text("Type", "类型"), symbol: "textformat", identifier: "axon-template-parameter-" + parameter.name).frame(width: 140)
                                TextField(store.text("Default value", "默认值"), text: $parameter.defaultValue).appInput()
                            }
                        }.padding(12).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger) }
                }.padding(20)
            }
            Divider()
            HStack { Text(store.text("Included in encrypted workspace backups", "包含在加密工作区备份中")).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()); Button(store.text("Save template", "保存模板")) { do { save(try value.validated(chinese: store.chinese)) } catch { self.error = error.localizedDescription } }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-template-save").disabled(!timeoutValid || value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.return, modifiers: .command) }.padding(20)
        }.frame(width: 720, height: 700).background(Palette.card).foregroundStyle(Palette.text)
            .onAppear { synchronize() }.onChange(of: value.command) { _, _ in synchronize() }
    }
    private func synchronize() { do { value.parameters = try SnippetParameters.synchronized(value.parameters, body: value.command, chinese: store.chinese); error = "" } catch { self.error = error.localizedDescription } }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted); content() } }
}
