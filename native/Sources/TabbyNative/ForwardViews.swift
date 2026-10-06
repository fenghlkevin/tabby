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
                        AppActionMenu {
                            Button(store.text("Local forwarding", "本地转发")) { newRule("local") }
                            Button(store.text("Remote forwarding", "远程转发")) { newRule("remote") }
                            Button(store.text("Dynamic SOCKS5 proxy", "动态 SOCKS5 代理")) { newRule("dynamic") }
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
                            Text(rule.isDynamic ? "SOCKS5  \(rule.listeningAddress)" : (rule.kind == "local" ? store.text("Local", "本地") : store.text("Remote", "远程")) + "  \(rule.listeningAddress) → \(rule.targetHost):\(rule.targetPort)").font(.system(.body, design: .monospaced))
                            if rule.isDynamic {
                                Text(store.text("TCP proxy · DNS resolved by the SSH server", "TCP 代理 · 域名由 SSH 服务器解析")).font(.caption).foregroundStyle(Palette.muted)
                            }
                            HStack {
                                Text(store.workspace.hosts.first(where: { $0.id == rule.hostID })?.name ?? store.text("Host unavailable", "主机不存在")).foregroundStyle(Palette.muted)
                                Spacer()
                                if rule.isDynamic {
                                    Button(store.text("Copy proxy URL", "复制代理 URL")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("socks5h://\(rule.listeningAddress)", forType: .string)
                                    }
                                }
                                if store.forwardTasks[rule.id] == nil {
                                    Button(store.text("Start", "启动")) { store.startForward(rule) }
                                    Button(store.text("Edit", "编辑")) { editing = rule }
                                    Button(store.text("Remove", "移除")) { do { try store.removeForward(rule.id) } catch { store.error = error.localizedDescription } }
                                } else { Button(store.text("Stop", "停止")) { store.stopForward(rule.id) } }
                            }.buttonStyle(ChromeButtonStyle())
                        }.padding(18).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if store.workspace.forwards.isEmpty { Text(store.text("Create a rule and choose an SSH host. Rules stay stopped after restarting.", "新建规则并选择 SSH 主机；重启后规则保持停止，需手动启动。 ")).foregroundStyle(Palette.muted).padding(30) }
                }.padding(22)
            }
        }.sheet(item: $editing) { rule in ForwardRuleEditor(rule: rule).environmentObject(store) }
    }
    func newRule(_ kind: String) { var rule = PortForwardRule(); rule.kind = kind; if rule.isDynamic { rule.bindPort = 1080 }; editing = rule }
}

struct ForwardRuleEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var rule: PortForwardRule
    @State private var error = ""
    @State private var nameEdited = false
    @State private var bindPortValid = true
    @State private var targetPortValid = true
    var validationMessage: String? {
        do { _ = try ConnectionValidation.forward(rule, workspace: store.workspace, chinese: store.chinese); return nil }
        catch { return error.localizedDescription }
    }
    var valid: Bool { bindPortValid && (rule.isDynamic || targetPortValid) && validationMessage == nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.left.arrow.right", color: Palette.blue, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.text("TCP forwarding rule", "TCP 转发规则")).font(.system(size: 16, weight: .semibold))
                    Text(store.text("Save the rule, then start it when needed", "保存规则后，按需手动启动")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }.padding(24).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("Name", "名称"), required: true)
                        TextField(store.text("Rule name", "规则名称"), text: $rule.name).appInput()
                            .onChange(of: rule.name) { _, _ in nameEdited = true }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("SSH host", "SSH 主机"), required: true)
                        AxonChoiceField(selection: $rule.hostID,
                            choices: [(Optional<UUID>.none, store.text("Select host", "选择主机"))] + store.workspace.hosts.map { (Optional($0.id), $0.name.isEmpty ? $0.address : $0.name) },
                            placeholder: store.text("Select host", "选择主机"), symbol: "server.rack", identifier: "axon-forward-host")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("Type", "类型"))
                        AxonChoiceField(selection: $rule.kind,
                            choices: [("local", store.text("Local → remote", "本地 → 远程")), ("remote", store.text("Remote → local", "远程 → 本地")), ("dynamic", "SOCKS5")],
                            placeholder: store.text("Choose type", "选择类型"), symbol: "arrow.left.arrow.right", identifier: "axon-forward-type")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("Listening address / port", "监听地址／端口"), required: true)
                        HStack(spacing: 12) {
                            TextField("127.0.0.1", text: $rule.bindHost).appInput()
                            PortInput(value: $rule.bindPort, valid: $bindPortValid, placeholder: rule.isDynamic ? "1080" : "8080", label: store.text("Listening port", "监听端口")).frame(width: 100)
                        }
                    }
                    if !rule.isDynamic {
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel(store.text("Destination address / port", "目标地址／端口"), required: true)
                            HStack(spacing: 12) {
                                TextField("127.0.0.1", text: $rule.targetHost).appInput()
                                PortInput(value: $rule.targetPort, valid: $targetPortValid, placeholder: "80", label: store.text("Destination port", "目标端口")).frame(width: 100)
                            }
                        }
                    }
                    Label(rule.isDynamic
                        ? store.text("Use this SOCKS5 address with remote DNS. TCP CONNECT; no authentication. Listen on 127.0.0.1 or ::1 only.", "填写此 SOCKS5 地址并开启远程 DNS。支持 TCP CONNECT，无需认证；仅监听 127.0.0.1 或 ::1。")
                        : (rule.kind == "remote"
                            ? store.text("The SSH server listens; this Mac connects to the destination.", "SSH 服务器监听端口，由此 Mac 访问目标地址。")
                            : store.text("This Mac listens; the SSH server connects to the destination.", "此 Mac 监听端口，由 SSH 服务器访问目标地址。")), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    if !error.isEmpty {
                        validationLabel(error)
                    } else if (nameEdited || !rule.name.isEmpty), let validationMessage {
                        validationLabel(validationMessage)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.text("Save", "保存")) {
                    guard valid else { return }
                    do { try store.saveForward(rule); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!valid).keyboardShortcut(.defaultAction)
            }.padding(24).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 540, height: 620).background(Palette.sidebar).foregroundStyle(Palette.text)
            .onChange(of: rule.kind) { old, new in
                if new == "dynamic", old != "dynamic", rule.bindPort == 8080 { rule.bindPort = 1080 }
            }
    }
    private func fieldLabel(_ title: String, required: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if required { Text(store.text("Required", "必填")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }
    }
    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.danger)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("axon-forward-validation")
    }
}

struct LogsView: View {
    @EnvironmentObject var store: AppStore
    var history: CommandHistoryStore = .shared
    var body: some View { LogsContentView(logs: store.sessionLogs, history: history) }
}
private struct LogsContentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var logs: SessionLogStore
    let history: CommandHistoryStore
    @State private var selected = "operations"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([("operations", store.text("Operation history", "操作历史")), ("transcripts", store.text("Session transcripts", "会话输出")), ("connections", store.text("Connection events", "连接事件"))], id: \.0) { item in
                    Button(item.1) { selected = item.0 }.buttonStyle(ChromeButtonStyle(prominent: selected == item.0))
                }
                Spacer()
            }.padding(16).background(Palette.sidebar)
            if selected == "operations" { OperationHistoryView(history: history) }
            else if selected == "transcripts" { SessionLogsView(logs: logs) }
            else { ConnectionEventsView() }

        }.onAppear { if logs.selectedID != nil { selected = "transcripts" } }
            .onChange(of: logs.navigationRequest) { _, _ in selected = "transcripts" }
    }
}

struct ConnectionEventsView: View {
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
        .appAlert(store.text("Clear all logs?", "清空全部日志？"), isPresented: $confirmingClear) {
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
            AppAlertButton(store.text("Clear all logs", "清空全部日志"), role: .destructive) { store.clearActivityLogs() }
        } message: {
            Text(store.text("All \(store.workspace.logs.count) saved events will be removed, including those hidden by search. This cannot be undone. New events will continue to appear here.", "将清空全部 \(store.workspace.logs.count) 条记录，包括搜索未显示的记录。此操作无法撤销，之后的新事件仍会继续记录。"))
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "tabby-connection-events.json"
        if panel.runModal() == .OK, let url = panel.url { do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(store.workspace.logs).write(to: url, options: .atomic) } catch { store.error = error.localizedDescription } }
    }
}
