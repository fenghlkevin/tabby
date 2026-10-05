import Foundation
import AppKit
import SwiftUI
import SwiftTerm
import Citadel
import NIO
import NIOSSH
import Crypto

final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let store: AppStore
    init(endpoint: String, store: AppStore) { self.endpoint = endpoint; self.store = store }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let encoded = String(openSSHPublicKey: hostKey)
        let bytes = encoded.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) } ?? Data()
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        Task { @MainActor in
            if let known = store.workspace.trustedKeys[endpoint] {
                guard known == encoded else { validationCompletePromise.fail(AppFailure.message("Host key changed for \(endpoint). Connection rejected.")); return }
            } else {
                let alert = AppModalAlert()
                alert.messageText = store.text("Trust this server?", "信任此服务器？")
                alert.informativeText = "\(endpoint)\n\(fingerprint)\n" + store.text("Verify this fingerprint before connecting.", "请确认服务器指纹后连接。")
                alert.addButton(withTitle: store.text("Trust and connect", "信任并连接")); alert.addButton(withTitle: store.text("Cancel", "取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { validationCompletePromise.fail(CancellationError()); return }
                store.workspace.trustedKeys[endpoint] = encoded; store.save()
            }
            validationCompletePromise.succeed(())
        }
    }
}

@MainActor final class TerminalSession: ObservableObject, Identifiable, TerminalViewDelegate, LocalProcessTerminalViewDelegate {
    private static var nextCreationOrder: UInt64 = 0
    let id = UUID()
    let creationOrder: UInt64
    let host: Host?
    weak var sceneFiles: FileManagerModel?
    private(set) var authenticatedUsername: String?
    private(set) var authenticatedAddress: String?
    private(set) var authenticatedPort: Int?
    private(set) var authenticatedRoute: [MonitoringRouteHop] = []
    private(set) var connectionInProgress = false
    unowned let store: AppStore
    @Published private(set) var title: String {
        didSet { if title != oldValue { store.objectWillChange.send() } }
    }
    @Published var status = ""
    @Published private(set) var currentDirectory: String? {
        didSet { if currentDirectory != oldValue { store.objectWillChange.send() } }
    }
    @Published var followDirectoryInFiles = false {
        didSet { store.objectWillChange.send() }
    }
    var pendingDirectoryInsertion: (command: String, host: Host?)?
    @Published var connected = false {
        didSet {
            if connected != oldValue {
                store.objectWillChange.send()
                store.monitoring.connectionsChanged()
                if connected { deliverPendingDirectoryInsertion() }
            }
        }
    }
    var client: SSHClient?
    private var jumpClients: [SSHClient] = []
    var writer: TTYStdinWriter?
    var terminal: TerminalView?
    var task: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private(set) var generation = 0
    private var localProcessGeneration: Int?
    private var columns = 100
    private var rows = 30
    private var temporaryAuthentications: [UUID: ConnectionAuthenticationCacheEntry] = [:]
    private var resolvedSettingsHosts: [UUID: Host] = [:]
    private var authenticationWindow: ConnectionAuthenticationWindowController?
    init(host: Host?, store: AppStore) {
        creationOrder = Self.nextCreationOrder; Self.nextCreationOrder += 1
        self.host = host; self.store = store
        authenticatedUsername = host.map { RecentTargets.effectiveUsername($0, workspace: store.workspace) }
        authenticatedAddress = host?.address; authenticatedPort = host.map { store.resolvedHost($0).port }
        self.title = host.map { Self.remoteTitle(for: $0, store: store) } ?? store.text("Local terminal", "本地终端")
    }
    private static func remoteTitle(for host: Host, store: AppStore) -> String {
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? host.address : name
        let username = RecentTargets.effectiveUsername(host, workspace: store.workspace)
        return username.isEmpty ? label : "\(username)@\(label)"
    }
    func matchesEndpoint(_ target: Host) -> Bool {
        guard let host, RecentTargets.canReuseProfile(host, target, workspace: store.workspace) else { return false }
        let requested = store.resolvedHost(target)
        if connected {
            var route: [MonitoringRouteHop] = []
            var current = requested
            var seen: Set<UUID> = [current.id]
            while let id = current.jumpHostID {
                guard seen.insert(id).inserted, let raw = store.workspace.hosts.first(where: { $0.id == id }) else { return false }
                current = store.resolvedHost(raw)
                route.insert(MonitoringRouteHop(address: current.address, port: current.port, username: current.username), at: 0)
            }
            guard route == authenticatedRoute else { return false }
        }
        return authenticatedAddress?.caseInsensitiveCompare(requested.address) == .orderedSame
            && authenticatedPort == requested.port
            && authenticatedUsername == requested.username
    }
    func makeView() -> TerminalView {
        if let terminal { return terminal }
        let pref = store.workspace.preferences
        let options = TerminalOptions(termName: "xterm-256color", cursorStyle: TerminalAppearance.cursorStyle(pref), scrollback: max(0, min(1000000, pref.scrollback)), enableSixelReported: false)
        let font = NSFont(name: pref.fontName, size: pref.fontSize) ?? .monospacedSystemFont(ofSize: pref.fontSize, weight: .light)
        let view: TerminalView
        if host == nil {
            let local = LocalTerminal(frame: .zero, font: font, options: options)
            local.processDelegate = self
            local.store = store; local.sessionID = id
            view = local
        } else {
            let remote = RemoteTerminal(frame: .zero, font: font, options: options)
            remote.store = store; remote.sessionID = id
            remote.terminalDelegate = self
            view = remote
        }
        TerminalAppearance.apply(pref, to: view)
        terminal = view
        if let local = view as? LocalProcessTerminalView {
            localProcessGeneration = generation
            let launch = LocalTerminalLaunch(preferences: pref)
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            local.startProcess(executable: launch.executable, args: launch.arguments, environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: launch.directory)
            connected = true; status = store.text("Connected", "已连接")
            if local.process.running { store.recordRecentSuccess(kind: .localTerminal) }
        } else { reconnect() }
        return view
    }
    func settings(for original: Host,
                  authenticationPrompt: ((ConnectionAuthenticationDraft) throws -> ConnectionAuthenticationResult)? = nil) throws -> SSHClientSettings {
        // Metadata validation still precedes Keychain reads and presentation.
        // Reload saved auth metadata so remembered choices apply on reconnect.
        let saved = GroupDefaults.connectionSource(original, workspace: store.workspace)
        let source = try ConnectionValidation.host(saved, workspace: store.workspace, chinese: store.chinese)
        let secretID = store.groupSecretID(for: saved)
        let material = Secrets.Value(secret: try Secrets.readChecked(secretID),
                                     privateKey: source.auth == "key" && source.keySource == "text" ? try Secrets.readPrivateKey(secretID) : "")
        var draft = ConnectionAuthenticationDraft(host: source, material: material)
        var reusable: ConnectionAuthenticationResult?
        var validationError = ""
        var refreshTemporarySelection = false
        if let cached = temporaryAuthentications[source.id], cached.matches(host: source, material: material) {
            if let shared = cached.result.sharedSnapshot {
                if store.workspace.credentials.contains(where: { $0.id == cached.result.host.credentialID }) {
                    let chosen = try ConnectionValidation.host(cached.result.host, workspace: store.workspace, chinese: store.chinese)
                    let chosenMaterial = try Secrets.readCredential(chosen.credentialID!)
                    if shared.matches(host: chosen, material: chosenMaterial) { reusable = cached.result }
                    else {
                        // Keep the temporary identity selection while honoring
                        // edits to its shared metadata and saved secrets.
                        draft = ConnectionAuthenticationDraft(host: chosen, material: chosenMaterial)
                        refreshTemporarySelection = true
                    }
                } else {
                    validationError = store.text("The shared credential is unavailable. Choose another credential.", "共享凭据已不存在，请选择其他凭据。")
                }
            } else { reusable = cached.result }
        }
        let result: ConnectionAuthenticationResult
        if let reusable { result = reusable }
        else {
            temporaryAuthentications[source.id] = nil
            var existing: ConnectionAuthenticationResult?
            do { existing = try draft.validatedResult(workspace: store.workspace, chinese: store.chinese) }
            catch {
                // A missing password is the normal prompt. Key errors explain
                // why the saved file, text or passphrase needs attention.
                if draft.host.auth == "key" { validationError = error.localizedDescription }
            }
            if let existing {
                result = existing
                if refreshTemporarySelection {
                    temporaryAuthentications[source.id] = .init(sourceHost: source, sourceMaterial: material, result: result)
                }
            }
            else {
                if let authenticationPrompt {
                    result = try authenticationPrompt(draft)
                    _ = try result.authentication(chinese: store.chinese)
                    try store.rememberConnectionAuthentication(result)
                } else {
                    let controller = ConnectionAuthenticationWindowController(draft: draft, store: store, initialError: validationError)
                    authenticationWindow = controller
                    defer { if authenticationWindow === controller { authenticationWindow = nil } }
                    result = try controller.present()
                }
                if !result.remember {
                    temporaryAuthentications[source.id] = .init(sourceHost: source, sourceMaterial: material, result: result)
                }
            }
        }
        try Task.checkCancellation()
        let host = result.host
        let auth = try result.authentication(chinese: store.chinese)
        resolvedSettingsHosts[original.id] = host
        var settings = SSHClientSettings(host: host.address, port: host.port, authenticationMethod: { auth }, hostKeyValidator: .custom(HostKeyCheck(endpoint: "\(host.address):\(host.port)", store: store)))
        settings.connectTimeout = .seconds(Int64(max(1, min(120, store.workspace.preferences.sshConnectTimeout))))
        settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
        return settings
    }
    func settingsUsername(for host: Host) -> String {
        resolvedSettingsHosts[host.id]?.username ?? RecentTargets.effectiveUsername(host, workspace: store.workspace)
    }
    func settingsHost(for host: Host) -> Host { resolvedSettingsHosts[host.id] ?? store.resolvedHost(host) }
    func reconnect() {
        guard let host else { return }
        disconnect()
        authenticatedRoute = []
        title = Self.remoteTitle(for: host, store: store)
        let request = generation
        task = Task {
            guard request == generation, !Task.isCancelled else { return }
            var outputFinished = false
            var outputError: Error?
            do {
                connectionInProgress = true
                defer { if request == generation { connectionInProgress = false } }
                status = store.text("Connecting…", "正在连接…")
                store.record("ssh", "connecting", host: host.name)
                var chain: [Host] = []; var current: Host? = host; var seen = Set<UUID>()
                while let h = current {
                    guard seen.insert(h.id).inserted else { throw AppFailure.message("Jump host cycle") }
                    let source = GroupDefaults.connectionSource(h, workspace: store.workspace)
                    chain.insert(source, at: 0)
                    if let jump = store.resolvedHost(source).jumpHostID {
                        guard let next = store.workspace.hosts.first(where: { $0.id == jump }) else { throw AppFailure.message("Jump host not found") }
                        current = next
                    } else { current = nil }
                }
                var connection: SSHClient?
                for h in chain {
                    try Task.checkCancellation()
                    let next: SSHClient
                    let connectionSettings = try settings(for: h)
                    let usernameSnapshot = settingsUsername(for: h)
                    let endpoint = settingsHost(for: h)
                    let addressSnapshot = endpoint.address, portSnapshot = endpoint.port
                    if let connection { next = try await connection.jump(to: connectionSettings) }
                    else { next = try await SSHClient.connect(to: connectionSettings) }
                    guard request == generation else { try? await next.close(); throw CancellationError() }
                    if h.id != host.id {
                        // Own each authenticated hop before a later hop can
                        // prompt or fail, so cancellation also closes the chain.
                        jumpClients.append(next)
                        authenticatedRoute.append(MonitoringRouteHop(address: addressSnapshot, port: portSnapshot, username: usernameSnapshot))
                    }
                    if h.id == host.id {
                        authenticatedUsername = usernameSnapshot
                        authenticatedAddress = addressSnapshot; authenticatedPort = portSnapshot
                        let label = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        title = "\(usernameSnapshot)@\(label.isEmpty ? host.address : label)"
                    }
                    connection = next
                }
                guard let connection else { return }
                client = connection; status = store.text("Opening terminal…", "正在打开终端…")
                try await connection.withPTY(.init(wantReply: true, term: "xterm-256color", terminalCharacterWidth: 100, terminalRowHeight: 30, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { output, input in
                    guard request == generation, !Task.isCancelled else { throw CancellationError() }
                    writer = input; connected = true; connectionInProgress = false; status = store.text("Connected", "已连接")
                    store.record("ssh", "connected", host: host.name)
                    store.recordRecentSuccess(host, kind: .ssh)
                    do {
                        try await input.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        for try await event in output {
                            try Task.checkCancellation()
                            guard request == generation else { throw CancellationError() }
                            switch event {
                            case .stdout(let bytes), .stderr(let bytes): terminal?.feed(byteArray: Array(bytes.readableBytesView)[...])
                            }
                        }
                        outputFinished = true
                    } catch {
                        // Citadel may replace an output error with alreadyClosed
                        // while closing its PTY. Keep the original failure visible.
                        outputError = error
                        throw error
                    }
                }
                guard request == generation else { return }
                connectionEnded(request: request, error: connection.isConnected ? nil : unexpectedDisconnect())
            } catch {
                guard request == generation else { return }
                if outputError == nil, outputFinished, client?.isConnected == true,
                   let channelError = error as? ChannelError, channelError == .alreadyClosed {
                    connectionEnded(request: request)
                } else {
                    connectionEnded(request: request, error: outputError ?? error)
                }
            }
        }
    }
    private func unexpectedDisconnect() -> Error {
        AppFailure.message(store.text("Connection ended unexpectedly. Reconnect to try again.", "连接意外中断，请重新连接。"))
    }
    /// A completion belongs to exactly one connection attempt. Closing or
    /// reconnecting invalidates it before any asynchronous cleanup can return.
    func connectionEnded(request: Int, error: Error? = nil) {
        guard request == generation else { return }
        pendingDirectoryInsertion = nil
        if error == nil || error is CancellationError {
            if error is CancellationError, let host { store.record("ssh", "cancelled", host: host.name) }
            if store.sessions.contains(where: { $0 === self }) { store.close(id) }
            else { disconnect() }
            return
        }
        guard let failure = error else { return }
        disconnect()
        if let exit = failure as? SSHClient.CommandFailed {
            status = store.text("Remote process exited with status \(exit.exitCode)", "远程进程退出，状态码 \(exit.exitCode)")
        } else { status = failure.localizedDescription }
        if let host { store.record("ssh", "connection failed", host: host.name, failed: true) }
        terminal?.feed(text: "\r\n\(status)\r\n")
    }
    func disconnect() {
        generation += 1; localProcessGeneration = nil
        currentDirectory = nil
        authenticationWindow?.cancel()
        if connected, let host { store.record("ssh", "disconnected", host: host.name) }
        inputTask?.cancel(); inputTask = nil
        task?.cancel(); task = nil; writer = nil; connected = false; connectionInProgress = false
        if let local = terminal as? LocalProcessTerminalView { local.terminate() }
        let clients = jumpClients + (client.map { [$0] } ?? [])
        client = nil; jumpClients = []
        Task { for c in clients.reversed() { try? await c.close() } }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { columns = newCols; rows = newRows; Task { try? await writer?.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) } }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) { if host == nil && !title.isEmpty { self.title = title } }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { if host == nil && !title.isEmpty { self.title = title } }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard source === terminal, connected else { return }
        let previous = currentDirectory
        currentDirectory = TerminalDirectoryBridge.currentDirectory(directory, trustedHosts: directoryTrustedHosts)
        guard followDirectoryInFiles, currentDirectory != previous, let currentDirectory else { return }
        do { try store.openTerminalDirectoryInFiles(sessionID: id, path: currentDirectory, activate: false) }
        catch { store.error = error.localizedDescription }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminal, let request = localProcessGeneration, request == generation else { return }
        if exitCode == 0 { connectionEnded(request: request) }
        else {
            let message = exitCode.map { store.text("Process exited with status \($0)", "进程退出，状态码 \($0)") }
                ?? store.text("Process ended unexpectedly", "进程意外结束")
            connectionEnded(request: request, error: AppFailure.message(message))
        }
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard source === terminal, let request = localProcessGeneration, request == generation else { return }
        connectionEnded(request: request, error: AppFailure.message(store.text("Process launch failed: \(error)", "进程启动失败：\(error)")))
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = ByteBuffer(bytes: data)
        let previous = inputTask; let input = writer; let request = generation
        inputTask = Task {
            await previous?.value
            guard !Task.isCancelled, request == generation else { return }
            do { try await input?.write(bytes) }
            catch { if request == generation { status = error.localizedDescription } }
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

}

extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        if let value = self { return try await transform(value) }; return nil
    }
}

@MainActor class RemoteTerminal: TerminalView {
    weak var store: AppStore?
    var sessionID: UUID?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusAttachedTerminal(self, store: store, sessionID: sessionID) }
    override func mouseDown(with event: NSEvent) { if let sessionID { store?.activeSession = sessionID }; super.mouseDown(with: event) }
    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        TerminalPaste.perform(text, preferences: store?.workspace.preferences ?? Preferences(), confirm: { TerminalPaste.confirm($0, chinese: store?.chinese == true, window: window) }, send: pasteText)
    }
    override func rightMouseDown(with event: NSEvent) {
        if store?.workspace.preferences.rightClickPaste == true { paste(self) } else { super.rightMouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)?.copy() as? NSMenu ?? NSMenu()
        if getSelection()?.isEmpty == false {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: store?.text("Locate selected path in SFTP", "在 SFTP 定位所选路径") ?? "Locate selected path in SFTP", action: #selector(openSelectedPathInFiles), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func openSelectedPathInFiles() {
        guard let store, let sessionID else { return }
        do { try store.openTerminalDirectoryInFiles(sessionID: sessionID, isSelection: true) }
        catch { store.error = error.localizedDescription }
    }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); if store?.workspace.preferences.copyOnSelect == true, getSelection()?.isEmpty == false { copy(self) } }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 && store?.workspace.preferences.middleClickPaste != false { paste(self) } else { super.otherMouseDown(with: event) } }
}
@MainActor class LocalTerminal: LocalProcessTerminalView {
    weak var store: AppStore?
    var sessionID: UUID?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusAttachedTerminal(self, store: store, sessionID: sessionID) }
    override func mouseDown(with event: NSEvent) { if let sessionID { store?.activeSession = sessionID }; super.mouseDown(with: event) }
    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        TerminalPaste.perform(text, preferences: store?.workspace.preferences ?? Preferences(), confirm: { TerminalPaste.confirm($0, chinese: store?.chinese == true, window: window) }, send: pasteText)
    }
    override func rightMouseDown(with event: NSEvent) { if store?.workspace.preferences.rightClickPaste == true { paste(self) } else { super.rightMouseDown(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)?.copy() as? NSMenu ?? NSMenu()
        if getSelection()?.isEmpty == false {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: store?.text("Locate selected path in Files", "在文件面板定位所选路径") ?? "Locate selected path in Files", action: #selector(openSelectedPathInFiles), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func openSelectedPathInFiles() {
        guard let store, let sessionID else { return }
        do { try store.openTerminalDirectoryInFiles(sessionID: sessionID, isSelection: true) }
        catch { store.error = error.localizedDescription }
    }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); if store?.workspace.preferences.copyOnSelect == true, getSelection()?.isEmpty == false { copy(self) } }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 && store?.workspace.preferences.middleClickPaste != false { paste(self) } else { super.otherMouseDown(with: event) } }
}

@MainActor private func focusAttachedTerminal(_ view: TerminalView, store: AppStore?, sessionID: UUID?) {
    guard view.window != nil, let store, let sessionID else { return }
    DispatchQueue.main.async { [weak view, weak store] in
        guard let view, let store, !view.isHidden, store.section == "terminal", store.activeSession == sessionID else { return }
        view.window?.makeFirstResponder(view)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var active: Bool
    var focused: Bool
    final class Coordinator { var focused = false; var wantsFocus = false; var revision = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalView { session.makeView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        view.isHidden = !active
        let coordinator = context.coordinator
        coordinator.wantsFocus = active && focused
        guard coordinator.wantsFocus else { coordinator.focused = false; coordinator.revision += 1; return }
        if view.window?.firstResponder === view { coordinator.focused = true; return }
        guard !coordinator.focused else { return }
        coordinator.revision += 1
        let revision = coordinator.revision
        DispatchQueue.main.async { [weak view] in
            guard let view, coordinator.wantsFocus, coordinator.revision == revision, !view.isHidden, let window = view.window else { return }
            coordinator.focused = window.makeFirstResponder(view)
        }
    }
}
