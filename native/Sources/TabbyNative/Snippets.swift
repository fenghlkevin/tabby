import Foundation
import AppKit
import SwiftUI
import SwiftTerm

struct CommandSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var group = ""
    var body = ""
    var notes = ""
    var parameters: [SnippetParameter] = []

    enum CodingKeys: String, CodingKey { case id, name, group, body, notes, parameters }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        group = try values.decodeIfPresent(String.self, forKey: .group) ?? ""
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        parameters = try values.decodeIfPresent([SnippetParameter].self, forKey: .parameters) ?? []
    }
}

enum SnippetAction { case insert, run }

enum SnippetInput {
    static func normalized(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }
    static func validate(_ body: String, chinese: Bool) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure.message(chinese ? "请输入命令内容" : "Enter a command")
        }
        guard body.utf8.count <= 256 * 1024 else {
            throw AppFailure.message(chinese ? "代码片段不能超过 256 KB" : "A snippet must be smaller than 256 KB")
        }
        guard !body.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127 }) else {
            throw AppFailure.message(chinese ? "命令内容不能包含隐藏的终端控制字符" : "Commands cannot contain hidden terminal control characters")
        }
    }
    static func bytes(_ body: String, action: SnippetAction, bracketedPaste: Bool, chinese: Bool = false) throws -> [UInt8] {
        try validate(body, chinese: chinese)
        let text = normalized(body)
        if action == .insert, !bracketedPaste, text.contains("\n") || text.contains("\t") {
            throw AppFailure.message(chinese ? "此终端尚未启用 Bracketed Paste，无法安全插入多行或制表符。请复制后检查，或选择运行。" : "This terminal has not enabled bracketed paste. Copy and review multiline or tabbed text, or choose Run.")
        }
        var bytes: [UInt8]
        if bracketedPaste { bytes = Array("\u{1b}[200~".utf8) + Array(text.utf8) + Array("\u{1b}[201~".utf8) }
        else { bytes = Array(text.replacingOccurrences(of: "\n", with: "\r").utf8) }
        if action == .run { bytes.append(13) }
        return bytes
    }
}

@MainActor extension AppStore {
    var snippetGroups: [String] {
        Array(Set(workspace.snippets.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func commitSnippets(_ values: [CommandSnippet]) throws {
        let previous = workspace.snippets
        workspace.snippets = values
        guard save() else {
            workspace.snippets = previous
            throw AppFailure.message(error ?? text("Could not save snippets", "无法保存代码片段"))
        }
    }
    func saveSnippet(_ original: CommandSnippet) throws {
        var value = original
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.group = value.group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw AppFailure.message(text("Enter a snippet name", "请输入片段名称")) }
        try SnippetInput.validate(value.body, chinese: chinese)
        value.body = value.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value.parameters = try SnippetParameters.synchronized(value.parameters, body: value.body, chinese: chinese)
        var values = workspace.snippets
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
        try commitSnippets(values)
    }
    @discardableResult func duplicateSnippet(_ original: CommandSnippet) throws -> CommandSnippet {
        var value = original; value.id = UUID(); value.name += text(" copy", " 副本")
        try saveSnippet(value)
        return value
    }
    func removeSnippet(_ id: UUID) throws { try commitSnippets(workspace.snippets.filter { $0.id != id }) }
    func renameSnippetGroup(_ group: String, to name: String) throws {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw AppFailure.message(text("Enter a group name", "请输入分组名称")) }
        guard target == group || !snippetGroups.contains(target) else { throw AppFailure.message(text("A group with this name already exists", "已有同名分组")) }
        try commitSnippets(workspace.snippets.map { original in var value = original; if value.group == group { value.group = target }; return value })
    }
    func ungroupSnippets(_ group: String) throws {
        try commitSnippets(workspace.snippets.map { original in var value = original; if value.group == group { value.group = "" }; return value })
    }
    func sendSnippet(_ snippet: CommandSnippet, to targetIDs: Set<UUID>, action: SnippetAction, parameterValues: [String: String] = [:]) throws {
        let body = try SnippetParameters.expanded(snippet, values: parameterValues, chinese: chinese)
        guard !targetIDs.isEmpty else { throw AppFailure.message(text("Choose a connected terminal", "请选择已连接终端")) }
        let targets = sessions.filter { targetIDs.contains($0.id) }
        guard targets.count == targetIDs.count, targets.allSatisfy({ $0.connected && $0.terminal != nil }) else {
            throw AppFailure.message(text("A selected terminal has disconnected. Choose connected terminals again.", "所选终端已断开，请重新选择已连接终端。"))
        }
        // Prepare every target before sending anything, so a failed insertion cannot reach only some sessions.
        let deliveries = try targets.map { session -> (TerminalSession, [UInt8]) in
            let mode = session.terminal!.terminalStateSnapshot().bracketedPasteMode
            return (session, try SnippetInput.bytes(body, action: action, bracketedPaste: mode, chinese: chinese))
        }
        for (session, bytes) in deliveries { session.terminal?.send(data: bytes[...]) }
        if targets.count == 1, let session = targets.first {
            activeSession = session.id; showTerminalSection()
            if let terminal = session.terminal { terminal.window?.makeFirstResponder(terminal) }
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var newestFirst = false
    @State private var group: String?
    @State private var editing: CommandSnippet?
    @State private var sending: CommandSnippet?
    @State private var renaming: String?
    @State private var newGroupName = ""
    var matching: [CommandSnippet] {
        let values = store.workspace.snippets.filter { value in
            (group == nil || value.group == group) && (search.isEmpty || "\(value.name) \(value.group) \(value.notes) \(value.body)".localizedCaseInsensitiveContains(search))
        }
        return newestFirst ? Array(values.reversed()) : values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var visible: [CommandSnippet] { group == nil && search.isEmpty ? matching.filter { $0.group.isEmpty } : matching }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                VaultSearchField(placeholder: store.text("Search snippets or groups", "搜索片段或分组"), text: $search)
                HStack {
                    Button { var value = CommandSnippet(); value.group = group ?? ""; editing = value } label: { Label(store.text("NEW SNIPPET", "新建片段"), systemImage: "plus") }.buttonStyle(ChromeButtonStyle())
                    Spacer()
                    AppActionMenu {
                        Button(store.text("Name", "按名称排序")) { newestFirst = false }
                        Button(store.text("Newest first", "最新添加优先")) { newestFirst = true }
                    } label: { Label(store.text("Sort", "排序"), systemImage: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 65)
                }
            }.padding(12).background(Palette.sidebar)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if group != nil { Button { group = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(IconButtonStyle()) }
                        PaneHeading(title: group ?? store.text("Snippets", "代码片段"))
                        Text("\(matching.count)").font(.caption).foregroundStyle(Palette.muted)
                        Spacer()
                    }
                    if group == nil && search.isEmpty {
                        ForEach(store.snippetGroups, id: \.self) { name in
                            Button { group = name } label: {
                                HStack(spacing: 12) {
                                    IconTile(symbol: "folder.fill", color: Palette.blue)
                                    Text(name).font(.system(size: 14, weight: .medium)); Spacer()
                                    Text("\(store.workspace.snippets.filter { $0.group == name }.count)").foregroundStyle(Palette.muted)
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                                }.padding(14).contentShape(Rectangle()).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(AxonSurfaceButtonStyle()).appContextMenu {
                                Button(store.text("Rename group", "重命名分组")) { newGroupName = name; renaming = name }
                                Button(store.text("Remove group, keep snippets", "取消分组，保留片段")) { perform { try store.ungroupSnippets(name) } }
                            }
                        }
                        if !visible.isEmpty && !store.snippetGroups.isEmpty { Text(store.text("Ungrouped", "未分组")).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).padding(.top, 10) }
                    }
                    ForEach(visible) { value in snippetRow(value) }
                    if matching.isEmpty {
                        VStack(spacing: 14) {
                            IconTile(symbol: "curlybraces", color: Palette.blue, size: 56)
                            Text(search.isEmpty ? store.text("Save commands you use often", "保存常用命令") : store.text("No matching snippets", "没有匹配的代码片段")).font(.system(size: 16, weight: .medium))
                            Text(store.text("Insert a command for review, or run it in selected connected terminals.", "插入终端后检查，或选择已连接终端运行。"))
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity).padding(35)
                    }
                }.padding(22)
            }
        }.foregroundStyle(Palette.text)
            .sheet(item: $editing) { SnippetEditor(value: $0).environmentObject(store) }
            .sheet(item: $sending) { SnippetSendSheet(snippet: $0).environmentObject(store) }
            .appAlert(store.text("Rename group", "重命名分组"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { renaming = nil }
                AppAlertButton(store.text("Save", "保存")) { if let name = renaming { perform { try store.renameSnippetGroup(name, to: newGroupName) } }; renaming = nil }
            } message: {
                TextField(store.text("Name", "名称"), text: $newGroupName).appInput()
            }
    }
    func snippetRow(_ value: CommandSnippet) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: "curlybraces", color: Palette.blue)
            Button { editing = value } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(value.name).font(.system(size: 14, weight: .medium)); if !value.group.isEmpty { Text(value.group).font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                    Text(value.body).font(.system(size: 12, design: .monospaced)).lineLimit(2).foregroundStyle(Palette.muted)
                    if !value.notes.isEmpty { Text(value.notes).font(.system(size: 11)).lineLimit(1).foregroundStyle(Palette.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(AxonSurfaceButtonStyle())
            Button(store.text("Use", "使用")) { sending = value }.buttonStyle(ChromeButtonStyle())
            AppActionMenu {
                Button { editing = value } label: { Label(store.text("Edit", "编辑"), systemImage: "square.and.pencil") }
                Button { copySnippet(value) } label: { Label(store.text("Copy command", "复制命令"), systemImage: "doc.on.doc") }
                Button { perform { _ = try store.duplicateSnippet(value) } } label: { Label(store.text("Duplicate", "复制片段"), systemImage: "plus.square.on.square") }
                Divider()
                Button(role: .destructive) { deleteSnippet(value) } label: { Label(store.text("Delete", "删除"), systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 34, height: 34)
                .tint(Palette.text).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(store.text("Snippet actions", "片段操作"))
        }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .appContextMenu {
                Button(store.text("Use in terminal", "在终端中使用")) { sending = value }
                Button { editing = value } label: { Label(store.text("Edit", "编辑"), systemImage: "square.and.pencil") }
                Button { copySnippet(value) } label: { Label(store.text("Copy command", "复制命令"), systemImage: "doc.on.doc") }
                Button { perform { _ = try store.duplicateSnippet(value) } } label: { Label(store.text("Duplicate", "复制片段"), systemImage: "plus.square.on.square") }
                Divider()
                Button(role: .destructive) { deleteSnippet(value) } label: { Label(store.text("Delete", "删除"), systemImage: "trash") }
            }
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { store.error = error.localizedDescription } }
    func deleteSnippet(_ value: CommandSnippet) { store.confirmSnippetDeletion(value) }

}

@MainActor extension AppStore {
    func confirmSnippetDeletion(_ value: CommandSnippet) {
        let alert = AppModalAlert(); alert.destructive = true
        alert.messageText = text("Delete snippet?", "删除代码片段？"); alert.informativeText = value.name
        alert.addButton(withTitle: text("Delete", "删除")); alert.addButton(withTitle: text("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            do { try removeSnippet(value.id) } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor private func copySnippet(_ value: CommandSnippet) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value.body, forType: .string)
}

struct SnippetEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var value: CommandSnippet
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text("Snippet", "代码片段")).font(.system(size: 19, weight: .semibold))
            TextField(store.text("Name", "名称"), text: $value.name).appInput()
            HStack {
                TextField(store.text("Group (optional)", "分组（可选）"), text: $value.group).appInput()
                AppActionMenu { Button(store.text("Ungrouped", "未分组")) { value.group = "" }; ForEach(store.snippetGroups, id: \.self) { name in Button(name) { value.group = name } } } label: { Image(systemName: "folder") }.menuStyle(.borderlessButton).frame(width: 25)
            }
            TextField(store.text("Description (optional)", "说明（可选）"), text: $value.notes).appInput()
            Text(store.text("Command", "命令内容")).font(.system(size: 12, weight: .medium))
            SnippetTextEditor(text: $value.body).frame(height: value.parameters.isEmpty ? 220 : 150).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
            Text(store.text("Add {{name}} outside quotes for a parameter. Each value becomes one quoted shell argument; do not use parameters in heredocs.", "在引号外添加 {{参数名}}。每个值会转换为一个安全引用的 Shell 参数；请勿在 heredoc 中使用参数。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if !value.parameters.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($value.parameters) { $parameter in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("{{\(parameter.name)}}").font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Spacer()
                                    AxonChoiceField(selection: $parameter.type, choices: SnippetParameterType.allCases.map { ($0, $0.title(chinese: store.chinese)) }, placeholder: store.text("Type", "类型"), symbol: "textformat", identifier: "axon-snippet-parameter-type").frame(width: 130)
                                    Toggle(store.text("Required", "必填"), isOn: $parameter.required).toggleStyle(AxonCheckboxStyle()).font(.system(size: 11))
                                }
                                TextField(store.text("Default value (optional)", "默认值（可选）"), text: $parameter.defaultValue).appInput()
                            }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 200)
            }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle())
                Spacer()
                Button(store.text("Save", "保存")) { do { try store.saveSnippet(value); dismiss() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(ChromeButtonStyle(prominent: true)).disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540).foregroundStyle(Palette.text).background(Palette.sidebar)
            .onAppear { synchronizeParameters() }
            .onChange(of: value.body) { _, _ in synchronizeParameters() }
    }
    private func synchronizeParameters() {
        do { value.parameters = try SnippetParameters.synchronized(value.parameters, body: value.body, chinese: store.chinese); error = "" }
        catch { self.error = error.localizedDescription }
    }
}

struct SnippetSendSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let snippet: CommandSnippet
    var preferredSessionID: UUID? = nil
    @State private var selected = Set<UUID>()
    @State private var error = ""
    @State private var confirmingRun = false
    @State private var parameterValues: [String: String] = [:]
    var connected: [TerminalSession] { store.sessions.filter { $0.connected && $0.terminal != nil } }
    var targets: [TerminalSession] { connected.filter { selected.contains($0.id) } }
    var parameters: [SnippetParameter] { (try? SnippetParameters.synchronized(snippet.parameters, body: snippet.body)) ?? [] }
    var expansion: Result<String, Error> { Result { try SnippetParameters.expanded(snippet, values: parameterValues, chinese: store.chinese) } }
    var expandedCommand: String? { try? expansion.get() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snippet.name).font(.system(size: 19, weight: .semibold))
            if !parameters.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(parameters) { parameter in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(parameter.name + (parameter.required ? " *" : "")).font(.system(size: 12, weight: .medium))
                                    Text(parameter.type.title(chinese: store.chinese)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }.frame(width: 115, alignment: .leading)
                                TextField(parameter.defaultValue, text: Binding(get: { parameterValues[parameter.name] ?? parameter.defaultValue }, set: { parameterValues[parameter.name] = $0; error = "" })).appInput()
                            }
                        }
                    }
                }.frame(maxHeight: 160)
            }
            Text(store.text("Command preview", "展开后的命令预览")).font(.system(size: 12, weight: .medium))
            ScrollView { Text(expandedCommand ?? snippet.body).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .frame(height: 145).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            if case .failure(let validationError) = expansion { Text(validationError.localizedDescription).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Text(store.text("Connected terminals", "已连接终端")).font(.system(size: 12, weight: .medium)); Spacer(); Button(store.text("Select all", "全选")) { selected = Set(connected.map(\.id)) }.buttonStyle(ChromeButtonStyle()).foregroundStyle(Palette.accent).disabled(connected.isEmpty) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(connected) { session in
                        Button { if !selected.insert(session.id).inserted { selected.remove(session.id) } } label: {
                            HStack(spacing: 10) {
                                AxonSelectionMark(selected: selected.contains(session.id))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayTitle).lineLimit(1).truncationMode(.middle)
                                    Text(session.host.map { "\($0.address):\($0.port)" } ?? store.text("Local terminal", "本地终端")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }; Spacer()
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(selected.contains(session.id) ? Palette.selected : Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(AxonSurfaceButtonStyle())
                    }
                    if connected.isEmpty { Text(store.text("Open a local terminal or connect to a host first.", "请先打开本地终端或连接主机。 ")).foregroundStyle(Palette.muted).padding(12) }
                }
            }.frame(height: 140)
            Text(store.text("Insert leaves the command for review. Run sends it and presses Enter in the selected terminals.", "插入后可检查命令；运行会将命令发送到所选终端并按回车。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle())
                Button(store.text("Copy", "复制")) { if let command = expandedCommand { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } }.buttonStyle(ChromeButtonStyle()).disabled(expandedCommand == nil)
                Spacer()
                Button(store.text("Insert", "插入")) { send(.insert) }.buttonStyle(ChromeButtonStyle()).disabled(selected.isEmpty || expandedCommand == nil)
                Button(store.text("Run", "运行")) { confirmingRun = true }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(selected.isEmpty || expandedCommand == nil)
            }
        }.padding(24).frame(width: 570).foregroundStyle(Palette.text).background(Palette.sidebar)
            .onAppear { if let id = preferredSessionID ?? store.activeSession, connected.contains(where: { $0.id == id }) { selected = [id] } }
            .appAlert(store.text("Run snippet?", "运行代码片段？"), isPresented: $confirmingRun) {
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
                AppAlertButton(store.text("Run", "运行")) { send(.run) }
            } message: {
                Text(store.text("Run \"\(snippet.name)\" in \(targets.count) terminal(s):", "在 \(targets.count) 个终端运行「\(snippet.name)」：") + "\n" + targets.map { session in session.displayTitle + (session.host.map { " · \($0.address):\($0.port)" } ?? "") }.joined(separator: "\n"))
            }
    }
    func send(_ action: SnippetAction) {
        do { try store.sendSnippet(snippet, to: selected, action: action, parameterValues: parameterValues); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct SnippetTerminalPanel: View {
    @EnvironmentObject var store: AppStore
    var sessionID: UUID? = nil
    var scrollsInternally = true
    @State private var search = ""
    @State private var sending: CommandSnippet?
    @State private var editing: CommandSnippet?
    @State private var hoveredSnippet: UUID?
    var filtered: [CommandSnippet] {
        store.workspace.snippets.filter { search.isEmpty || "\($0.name) \($0.group) \($0.body)".localizedCaseInsensitiveContains(search) }
            .sorted { $0.group == $1.group ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.group.localizedStandardCompare($1.group) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(store.text("Snippets", "代码片段")).font(.system(size: 15, weight: .semibold))
                Text("\(filtered.count)")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(TerminalChrome.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(TerminalChrome.card).clipShape(Capsule())
                Spacer(minLength: 4)
                Button { editing = CommandSnippet() } label: {
                    Label(store.text("New", "新建"), systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 28)
                        .foregroundStyle(TerminalChrome.accent)
                        .background(TerminalChrome.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(TerminalChrome.accent.opacity(0.2), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(AxonSurfaceButtonStyle()).help(store.text("New snippet", "新建片段")).accessibilityLabel(store.text("New snippet", "新建片段"))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(TerminalChrome.muted)
                TextField(store.text("Search snippets", "搜索代码片段"), text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }.padding(.horizontal, 11).frame(height: 36)
                .background(TerminalChrome.field).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(TerminalChrome.border.opacity(0.65), lineWidth: 1))
            if scrollsInternally { ScrollView { snippetList } }
            else { snippetList }
        }.foregroundStyle(TerminalChrome.text).colorScheme(.dark)
            .sheet(item: $sending) { SnippetSendSheet(snippet: $0, preferredSessionID: sessionID).environmentObject(store).colorScheme(.light) }
            .sheet(item: $editing) { SnippetEditor(value: $0).environmentObject(store).colorScheme(.light) }
    }
    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(filtered) { value in
                Button { sending = value } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 9) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(TerminalChrome.accent)
                                .frame(width: 28, height: 28)
                                .background(TerminalChrome.accent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(value.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                HStack(spacing: 5) {
                                    if !value.group.isEmpty {
                                        Text(value.group).lineLimit(1)
                                        Text("·")
                                    }
                                    Text(store.text("\(lineCount(value)) " + (lineCount(value) == 1 ? "line" : "lines"), "\(lineCount(value)) 行")).fixedSize()
                                }.font(.system(size: 10)).foregroundStyle(TerminalChrome.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(TerminalChrome.muted.opacity(0.7))
                        }
                        Text(value.body).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TerminalChrome.text.opacity(0.85)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .background(TerminalChrome.field.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                        .background(TerminalChrome.card).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(hoveredSnippet == value.id ? TerminalChrome.accent.opacity(0.55) : TerminalChrome.border.opacity(0.55), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(AxonSurfaceButtonStyle())
                    .onHover { hovering in hoveredSnippet = hovering ? value.id : (hoveredSnippet == value.id ? nil : hoveredSnippet) }
                    .animation(.easeOut(duration: 0.12), value: hoveredSnippet == value.id)
                    .appContextMenu {
                    Button(store.text("Use", "使用")) { sending = value }
                    Button(store.text("Copy", "复制")) { copySnippet(value) }
                    Button { editing = value } label: { Label(store.text("Edit", "编辑"), systemImage: "square.and.pencil") }
                }
            }
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: search.isEmpty ? "curlybraces.square" : "magnifyingglass")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(TerminalChrome.accent.opacity(0.8))
                    Text(search.isEmpty ? store.text("Save your frequent commands", "保存常用命令") : store.text("No matching snippets", "没有匹配的代码片段"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(TerminalChrome.text)
                    Text(search.isEmpty ? store.text("Choose New to keep commands close to your terminal.", "点击新建，将常用命令保存在终端旁。") : store.text("Try another name, group, or command.", "试试其他名称、分组或命令。"))
                        .font(.system(size: 11)).foregroundStyle(TerminalChrome.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 28)
                    .background(TerminalChrome.field.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(TerminalChrome.border.opacity(0.45), lineWidth: 1))
            }
        }
    }
    private func lineCount(_ value: CommandSnippet) -> Int {
        value.body.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

struct SnippetTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
        let editor = scroll.documentView as! NSTextView; editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = NSColor(hex: "#171A2A"); editor.insertionPointColor = NSColor(hex: "#171A2A"); editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 10, height: 10); editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator; editor.string = text
        editor.setAccessibilityLabel("Command / 命令内容")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? NSTextView {
            editor.isEditable = enabled
            if editor.string != text { editor.string = text }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetTextEditor
        init(_ parent: SnippetTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
