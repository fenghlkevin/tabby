import SwiftUI
import AppKit

struct PortForwardsView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: PortForwardRule?
    @State private var search = ""
    var rules: [PortForwardRule] { store.workspace.forwards.filter { search.isEmpty || "\($0.name) \($0.bindHost) \($0.targetHost)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                VaultSearchField(placeholder: store.text("Search forwarding rules", "搜索转发规则"), text: $search)
                HStack {
                    HStack(spacing: 0) {
                        Button { newRule("local") } label: { Label(store.text("NEW RULE", "新建规则"), systemImage: "arrow.left.arrow.right") }.buttonStyle(ChromeButtonStyle())
                        Menu {
                            Button(store.text("Local forwarding", "本地转发")) { newRule("local") }
                            Button(store.text("Remote forwarding", "远程转发")) { newRule("remote") }
                        } label: { Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Palette.text).fixedSize().padding(.trailing, 6).accessibilityLabel(store.text("New forwarding menu", "新建转发菜单"))
                    }.background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }.padding(12).background(Palette.sidebar)
            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack { PaneHeading(title: store.text("Port forwarding", "端口转发")); Text(String(rules.count)).font(.caption).foregroundStyle(Palette.muted); Spacer() }
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { IconTile(symbol: "arrow.left.arrow.right", color: Palette.blue); Text(rule.name).font(.headline); Spacer(); Text(store.forwardStatus[rule.id] ?? store.text("Stopped", "已停止")).foregroundStyle(Palette.muted) }
                            Text((rule.kind == "local" ? store.text("Local", "本地") : store.text("Remote", "远程")) + "  \(rule.bindHost):\(rule.bindPort) → \(rule.targetHost):\(rule.targetPort)").font(.system(.body, design: .monospaced))
                            HStack {
                                Text(store.workspace.hosts.first(where: { $0.id == rule.hostID })?.name ?? store.text("Host unavailable", "主机不存在")).foregroundStyle(Palette.muted)
                                Spacer()
                                if store.forwardTasks[rule.id] == nil {
                                    Button(store.text("Start", "启动")) { store.startForward(rule) }
                                    Button(store.text("Edit", "编辑")) { editing = rule }
                                    Button(store.text("Remove", "移除")) { store.workspace.forwards.removeAll { $0.id == rule.id }; store.save() }
                                } else { Button(store.text("Stop", "停止")) { store.stopForward(rule.id) } }
                            }.buttonStyle(ChromeButtonStyle())
                        }.padding(18).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if store.workspace.forwards.isEmpty { Text(store.text("Create a rule and choose an SSH host. Rules stay stopped after restarting.", "新建规则并选择 SSH 主机；重启后规则保持停止，需手动启动。 ")).foregroundStyle(Palette.muted).padding(30) }
                }.padding(22)
            }
        }.sheet(item: $editing) { rule in ForwardRuleEditor(rule: rule).environmentObject(store) }
    }
    func newRule(_ kind: String) { var rule = PortForwardRule(); rule.kind = kind; editing = rule }
}

struct ForwardRuleEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var rule: PortForwardRule
    @State private var error = ""
    @State private var bindPortValid = true
    @State private var targetPortValid = true
    var validationMessage: String? {
        do { _ = try ConnectionValidation.forward(rule, workspace: store.workspace, chinese: store.chinese); return nil }
        catch { return error.localizedDescription }
    }
    var valid: Bool { bindPortValid && targetPortValid && validationMessage == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeading(title: store.text("TCP forwarding rule", "TCP 转发规则"))
            TextField(store.text("Name", "名称"), text: $rule.name).appInput()
            Picker(store.text("SSH host", "SSH 主机"), selection: $rule.hostID) { Text(store.text("Select host", "选择主机")).tag(Optional<UUID>.none); ForEach(store.workspace.hosts) { host in Text(host.name).tag(Optional(host.id)) } }
            Picker(store.text("Direction", "方向"), selection: $rule.kind) { Text(store.text("Local → remote", "本地 → 远程")).tag("local"); Text(store.text("Remote → local", "远程 → 本地")).tag("remote") }.pickerStyle(.segmented)
            Text(store.text("Listening address / port", "监听地址／端口")).foregroundStyle(Palette.muted)
            HStack { TextField("127.0.0.1", text: $rule.bindHost).appInput(); PortInput(value: $rule.bindPort, valid: $bindPortValid, placeholder: "8080", label: store.text("Listening port", "监听端口")).frame(width: 120) }
            Text(store.text("Destination address / port", "目标地址／端口")).foregroundStyle(Palette.muted)
            HStack { TextField("127.0.0.1", text: $rule.targetHost).appInput(); PortInput(value: $rule.targetPort, valid: $targetPortValid, placeholder: "80", label: store.text("Destination port", "目标端口")).frame(width: 120) }
            Text(store.text("For local forwarding, the destination is reached from the SSH server. For remote forwarding, it is reached from this Mac.", "本地转发的目标由 SSH 服务器访问；远程转发的目标由此 Mac 访问。 ")).font(.caption).foregroundStyle(Palette.muted)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red) }
            HStack { Button(store.text("Cancel", "取消")) { dismiss() }; Spacer(); Button(store.text("Save", "保存")) { guard valid else { return }; do { try store.saveForward(rule); dismiss() } catch { self.error = error.localizedDescription } }.disabled(!valid).keyboardShortcut(.defaultAction) }.buttonStyle(ChromeButtonStyle())
        }.padding(24).frame(width: 520).background(Palette.sidebar)
    }
}

struct LogsView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var confirmingClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                VaultSearchField(placeholder: store.text("Search logs", "搜索日志"), text: $search)
                HStack {
                    Button { export() } label: { Label(store.text("EXPORT", "导出"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(ChromeButtonStyle())
                    Spacer()
                    Button { confirmingClear = true } label: { Label(store.text("Clear logs", "清空日志"), systemImage: "trash") }
                        .buttonStyle(ChromeButtonStyle())
                        .disabled(store.workspace.logs.isEmpty)
                        .accessibilityIdentifier("axon-clear-logs")
                }
            }.padding(12).background(Palette.sidebar)
            HStack { PaneHeading(title: store.text("Logs", "日志"), subtitle: store.text("Last 500 connection and forwarding events.", "最近 500 条连接与转发事件。")); Spacer() }.padding(22)
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(store.workspace.logs.reversed().filter { search.isEmpty || "\($0.category) \($0.event) \($0.host)".localizedCaseInsensitiveContains(search) }) { log in
                    HStack(alignment: .top) { Image(systemName: log.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(log.failed ? .red : Palette.blue); Text(log.date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).frame(width: 160, alignment: .leading); Text(log.category).frame(width: 60); Text(log.host).frame(width: 180, alignment: .leading); Text(log.event); Spacer() }.padding(12).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
                }
                if store.workspace.logs.isEmpty { Text(store.text("Connection and forwarding events appear here.", "连接或启动转发后，事件会显示在这里。 ")).foregroundStyle(Palette.muted).padding(30).frame(maxWidth: .infinity) }
            }.padding(.horizontal, 22) }
        }
        .alert(store.text("Clear all logs?", "清空全部日志？"), isPresented: $confirmingClear) {
            Button(store.text("Cancel", "取消"), role: .cancel) {}
            Button(store.text("Clear all logs", "清空全部日志"), role: .destructive) { store.clearActivityLogs() }
        } message: {
            Text(store.text("All \(store.workspace.logs.count) saved events will be removed, including those hidden by search. This cannot be undone. New events will continue to appear here.", "将清空全部 \(store.workspace.logs.count) 条记录，包括搜索未显示的记录。此操作无法撤销，之后的新事件仍会继续记录。"))
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "tabby-connection-events.json"
        if panel.runModal() == .OK, let url = panel.url { do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(store.workspace.logs).write(to: url, options: .atomic) } catch { store.error = error.localizedDescription } }
    }
}
