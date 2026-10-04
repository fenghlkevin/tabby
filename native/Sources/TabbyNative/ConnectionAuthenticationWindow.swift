import AppKit
import SwiftUI

@MainActor final class ConnectionAuthenticationModel: ObservableObject {
    @Published var draft: ConnectionAuthenticationDraft
    @Published var error: String
    unowned let store: AppStore
    var onConnect: ((ConnectionAuthenticationResult) -> Void)?
    var onCancel: (() -> Void)?

    init(draft: ConnectionAuthenticationDraft, store: AppStore, initialError: String = "") {
        self.draft = draft; self.store = store; error = initialError
    }
    func selectCredential(_ id: UUID?) {
        do {
            try draft.selectCredential(id, workspace: store.workspace, chinese: store.chinese)
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    func submit() {
        do {
            let result = try draft.validatedResult(workspace: store.workspace, chinese: store.chinese)
            try store.rememberConnectionAuthentication(result)
            error = ""
            onConnect?(result)
        } catch { self.error = error.localizedDescription }
    }
}

/// A scoped native modal session keeps Return/Escape and normal file selection
/// working without semaphores or blocking an async task on a continuation.
@MainActor final class ConnectionAuthenticationWindowController: NSObject, NSWindowDelegate {
    let model: ConnectionAuthenticationModel
    private(set) var window: NSWindow?
    private var result: ConnectionAuthenticationResult?
    private var presenting = false
    private var completionRequested = false
    private var modalCompletionTimer: Timer?

    init(draft: ConnectionAuthenticationDraft, store: AppStore, initialError: String = "") {
        model = ConnectionAuthenticationModel(draft: draft, store: store, initialError: initialError)
        super.init()
        model.onConnect = { [weak self] result in self?.finish(result) }
        model.onCancel = { [weak self] in self?.cancel() }
    }
    func present() throws -> ConnectionAuthenticationResult {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 610),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = model.store.text("Connection authentication", "连接认证")
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.background)
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        let view = ConnectionAuthenticationView(model: model).environmentObject(model.store)
        window.contentView = NSHostingView(rootView: view)
        self.window = window
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        } else { window.center() }
        presenting = true
        defer {
            presenting = false
            modalCompletionTimer?.invalidate(); modalCompletionTimer = nil
            window.endEditing(for: nil)
            clearPasswordInputs(in: window.contentView)
            model.draft.secret = ""; model.draft.privateKey = ""
            window.orderOut(nil)
            window.delegate = nil
            window.close()
            self.window = nil
            result = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        guard let result else { throw CancellationError() }
        return result
    }
    private func clearPasswordInputs(in view: NSView?) {
        guard let view else { return }
        if let input = view as? PasswordInputView { input.clearSensitiveText() }
        else { view.subviews.forEach { clearPasswordInputs(in: $0) } }
    }
    func cancel() { finish(nil) }
    private func finish(_ result: ConnectionAuthenticationResult?) {
        guard presenting, !completionRequested, let window else { return }
        completionRequested = true
        self.result = result
        // Stop only this controller's modal window; a key-file panel may be nested.
        if NSApp.modalWindow === window { NSApp.stopModal(withCode: result == nil ? .cancel : .OK) }
        else {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak window] timer in
                guard let self, self.presenting, let window else { timer.invalidate(); return }
                if NSApp.modalWindow === window {
                    NSApp.stopModal(withCode: self.result == nil ? .cancel : .OK)
                    timer.invalidate()
                }
            }
            modalCompletionTimer = timer
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}

struct ConnectionAuthenticationView: View {
    @ObservedObject var model: ConnectionAuthenticationModel
    @EnvironmentObject var store: AppStore

    private var credentialSelection: Binding<UUID?> {
        Binding(get: { model.draft.host.credentialID }, set: { model.selectCredential($0) })
    }
    private var authSelection: Binding<String> {
        Binding(get: { model.draft.host.auth }, set: { value in
            model.draft.host.auth = value
            if value == "key", model.draft.host.keySource == nil, model.draft.host.keyPath.isEmpty { model.draft.host.keySource = "text" }
            model.error = ""
        })
    }
    private var shared: Bool { model.draft.host.credentialID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "key.fill", color: Palette.blue, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.text("Connect to host", "连接主机")).font(.system(size: 16, weight: .semibold))
                    Text("\(model.draft.host.address):\(model.draft.host.port)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 14)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.workspace.credentials.isEmpty {
                        field(store.text("Login credentials", "登录凭据")) {
                            CredentialPicker(selectedID: credentialSelection, credentials: store.workspace.credentials,
                                             chinese: store.chinese, enabled: true, onNew: {}, allowsCreation: false)
                                .frame(height: CredentialPickerButton.fieldHeight)
                        }
                    }
                    field(store.text("Username", "用户名")) {
                        TextField(store.text("Username", "用户名"), text: $model.draft.host.username).appInput().disabled(shared)
                            .accessibilityIdentifier("connection-auth-username")
                    }
                    field(store.text("Authentication", "认证")) {
                        AuthenticationSelector(selection: authSelection, passwordTitle: store.text("Password", "密码"),
                                               keyTitle: store.text("Private key", "私钥"), enabled: !shared)
                    }
                    if model.draft.host.auth == "key" {
                        field(store.text("Private key", "私钥")) {
                            PrivateKeyInput(source: $model.draft.host.keySource, path: $model.draft.host.keyPath,
                                            text: $model.draft.privateKey, savedInKeychain: false, editorHeight: 80, compact: true)
                        }
                    }
                    field(model.draft.host.auth == "key" ? store.text("Passphrase", "私钥口令") : store.text("Password", "密码")) {
                        PreferencesSecureField(title: model.draft.host.auth == "key" ? store.text("Optional for unencrypted keys", "未加密的私钥可留空") : store.text("Enter password", "输入密码"), text: $model.draft.secret,
                                               identifier: "connection-auth-secret", chinese: store.chinese,
                                               focusOnAppear: model.draft.host.auth == "password", onSubmit: model.submit).appInput()
                    }
                    if model.draft.canRemember(in: store.workspace) {
                        Toggle(shared ? store.text("Remember shared credentials in Keychain", "将共享凭据保存到钥匙串") : store.text("Remember credentials for this host", "记住此主机的凭据"), isOn: $model.draft.remember)
                            .toggleStyle(.checkbox).font(.system(size: 12))
                        if shared && model.draft.remember {
                            Text(store.text("Saved changes apply to every host using this shared credential.", "保存后的凭据供所有使用它的主机使用。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    Text(model.draft.remember ? store.text("Secrets are stored in macOS Keychain.", "密码和私钥文本保存在 macOS 钥匙串中。") : store.text("Credentials stay in memory for this session.", "凭据仅保留在本次会话内存中。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
            if !model.error.isEmpty {
                Label(model.error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(hex: "#C42B38"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#C42B38").opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .accessibilityIdentifier("connection-auth-error")
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                Button(store.text("Cancel", "取消")) { model.onCancel?() }
                    .buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("connection-auth-cancel")
                Button { model.submit() } label: { Label(store.text("Connect", "连接"), systemImage: "terminal") }
                    .buttonStyle(ChromeButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("connection-auth-connect")
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(width: 480, height: 610).background(Palette.background).foregroundStyle(Palette.text)
            .onExitCommand { model.onCancel?() }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            content()
        }
    }
}
