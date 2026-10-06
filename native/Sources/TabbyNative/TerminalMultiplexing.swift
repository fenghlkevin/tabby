import Foundation
import SwiftUI
import AppKit
import SwiftTerm

struct TerminalPaneLayout {
    static func frames(count: Int, size: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count == 1 ? 1 : 2
        let rows = count <= 2 ? 1 : 2
        let width = max(0, (size.width - CGFloat(columns - 1) * 6) / CGFloat(columns))
        let height = max(0, (size.height - CGFloat(rows - 1) * 6) / CGFloat(rows))
        return (0..<min(4, count)).map { CGRect(x: CGFloat($0 % columns) * (width + 6), y: CGFloat($0 / columns) * (height + 6), width: width, height: height) }
    }
}
@MainActor extension AppStore {
    func paneIDs(containing id: UUID) -> [UUID] {
        if let group = terminalPaneGroups.values.first(where: { $0.contains(id) }) {
            return group.filter { key in sessions.contains { $0.id == key } }
        }
        if let peer = splitPartners[id], sessions.contains(where: { $0.id == peer }) {
            return sessions.filter { $0.id == id || $0.id == peer }.map(\.id)
        }
        return sessions.contains(where: { $0.id == id }) ? [id] : []
    }
    func samePaneGroup(_ a: UUID?, _ b: UUID) -> Bool { a.map { paneIDs(containing: $0).contains(b) } ?? false }
    var visiblePaneIDs: [UUID] { activeSession.map(paneIDs) ?? [] }
    func dissolvePane(_ id: UUID) {
        let ids = paneIDs(containing: id)
        for key in terminalPaneGroups.keys.filter({ terminalPaneGroups[$0]?.contains(id) == true }) {
            let remaining = ids.filter { $0 != id }
            terminalPaneGroups[key] = remaining.count > 1 ? remaining : nil
        }
        splitPartners = splitPartners.filter { $0.key != id && $0.value != id }
        for group in terminalPaneGroups.values where group.count == 2 { splitPartners[group[0]] = group[1]; splitPartners[group[1]] = group[0] }
        if ids.count == 2, let remaining = ids.first(where: { $0 != id }) {
            sessions.first { $0.id == remaining }?.setFontSize(nil)
        }
        synchronizedTargets.remove(id); synchronizationEnabled = false
    }
    var synchronizationReady: Bool {
        guard synchronizationEnabled, (section == "terminal" || section == "scene" && currentScene?.mode == "terminal"), synchronizedTargets.count >= 2,
              let activeSession, synchronizedTargets.contains(activeSession), synchronizedTargets.isSubset(of: Set(visiblePaneIDs)) else { return false }
        return synchronizedTargets.allSatisfy { id in sessions.contains { $0.id == id && $0.connected && !$0.commandHistoryBootstrapScreen } }
    }
    func dispatchUserInput(from id: UUID, bytes: [UInt8]) {
        // Replies produced by terminal parsing use writeInput directly.
        let ids = synchronizationReady && synchronizedTargets.contains(id) ? visiblePaneIDs.filter { synchronizedTargets.contains($0) } : [id]
        for key in ids { sessions.first { $0.id == key }?.writeInput(bytes) }
    }
    func sendComposed(_ command: String, targets: Set<UUID>, run: Bool) throws {
        guard !targets.isEmpty, targets.isSubset(of: Set(visiblePaneIDs)), targets.allSatisfy({ id in sessions.contains { $0.id == id && $0.connected } }) else {
            throw AppFailure.message(text("Choose connected terminals from this pane group", "请选择当前分屏组中已连接的终端"))
        }
        var payloads: [(TerminalSession, [UInt8])] = []
        for id in visiblePaneIDs where targets.contains(id) {
            guard let session = sessions.first(where: { $0.id == id }), let terminal = session.terminal else { throw AppFailure.message(text("Terminal unavailable", "终端不可用")) }
            let bytes = try SnippetInput.bytes(command, action: run ? .run : .insert, bracketedPaste: terminal.terminalStateSnapshot().bracketedPasteMode, chinese: chinese)
            payloads.append((session, bytes))
        }
        // Validate every receiver before any input is sent. No recursive broadcast.
        for (session, bytes) in payloads { session.writeInput(bytes) }
    }
}

struct TerminalGroupControls: View {
    @EnvironmentObject var store: AppStore
    @State private var showing = false
    private var sessions: [TerminalSession] { store.visiblePaneIDs.compactMap { key in store.sessions.first { $0.id == key } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(store.text("Pane group", "分屏与同步")).font(.system(size: 14, weight: .semibold)); Spacer(); Text("\(sessions.count) / 4").foregroundStyle(TerminalChrome.muted) }
            HStack(spacing: 8) {
                Button(store.text("Add pane", "增加分屏")) { store.split() }.buttonStyle(ChromeButtonStyle()).disabled(sessions.count >= 4)
                Button(store.text("Separate", "独立标签")) { if let id = store.activeSession { store.separateSession(id) } }.buttonStyle(ChromeButtonStyle()).disabled(sessions.count < 2)
            }
            Button { showing = true } label: { Label(store.text("Choose receivers & compose", "选择接收终端与编写命令"), systemImage: "rectangle.and.pencil.and.ellipsis") }.buttonStyle(ChromeButtonStyle()).disabled(sessions.count < 2)
            HStack(spacing: 6) {
                Image(systemName: store.synchronizationReady ? "antenna.radiowaves.left.and.right" : "pause.circle")
                Text(store.synchronizationReady ? store.text("Live input → \(store.synchronizedTargets.count) terminals", "实时输入 → \(store.synchronizedTargets.count) 个终端") : store.text("Live input is off or paused", "实时同步已关闭或暂停"))
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(store.synchronizationReady ? TerminalChrome.accent : TerminalChrome.muted)
            if store.synchronizationEnabled { Button(store.text("Stop synchronization", "停止同步输入")) { store.synchronizationEnabled = false }.buttonStyle(ChromeButtonStyle()) }
        }.sheet(isPresented: $showing) { TerminalComposeSheet().environmentObject(store).colorScheme(.light) }
    }
}

struct TerminalComposeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var targets = Set<UUID>()
    @State private var command = ""
    @State private var live = false
    @State private var error = ""
    @State private var confirming = false
    private var sessions: [TerminalSession] { store.visiblePaneIDs.compactMap { key in store.sessions.first { $0.id == key } } }
    private var canSend: Bool { !targets.isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targets.allSatisfy { id in sessions.contains { $0.id == id && $0.connected } } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { IconTile(symbol: "rectangle.split.2x2", size: 40); PaneHeading(title: store.text("Synchronized input", "同步输入"), subtitle: store.text("Select exactly which terminals receive your input", "明确选择接收输入的终端")); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text(store.text("Receivers", "接收终端")).fontWeight(.semibold); Spacer(); Text(store.text("\(targets.count) selected", "已选 \(targets.count) 个")).foregroundStyle(Palette.muted) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(sessions) { session in
                        Button { if targets.contains(session.id) { targets.remove(session.id) } else { targets.insert(session.id) } } label: {
                            HStack(spacing: 10) {
                                AxonSelectionMark(selected: targets.contains(session.id))
                                VStack(alignment: .leading, spacing: 5) { Text(session.displayTitle).fontWeight(.medium).lineLimit(1); Text(session.host.map { "\(session.authenticatedUsername ?? $0.username)@\($0.address):\($0.port)" } ?? store.text("Local shell", "本地 Shell")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                Spacer(); Text(session.connected ? store.text("Connected", "已连接") : store.text("Disconnected", "未连接")).foregroundStyle(session.connected ? Palette.accent : Palette.danger)
                            }.padding(12).background(targets.contains(session.id) ? Palette.selected : Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.buttonStyle(AxonSurfaceButtonStyle()).disabled(!session.connected).accessibilityIdentifier("axon-sync-target-" + session.id.uuidString)
                    }
                    }
                    Toggle(store.text("Synchronize live keyboard input and paste", "同步实时键盘输入与粘贴"), isOn: $live).toggleStyle(AxonCheckboxStyle())
                    Text(store.text("Requires at least two connected receivers including the focused terminal. Leaving this pane group or losing a connection pauses synchronization. Typed secrets also reach selected terminals.", "需要至少两个已连接接收终端，并包含当前焦点终端。离开分屏组或连接中断时暂停；输入的密码也会发送至所选终端。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Divider()
                    Text(store.text("Compose command", "统一命令撰写")).fontWeight(.semibold)
                    SnippetTextEditor(text: $command).frame(height: 150).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack { Button(store.text("Insert without Enter", "仅填入，不回车")) { send(false) }.buttonStyle(ChromeButtonStyle()).disabled(!canSend); Button(store.text("Send and run…", "发送并执行…")) { confirming = true }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!canSend); Spacer() }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger) }
                }.padding(20)
            }
            Divider()
            HStack { Text(store.text("Applies only to this pane group", "仅作用于当前分屏组")).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()); Button(store.text("Apply", "应用")) {
                guard !live || (targets.count >= 2 && targets.contains(store.activeSession ?? UUID()) && targets.allSatisfy { id in sessions.contains { $0.id == id && $0.connected } }) else { error = store.text("Select at least two connected receivers including the focused terminal", "请至少选择两个已连接终端，并包含当前焦点终端"); return }
                store.synchronizedTargets = targets; store.synchronizationEnabled = live; dismiss()
            }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-sync-apply").keyboardShortcut(.return, modifiers: .command) }.padding(20)
        }.frame(width: 660, height: 730).background(Palette.card).foregroundStyle(Palette.text).font(.system(size: 12))
            .onAppear { targets = store.synchronizedTargets.intersection(Set(sessions.map(\.id))); live = store.synchronizationEnabled }
            .appAlert(store.text("Run on selected terminals?", "在所选终端执行？"), isPresented: $confirming) {
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
                AppAlertButton(store.text("Run", "执行")) { send(true) }
            } message: { Text(sessions.filter { targets.contains($0.id) }.map(\.displayTitle).joined(separator: "\n") + "\n\n" + command) }
    }
    private func send(_ run: Bool) { do { try store.sendComposed(command, targets: targets, run: run); error = ""; command = "" } catch { self.error = error.localizedDescription } }
}
