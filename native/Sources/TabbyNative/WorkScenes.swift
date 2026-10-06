import Foundation
import SwiftUI
import AppKit

struct WorkSceneTerminal: Codable, Identifiable, Equatable {
    var id = UUID()
    var hostID: UUID?
    var directory = ""
    var persistentSession: Bool?
    var persistentSessionName: String?
}
struct WorkSceneLocation: Codable, Identifiable, Equatable {
    var id = UUID()
    var hostID: UUID?
    var path = ""
}
struct WorkScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var terminals: [WorkSceneTerminal] = []
    var split = false
    var paneGroups: [[Int]]?
    var selectedIndex = 0
    var directories: [WorkSceneLocation] = []
    var logFiles: [WorkSceneLocation] = []
    var forwardIDs: [UUID] = []
    var startForwards = false

    func validated(workspace: Workspace, allowEmpty: Bool = false) throws -> WorkScene {
        var result = self
        result.name = try ConnectionValidation.label(name, required: true)
        guard (allowEmpty || !terminals.isEmpty), terminals.count <= 32,
              directories.count <= 32, logFiles.count <= 32, forwardIDs.count <= 32 else {
            throw AppFailure.message("A scene needs 1–32 terminals / 场景需要 1–32 个终端")
        }
        if let paneGroups {
            let indices = paneGroups.flatMap { $0 }
            guard Set(indices).count == indices.count, paneGroups.allSatisfy({ (2...4).contains($0.count) && $0.allSatisfy { terminals.indices.contains($0) } }) else { throw AppFailure.message("Invalid pane layout / 分屏布局无效") }
        }
        let ids = terminals.map(\.id) + directories.map(\.id) + logFiles.map(\.id)
        guard Set(ids).count == ids.count, Set(forwardIDs).count == forwardIDs.count else { throw AppFailure.message("Duplicate scene items / 场景项目重复") }
        for entry in terminals {
            if entry.persistentSession == true, entry.hostID == nil { throw AppFailure.message("tmux requires a remote host / tmux 需要远端主机") }
            if let name = entry.persistentSessionName, !name.isEmpty { _ = try PersistentSession.validatedName(name) }
        }
        for hostID in terminals.compactMap(\.hostID) + directories.compactMap(\.hostID) + logFiles.compactMap(\.hostID) {
            guard workspace.hosts.contains(where: { $0.id == hostID }) else { throw AppFailure.message("A scene host is unavailable / 场景主机已不存在，请编辑场景") }
        }
        for id in forwardIDs where !workspace.forwards.contains(where: { $0.id == id }) { throw AppFailure.message("A scene forwarding rule is unavailable / 场景转发规则已不存在") }
        for path in terminals.map(\.directory).filter({ !$0.isEmpty }) + directories.map(\.path) + logFiles.map(\.path) {
            _ = try TerminalDirectoryBridge.safeChangeDirectoryCommand(path: path)
        }
        guard selectedIndex >= 0, selectedIndex < max(1, terminals.count) else { throw AppFailure.message("Invalid scene selection / 场景选择无效") }
        return result
    }
    mutating func removeHost(_ id: UUID) {
        terminals.removeAll { $0.hostID == id }; directories.removeAll { $0.hostID == id }; logFiles.removeAll { $0.hostID == id }
        selectedIndex = min(selectedIndex, max(0, terminals.count - 1))
    }
}

@MainActor final class OpenWorkScene: ObservableObject, Identifiable {
    let id: UUID
    var definition: WorkScene
    var sessionIDs: [UUID]
    var logIDs: [UUID] = []
    var selectedSessionID: UUID?
    weak var store: AppStore?
    @Published var mode = "terminal" { didSet { store?.objectWillChange.send() } }
    init(definition: WorkScene, sessionIDs: [UUID], store: AppStore) {
        id = definition.id; self.definition = definition; self.sessionIDs = sessionIDs; self.store = store; self.selectedSessionID = sessionIDs.isEmpty ? nil : sessionIDs[min(definition.selectedIndex, sessionIDs.count - 1)]
    }
}

@MainActor extension AppStore {
    var sceneFileSessions: [TerminalSession] {
        guard sceneWindowID != nil, let scene = currentScene else { return [] }
        var hosts: [UUID?] = []
        return sessions.filter { session in
            guard scene.sessionIDs.contains(session.id), scene.definition.directories.contains(where: { $0.hostID == session.host?.id }), !hosts.contains(where: { $0 == session.host?.id }) else { return false }
            hosts.append(session.host?.id); return true
        }
    }
    var currentScene: OpenWorkScene? { openScenes.first { $0.id == activeSceneID } }
    var standaloneSessions: [TerminalSession] { sessions.filter { session in sceneWindowID != nil || !openScenes.contains { $0.sessionIDs.contains(session.id) } } }
    var standaloneLogViewers: [LogViewerModel] { logViewers.filter { viewer in sceneWindowID != nil || !openScenes.contains { $0.logIDs.contains(viewer.id) } } }
    func saveScene(_ original: WorkScene) throws {
        let value = try original.validated(workspace: workspace)
        let previous = workspace
        if let index = workspace.workScenes.firstIndex(where: { $0.id == value.id }) { workspace.workScenes[index] = value }
        else { workspace.workScenes.append(value) }
        guard save() else { workspace = previous; throw AppFailure.message(error ?? "Could not save scene") }
        if let runtime = openScenes.first(where: { $0.id == value.id }) { runtime.definition.name = value.name; objectWillChange.send() }
    }
    func removeScene(_ id: UUID) throws {
        let previous = workspace; workspace.workScenes.removeAll { $0.id == id }
        guard save() else { workspace = previous; throw AppFailure.message(error ?? "Could not remove scene") }
    }
    func showScene(_ scene: OpenWorkScene) {
        activeSceneID = scene.id
        if !scene.sessionIDs.contains(activeSession ?? UUID()) { activeSession = scene.selectedSessionID.flatMap { selected in sessions.contains(where: { $0.id == selected }) ? selected : nil } ?? scene.sessionIDs.first { id in sessions.contains { $0.id == id } } }
        if scene.mode == "logs" { selectSceneLogIfNeeded(scene) }
        section = sceneWindowID == nil ? "scene" : "terminal"
    }
    func selectSceneLogIfNeeded(_ scene: OpenWorkScene) {
        if !scene.logIDs.contains(activeLogViewer ?? UUID()) { activeLogViewer = scene.logIDs.last }
    }
    func showFileSection() {
        if sceneWindowID == nil, let scene = openScenes.first(where: { $0.sessionIDs.contains(activeSession ?? UUID()) }) { activeSceneID = scene.id; scene.mode = "files"; section = sceneWindowID == nil ? "scene" : "sftp" }
        else { section = "sftp" }
    }
    func showTerminalSection() {
        if sceneWindowID == nil, let scene = openScenes.first(where: { $0.sessionIDs.contains(activeSession ?? UUID()) }) { activeSceneID = scene.id; scene.mode = "terminal"; section = "scene" }
        else { section = "terminal" }
    }
    @discardableResult func openScene(_ original: WorkScene) throws -> OpenWorkScene {
        if let open = openScenes.first(where: { $0.id == original.id }) { showScene(open); return open }
        let scene = try original.validated(workspace: workspace)
        var entries = scene.terminals
        let neededHosts = scene.directories.compactMap(\.hostID) + scene.logFiles.compactMap(\.hostID)
            + (scene.startForwards ? workspace.forwards.filter { scene.forwardIDs.contains($0.id) }.compactMap(\.hostID) : [])
        for id in neededHosts where !entries.contains(where: { $0.hostID == id }) { entries.append(WorkSceneTerminal(hostID: id)) }
        if (scene.directories.contains { $0.hostID == nil } || scene.logFiles.contains { $0.hostID == nil }), !entries.contains(where: { $0.hostID == nil }) { entries.append(WorkSceneTerminal()) }
        var created: [TerminalSession] = []
        for entry in entries {
            let host = entry.hostID.flatMap { id in workspace.hosts.first { $0.id == id } }
            let session = TerminalSession(host: host, store: self)
            session.persistentOverride = entry.persistentSession
            if entry.persistentSession == true { session.persistentNameOverride = entry.persistentSessionName?.isEmpty == false ? entry.persistentSessionName : PersistentSession.defaultName(entry.id) }
            created.append(session)
        }
        let runtime = OpenWorkScene(definition: scene, sessionIDs: created.map(\.id), store: self)
        sessions += created; openScenes.append(runtime)
        activeSceneID = runtime.id; activeSession = created[min(scene.selectedIndex, created.count - 1)].id; section = "scene"
        if let groups = scene.paneGroups {
            for group in groups { let ids = group.map { created[$0].id }; terminalPaneGroups[ids[0]] = ids; if ids.count == 2 { splitPartners[ids[0]] = ids[1]; splitPartners[ids[1]] = ids[0] } }
        } else if scene.split, created.count >= 2 { splitPartners[created[0].id] = created[1].id; splitPartners[created[1].id] = created[0].id }
        created.forEach { _ = $0.makeView() }
        let taskToken = UUID(); sceneTaskTokens[scene.id] = taskToken
        sceneTasks[scene.id] = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer { if self.sceneTaskTokens[scene.id] == taskToken { self.sceneTasks.removeValue(forKey: scene.id); self.sceneTaskTokens.removeValue(forKey: scene.id) } }
            // Initial directories apply only to these freshly created terminals.
            for (entry, session) in zip(entries, created) where !entry.directory.isEmpty {
                for _ in 0..<600 {
                    if Task.isCancelled || !self.openScenes.contains(where: { $0 === runtime }) { return }
                    if session.connected, session.host == nil || session.writer != nil { break }
                    if !session.connectionInProgress, !session.connected { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if session.connected, !session.usesPersistentSession || session.persistentSessionWasCreated, let command = try? TerminalDirectoryBridge.safeChangeDirectoryCommand(path: entry.directory) {
                    let bytes = try? SnippetInput.bytes(command, action: .run, bracketedPaste: session.terminal?.terminalStateSnapshot().bracketedPasteMode ?? false, chinese: self.chinese)
                    if let bytes { session.terminal?.send(data: bytes[...]) }
                }
            }
            if scene.startForwards {
                for id in scene.forwardIDs {
                    guard !Task.isCancelled, self.openScenes.contains(where: { $0 === runtime }), let rule = self.workspace.forwards.first(where: { $0.id == id }) else { return }
                    if self.forwardTasks[id] == nil { self.startForward(rule, origin: .scene) }
                }
            }
        }
        return runtime
    }
    func closeScene(_ id: UUID) {
        guard let scene = openScenes.first(where: { $0.id == id }) else { return }
        sceneTaskTokens.removeValue(forKey: id); sceneTasks.removeValue(forKey: id)?.cancel()
        openScenes.removeAll { $0.id == id }
        for log in scene.logIDs { closeLogViewer(log) }
        for rule in scene.definition.forwardIDs where sceneManagedForwardIDs.contains(rule) {
            if !openScenes.contains(where: { $0.definition.startForwards && $0.definition.forwardIDs.contains(rule) }) {
                stopForward(rule); sceneManagedForwardIDs.remove(rule)
            }
        }
        // A rule shared with another scene or explicitly started outside a
        // scene keeps its SSH transport alive as a standalone session.
        for session in scene.sessionIDs where !forwardSessionIDs.values.contains(session) { close(session) }
        if activeSceneID == id {
            activeSceneID = openScenes.last?.id
            if let next = currentScene { showScene(next) }
            else { section = standaloneSessions.isEmpty ? "hosts" : "terminal"; activeSession = standaloneSessions.last?.id }
        }
    }
    func captureScene() -> WorkScene {
        let owner = (section == "scene" || sceneWindowID != nil) ? currentScene : nil
        var scene = owner?.definition ?? WorkScene()
        let candidates = owner.map { runtime in sessions.filter { runtime.sessionIDs.contains($0.id) } } ?? standaloneSessions
        let source = candidates.filter { session in session.host == nil || workspace.hosts.contains(where: { $0.id == session.host?.id }) }
        scene.terminals = source.map { session in
            WorkSceneTerminal(hostID: session.host?.id, directory: session.currentDirectory ?? "", persistentSession: session.persistentOverride, persistentSessionName: session.usesPersistentSession ? session.persistentName : nil)
        }
        if sceneWindowID != nil || owner == nil {
            let openedDirectories = source.flatMap { session -> [WorkSceneLocation] in
                guard let files = session.sceneFiles else { return [] }
                var locations = [WorkSceneLocation(path: files.local.path)]
                if let remote = files.remote { locations.append(WorkSceneLocation(hostID: files.rightHost?.id, path: remote.path)) }
                return locations
            }
            if !openedDirectories.isEmpty {
                scene.directories = openedDirectories.reduce(into: []) { result, location in
                    if !result.contains(where: { $0.hostID == location.hostID && $0.path == location.path }) { result.append(location) }
                }
            }
            scene.logFiles = logViewers.map { WorkSceneLocation(hostID: $0.hostID, path: $0.entry.path) }
        }
        scene.selectedIndex = max(0, source.firstIndex { $0.id == activeSession } ?? 0)
        scene.paneGroups = source.filter { paneIDs(containing: $0.id).first == $0.id }.map { session in paneIDs(containing: session.id).compactMap { id in source.firstIndex { $0.id == id } } }.filter { $0.count >= 2 }
        scene.split = scene.paneGroups?.isEmpty == false
        scene.directories.removeAll { location in location.hostID.map { id in !workspace.hosts.contains { $0.id == id } } ?? false }
        scene.logFiles.removeAll { location in location.hostID.map { id in !workspace.hosts.contains { $0.id == id } } ?? false }
        scene.forwardIDs.removeAll { id in !workspace.forwards.contains { $0.id == id } }
        if owner == nil { scene.name = text("New scene", "新工作场景") }
        return scene
    }
    func openSceneDirectory(_ location: WorkSceneLocation) {
        guard let scene = currentScene, let session = sessions.first(where: { scene.sessionIDs.contains($0.id) && $0.host?.id == location.hostID }) else { return }
        activeSession = session.id; scene.mode = "files"; section = sceneWindowID == nil ? "scene" : "sftp"
        do { try openTerminalDirectoryInFiles(sessionID: session.id, path: location.path) } catch { self.error = error.localizedDescription }
    }
    func openSceneLog(_ location: WorkSceneLocation) {
        guard let scene = currentScene else { return }
        if let existing = logViewers.first(where: { scene.logIDs.contains($0.id) && $0.hostID == location.hostID && $0.entry.path == location.path }) {
            activeLogViewer = existing.id; scene.mode = "logs"; if sceneWindowID != nil { section = "logviewer" }; return
        }
        Task { [weak self, weak scene] in
            guard let self, let scene else { return }
            do {
                var remoteToClose: RemoteFiles?
                defer { if let remote = remoteToClose { Task { try? await remote.close() } } }
                let backend: any FileEndpoint
                if let id = location.hostID {
                    guard let session = self.sessions.first(where: { scene.sessionIDs.contains($0.id) && $0.host?.id == id }), let client = session.client, client.isConnected else { throw AppFailure.message(self.text("Connect this scene host first", "请先连接场景中的该主机")) }
                    let remote = RemoteFiles(try await client.openSFTP()); backend = remote; remoteToClose = remote
                } else { backend = LocalFiles() }
                let entry = try await backend.stat(location.path)
                guard self.openScenes.contains(where: { $0 === scene }) else { return }
                let pane = FilePane(path: (location.path as NSString).deletingLastPathComponent, backend: backend)
                let viewer = self.openLogViewer(pane: pane, entry: entry, host: location.hostID.flatMap { id in self.workspace.hosts.first { $0.id == id } }, sceneID: scene.id)
                if let remote = backend as? RemoteFiles { viewer.onClose = { Task { try? await remote.close() } }; remoteToClose = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult func openLogViewer(pane: FilePane, entry: FileEntry, host: Host? = nil, sceneID: UUID? = nil) -> LogViewerModel {
        let viewer = LogViewerModel(pane: pane, entry: entry, title: (host?.name).map { $0 + " · " + entry.name } ?? entry.name)
        viewer.hostID = host?.id; logViewers.append(viewer); activeLogViewer = viewer.id
        let owner = sceneID.flatMap { id in openScenes.first { $0.id == id } } ?? ((section == "scene" || sceneWindowID != nil) ? currentScene : nil)
        if let owner { owner.logIDs.append(viewer.id); activeSceneID = owner.id; owner.mode = "logs"; section = sceneWindowID == nil ? "scene" : "logviewer" }
        else { section = "logviewer" }
        return viewer
    }
    func closeLogViewer(_ id: UUID) {
        logViewers.first { $0.id == id }?.close(); logViewers.removeAll { $0.id == id }
        for scene in openScenes { scene.logIDs.removeAll { $0 == id } }
        if activeLogViewer == id {
            if section == "scene", let scene = currentScene { activeLogViewer = scene.logIDs.last }
            else { activeLogViewer = standaloneLogViewers.last?.id }
        }
        if section == "logviewer", activeLogViewer == nil { section = "hosts" }
        objectWillChange.send()
    }
}

struct WorkSceneLibrary: View {
    @EnvironmentObject var store: AppStore
    var query = ""
    @State private var editing: WorkScene?
    @State private var deleting: WorkScene?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.text("Work scenes", "常用工作场景")).font(.headline)
                Spacer()
                Button { editing = WorkScene(name: store.text("New scene", "新工作场景"), terminals: [WorkSceneTerminal()]) } label: { Label(store.text("New scene", "新建场景"), systemImage: "plus") }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-new-scene")
                if !store.sessions.isEmpty { Button { editing = store.captureScene() } label: { Label(store.text("Save current", "保存当前组合"), systemImage: "square.and.arrow.down") }.buttonStyle(ChromeButtonStyle()) }
            }
            ForEach(store.workspace.workScenes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { scene in
                HStack {
                    Button { do { try SceneWindowController.open(scene, owner: store) } catch { store.error = error.localizedDescription } } label: {
                        HStack(spacing: 12) { IconTile(symbol: "rectangle.3.group", color: Palette.blue, size: 30); VStack(alignment: .leading) { Text(scene.name).font(.system(size: 13, weight: .medium)); Text("\(scene.terminals.count) " + store.text("terminals", "个终端") + " · \(scene.logFiles.count) " + store.text("logs", "个日志")).font(.caption).foregroundStyle(Palette.muted) }; Spacer() }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(AxonSurfaceButtonStyle())
                    Button { editing = scene } label: { Image(systemName: "pencil").frame(width: 26, height: 30) }.buttonStyle(AxonSurfaceButtonStyle()).help(store.text("Edit scene", "编辑场景"))
                    Button { deleting = scene } label: { Image(systemName: "trash").frame(width: 26, height: 30) }.buttonStyle(AxonSurfaceButtonStyle()).help(store.text("Remove scene", "移除场景"))
                }.background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }.sheet(item: $editing) { WorkSceneEditor(value: $0).environmentObject(store) }
            .appAlert(store.text("Remove scene?", "移除工作场景？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { deleting = nil }
                AppAlertButton(store.text("Remove", "移除"), role: .destructive) { if let deleting { do { try store.removeScene(deleting.id) } catch { store.error = error.localizedDescription } }; deleting = nil }
            } message: { Text(store.text("The saved template will be removed. Open sessions stay available.", "移除保存的模板，已打开的场景仍可继续使用。")) }
    }
}

struct WorkSceneEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var value: WorkScene
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text("Configure work scene", "配置工作场景")).font(.system(size: 20, weight: .semibold))
                Text(store.text("Save the terminals and tools you use together. Open them next time from one scene card.", "把常用的终端和工具保存为一个组合，下次点击场景卡片即可打开。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text("Scene name", "场景名称")).font(.system(size: 12, weight: .medium))
                TextField(store.text("For example: production troubleshooting", "例如：生产环境排查"), text: $value.name).appInput()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading(store.text("Terminals", "打开哪些终端"), description: store.text("Each row opens one terminal. Select a saved SSH host or your local shell. Blank directories use the host's default directory.", "每一行打开一个终端。选择 SSH 主机或本地终端；初始目录留空时使用默认目录。"))
                        ForEach($value.terminals) { $item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(store.text("Terminal", "终端") + " \((value.terminals.firstIndex { $0.id == item.id } ?? 0) + 1)").font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Button { moveTerminal(item.id, by: -1) } label: { Image(systemName: "chevron.up") }.help(store.text("Move up", "上移")).disabled(value.terminals.first?.id == item.id)
                                    Button { moveTerminal(item.id, by: 1) } label: { Image(systemName: "chevron.down") }.help(store.text("Move down", "下移")).disabled(value.terminals.last?.id == item.id)
                                    Button { value.terminals.removeAll { $0.id == item.id }; value.selectedIndex = 0; if value.terminals.count < 2 { value.split = false } } label: { Image(systemName: "trash") }.help(store.text("Remove terminal", "移除此终端"))
                                }.buttonStyle(IconButtonStyle())
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(store.text("Connect to", "连接到")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                        SceneHostSelector(selection: $item.hostID).frame(height: 38)
                                            .onChange(of: item.hostID) { _, id in if id == nil { item.persistentSession = false } }
                                    }.frame(maxWidth: .infinity)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(store.text("Initial directory · optional", "初始目录 · 可选")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                        TextField("/var/www/app", text: $item.directory).appInput()
                                    }.frame(maxWidth: .infinity)
                                }
                                Divider().padding(.vertical, 4)
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle(isOn: Binding(get: { item.persistentSession ?? false }, set: { item.persistentSession = $0 })) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(store.text("Keep the remote session with tmux", "使用 tmux 保留远程会话")).font(.system(size: 12, weight: .medium))
                                            Text(item.hostID == nil
                                                ? store.text("Available for SSH hosts", "选择 SSH 主机后可用")
                                                : store.text("Reconnect to the same session after disconnecting", "断线后重新连接到同一个会话"))
                                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                        }.padding(.vertical, 8)
                                    }.toggleStyle(AxonCheckboxStyle()).disabled(item.hostID == nil)
                                    if item.persistentSession == true && item.hostID != nil {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(store.text("tmux session name · optional", "tmux 会话名称 · 可选")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                            TextField(store.text("Use the default session name", "留空使用默认会话名称"), text: Binding(get: { item.persistentSessionName ?? "" }, set: { item.persistentSessionName = $0 })).appInput()
                                        }.frame(maxWidth: 340, alignment: .leading).padding(.leading, 34)
                                    }
                                }

                            }.padding(16).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if value.terminals.isEmpty { Text(store.text("Add a terminal to connect to a host or open your local shell.", "添加一个终端，连接主机或打开本地 Shell。")).font(.caption).foregroundStyle(Palette.muted) }
                        HStack {
                            Button { value.terminals.append(WorkSceneTerminal()) } label: { Label(store.text("Add terminal", "添加终端"), systemImage: "plus") }.buttonStyle(ChromeButtonStyle())
                            Spacer()
                            AxonChoiceField(selection: Binding(get: { value.paneGroups?.first?.count ?? (value.split ? 2 : 1) }, set: { count in
                                value.split = count > 1
                                value.paneGroups = count > 1 ? [Array(0..<min(count, value.terminals.count))] : nil
                            }), choices: [(1, store.text("Separate tabs", "独立标签"))] + (value.terminals.count >= 2 ? [(2, store.text("Two panes", "双终端分屏"))] : []) + (value.terminals.count >= 3 ? [(3, store.text("Three panes", "三终端分屏"))] : []) + (value.terminals.count >= 4 ? [(4, store.text("Four panes", "四终端分屏"))] : []), placeholder: store.text("Pane layout", "分屏布局"), symbol: "rectangle.split.2x2", identifier: "axon-scene-pane-layout").frame(width: 210)
                        }
                    }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    locationEditor(title: store.text("SFTP directories · optional", "SFTP 文件目录 · 可选"), description: store.text("Saved shortcuts inside this scene. Choose a host and enter an absolute directory path, for example /var/www/app.", "在场景内保存常用目录快捷入口。选择主机并填写绝对目录，例如 /var/www/app。"), placeholder: "/var/www/app", buttonTitle: store.text("Add directory", "添加文件目录"), locations: $value.directories)
                    locationEditor(title: store.text("Follow log files · optional", "跟踪日志文件 · 可选"), description: store.text("Open these files in the log viewer when the scene opens. Enter a file path, not a directory, for example /var/log/app.log.", "打开场景时在日志查看器中跟踪这些文件。填写文件路径，例如 /var/log/app.log，不是目录。"), placeholder: "/var/log/app.log", buttonTitle: store.text("Add log file", "添加日志文件"), locations: $value.logFiles)
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeading(store.text("Port forwarding / SOCKS · optional", "端口转发 / SOCKS 代理 · 可选"), description: store.text("Reuse rules from Port forwarding. Enable automatic start only if you want these rules started with this scene.", "复用“端口转发”中已有的规则。需要随场景启动时，再开启下方选项。"))
                        if store.workspace.forwards.isEmpty { Text(store.text("No saved rules. Create rules under Port forwarding first; you can skip this section.", "尚无转发规则。可先到左侧“端口转发”创建；不需要代理时跳过此项。")).font(.caption).foregroundStyle(Palette.muted) }
                        ForEach(store.workspace.forwards) { rule in
                            Toggle(rule.name, isOn: Binding(get: { value.forwardIDs.contains(rule.id) }, set: { on in value.forwardIDs.removeAll { $0 == rule.id }; if on { value.forwardIDs.append(rule.id) } })).toggleStyle(AxonCheckboxStyle())
                        }
                        Toggle(store.text("Start selected rules when opening", "打开场景时启动所选规则"), isOn: $value.startForwards).toggleStyle(AxonCheckboxStyle()).disabled(value.forwardIDs.isEmpty)
                    }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                }.padding(.trailing, 4)
            }
            Divider()
            HStack {
                Text(store.text("Closing a scene closes its terminals and the proxies it started.", "关闭场景会关闭其终端及由它启动的代理。")).font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button(store.text("Save scene", "保存场景")) { do { try store.saveScene(value); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(ChromeButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 780, height: 640).background(Palette.sidebar).foregroundStyle(Palette.text)
            .onChange(of: value.terminals.map(\.id)) { old, new in
                guard let groups = value.paneGroups else { return }
                value.paneGroups = groups.map { group in group.compactMap { index in old.indices.contains(index) ? new.firstIndex(of: old[index]) : nil } }.filter { $0.count >= 2 }
                value.split = value.paneGroups?.isEmpty == false
            }
    }
    private func sectionHeading(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(description).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
    }
    private func moveTerminal(_ id: UUID, by offset: Int) {
        guard let index = value.terminals.firstIndex(where: { $0.id == id }), value.terminals.indices.contains(index + offset) else { return }
        value.terminals.swapAt(index, index + offset); value.selectedIndex = 0
    }
    private func hostPicker(_ binding: Binding<UUID?>) -> some View {
        SceneHostSelector(selection: binding).frame(width: 180)
    }
    private func locationEditor(title: String, description: String, placeholder: String, buttonTitle: String, locations: Binding<[WorkSceneLocation]>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(title, description: description)
            ForEach(locations) { $item in
                HStack { hostPicker($item.hostID); TextField(placeholder, text: $item.path).appInput(); Button { locations.wrappedValue.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).help(store.text("Remove path", "移除此路径")) }
            }
            Button { locations.wrappedValue.append(WorkSceneLocation()) } label: { Label(buttonTitle, systemImage: "plus") }.buttonStyle(ChromeButtonStyle())
        }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }

}

struct WorkSceneToolbar: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var scene: OpenWorkScene
    var toggleTools: () -> Void = {}
    @State private var editing: WorkScene?
    var body: some View {
        HStack(spacing: 12) {
            AppActionMenu {
                if scene.mode == "logs" {
                    ForEach(store.logViewers.filter { scene.logIDs.contains($0.id) }) { log in Button(log.title) { store.activeLogViewer = log.id } }
                    ForEach(scene.definition.logFiles) { location in Button(location.path) { store.openSceneLog(location) } }
                } else {
                    ForEach(store.sessions.filter { scene.sessionIDs.contains($0.id) }) { session in Button(session.displayTitle) { scene.selectedSessionID = session.id; store.activeSession = session.id } }
                    if scene.mode == "files" { Divider(); ForEach(scene.definition.directories) { location in Button(location.path) { store.openSceneDirectory(location) } } }
                }
            } label: {
                HStack { Image(systemName: scene.mode == "logs" ? "doc.text" : scene.mode == "files" ? "folder" : "terminal"); Text(scene.mode == "logs" ? (store.logViewers.first { $0.id == store.activeLogViewer }?.title ?? store.text("Select log", "选择日志")) : (store.sessions.first { $0.id == store.activeSession }?.displayTitle ?? store.text("Select terminal", "选择终端"))).lineLimit(1); Image(systemName: "chevron.down") }.padding(.horizontal, 12).frame(width: 230, height: 34).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Palette.text)
            Spacer(minLength: 0)
            if scene.mode == "terminal" { Button(action: toggleTools) { Image(systemName: "sidebar.right") }.buttonStyle(ChromeButtonStyle()).help(store.text("Terminal tools", "终端工具")) }
            AxonChoiceField(selection: $scene.mode, choices: [("terminal", store.text("Terminal", "终端")), ("files", "SFTP"), ("logs", store.text("Logs", "日志"))], placeholder: store.text("View", "视图"), symbol: "rectangle.3.group", identifier: "axon-scene-view").frame(width: 230)
            Button { editing = store.captureScene() } label: { Label(store.text("Save layout", "保存布局"), systemImage: "square.and.arrow.down") }.buttonStyle(ChromeButtonStyle())
            AppActionMenu {
                ForEach(scene.definition.directories) { location in Button(location.path) { store.openSceneDirectory(location) } }
                Divider()
                ForEach(scene.definition.logFiles) { location in Button(store.text("Log: ", "日志：") + location.path) { store.openSceneLog(location) } }
                ForEach(store.logViewers.filter { scene.logIDs.contains($0.id) }) { log in Button(store.text("Close log: ", "关闭日志：") + log.title) { store.closeLogViewer(log.id) } }
                Divider()
                ForEach(store.workspace.forwards.filter { scene.definition.forwardIDs.contains($0.id) }) { rule in Button((store.forwardTasks[rule.id] == nil ? store.text("Start ", "启动 ") : store.text("Stop ", "停止 ")) + rule.name) { if store.forwardTasks[rule.id] == nil { store.startForward(rule, origin: .scene) } else { store.stopForward(rule.id) } } }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 34) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(12).background(Palette.sidebar)
            .onChange(of: scene.mode) { _, mode in
                if mode == "logs" { store.selectSceneLogIfNeeded(scene) }
            }.sheet(item: $editing) { WorkSceneEditor(value: $0).environmentObject(store) }
    }
}

struct WorkAreaTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) { Image(systemName: "xmark").frame(width: 18, height: 30) }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel("Close " + title)
            Button(action: select) { Label(title, systemImage: symbol).lineLimit(1).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(AxonSurfaceButtonStyle())
        }.padding(.horizontal, 10).frame(width: selected ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive, height: 34)
            .foregroundStyle(Palette.chromeText).background(Color(hex: selected ? "#45475F" : "#393C52")).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("axon-workarea-tab-" + title)
    }
}
