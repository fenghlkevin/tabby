import SwiftUI
import AppKit

/// Groups own connection defaults. This inspector shares the host editor's
/// placement and input controls while keeping tag management independent.
struct GroupEditor: View {
    @EnvironmentObject var store: AppStore
    @State var value: HostGroup
    var isNew: Bool
    var done: () -> Void
    @State private var originalName = ""
    @State private var secret = ""
    @State private var privateKeyText = ""
    @State private var secretLoaded = false
    @State private var portValid = true
    @State private var error = ""
    @State private var readAttempt = 0
    @State private var deletionOpen = false
    @State private var editingCredential: VaultCredential?
    @State private var independentCredential: IndependentHostCredentialDraft?
    private var shared: VaultCredential? { store.workspace.credentials.first { $0.id == value.credentialID } }
    private var loadID: String { "\(value.id)-\(value.credentialID?.uuidString ?? "own")-\(readAttempt)" }
    private var routeProbe: Host {
        var host = Host(); host.id = value.id; host.address = "group-defaults.invalid"; host.username = value.username; host.jumpHostID = value.jumpHostID
        return host
    }
    private var canSave: Bool { secretLoaded && portValid && !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? store.text("New group", "新建分组") : store.text("Group details", "分组详情")).font(.system(size: 15, weight: .medium))
                Spacer()
                Button(action: done) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help(store.text("Close details", "关闭详情"))
            }.padding(.horizontal, 18).frame(height: 52)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "folder.fill", size: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.name.isEmpty ? store.text("Unnamed group", "未命名分组") : value.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(store.text("Connection defaults", "连接基础设置")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    field(store.text("Name", "名称")) { TextField(store.text("Group name", "分组名称"), text: $value.name).appInput().accessibilityIdentifier("axon-group-name") }
                    Text(store.text("Hosts can use the group's port, username, authentication and jump host. Changing these defaults applies to future connections; individual overrides are kept.", "分组内的主机可复用端口、用户名、认证和跳板机。修改后用于后续连接，各主机单独设置的值会保留。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Divider().overlay(Palette.border)
                    Text("SSH").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    field(store.text("Port", "端口")) { PortInput(value: $value.port, valid: $portValid, placeholder: "22", label: store.text("Group SSH port", "分组 SSH 端口")) }
                    field(store.text("Login credentials", "登录凭据")) {
                        CredentialPicker(selectedID: Binding(get: { value.credentialID }, set: chooseCredential), credentials: store.workspace.credentials, chinese: store.chinese, enabled: secretLoaded, onNew: newCredential, independentTitle: store.text("Set up for this group", "用于此分组"))
                            .frame(height: CredentialPickerButton.fieldHeight)
                        if let shared {
                            Text(store.text("Uses this shared credential's current username and authentication.", "使用此共享凭据当前的用户名和认证设置。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Button(store.text("Edit shared credential", "编辑共享凭据")) { editingCredential = shared }.buttonStyle(ChromeButtonStyle())
                        } else {
                            Text(store.text("The following login is shared by hosts inheriting this group's authentication.", "以下登录信息供继承此分组认证的主机复用。"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    field(store.text("Username", "用户名")) {
                        TextField(store.text("Username", "用户名"), text: $value.username).appInput().disabled(value.credentialID != nil).accessibilityIdentifier("axon-group-username")
                    }
                    field(store.text("Authentication", "认证")) {
                        AuthenticationSelector(selection: Binding(get: { value.auth }, set: { auth in value.auth = auth; if auth == "key", value.keySource == nil, value.keyPath.isEmpty { value.keySource = "text" } }), passwordTitle: store.text("Password", "密码"), keyTitle: store.text("Private key", "私钥"), enabled: secretLoaded && value.credentialID == nil)
                    }
                    if value.auth == "key" {
                        field(store.text("Private key", "私钥")) {
                            if value.credentialID == nil { PrivateKeyInput(source: $value.keySource, path: $value.keyPath, text: $privateKeyText).disabled(!secretLoaded) }
                            else { Text(value.keySource == "text" ? store.text("Private key from shared credential", "使用共享凭据中的私钥") : value.keyPath).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        }
                    }
                    field(value.auth == "key" ? store.text("Passphrase", "私钥口令") : store.text("Password", "密码")) {
                        PreferencesSecureField(title: store.text("Optional", "可稍后输入"), text: $secret, identifier: "axon-group-secret", chinese: store.chinese).appInput().disabled(!secretLoaded || value.credentialID != nil)
                    }
                    Text(store.text("Passwords and private keys are saved in macOS Keychain.", "密码和私钥保存在 macOS 钥匙串中。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if !secretLoaded {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.text("Reading saved credentials…", "正在读取已保存的凭据…")) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if !error.isEmpty { Button(store.text("Retry", "重试读取")) { readAttempt += 1 }.buttonStyle(ChromeButtonStyle()) }
                    }
                    Divider().overlay(Palette.border)
                    field(store.text("Jump host", "跳板机")) {
                        JumpHostPicker(selection: $value.jumpHostID, host: routeProbe, hosts: store.workspace.hosts.map(store.resolvedHost), chinese: store.chinese).frame(height: 38)
                    }
                    if !isNew {
                        Divider().overlay(Palette.border)
                        Button { deletionOpen = true } label: { Label(store.text("Delete group", "删除分组"), systemImage: "trash") }.buttonStyle(ChromeButtonStyle()).foregroundStyle(.red)
                        Text(store.text("Deleting the group keeps its hosts and their effective connection settings.", "删除分组会保留主机及其实际使用的连接设置。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(18)
            }
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8) }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 10) {
                Button(store.text("Cancel", "取消"), action: done).buttonStyle(ChromeButtonStyle())
                Button(store.text("Save", "保存"), action: save).buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!canSave).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("axon-group-save")
            }.frame(maxWidth: .infinity).padding(16)
        }.accessibilityIdentifier("axon-group-inspector")
            .onAppear { originalName = isNew ? "" : value.name }
            .onChange(of: store.workspace.credentials) { _, _ in if let shared { applyShared(shared) } }
            .sheet(item: $editingCredential) { credential in
                CredentialEditor(value: credential, onSaved: { saved in chooseCredential(saved.id); applyShared(saved) }).environmentObject(store)
            }
            .task(id: loadID) {
                secretLoaded = false; error = ""
                if let shared { applyShared(shared); secretLoaded = true; return }
                if let draft = independentCredential {
                    value.username = draft.username; value.auth = draft.auth; value.keySource = draft.keySource; value.keyPath = draft.keyPath
                    secret = draft.secret; privateKeyText = draft.privateKey; secretLoaded = true; return
                }
                if isNew { secretLoaded = true; return }
                let id = value.id
                do {
                    let saved = try await Task.detached { try Secrets.readCredential(id) }.value
                    guard !Task.isCancelled, value.credentialID == nil else { return }
                    secret = saved.secret; privateKeyText = saved.privateKey; secretLoaded = true
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .alert(store.text("Delete group?", "删除分组？"), isPresented: $deletionOpen) {
                Button(store.text("Cancel", "取消"), role: .cancel) {}
                Button(store.text("Delete", "删除"), role: .destructive) {
                    do { try store.removeGroup(originalName); done() } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text(store.text("The group will be removed. Its hosts and their current connection settings will be kept.", "将删除分组，主机及其当前连接设置会保留。"))
            }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted); content() }
    }
    private func applyShared(_ credential: VaultCredential) {
        value.username = credential.username; value.auth = credential.auth; value.keySource = credential.keySource; value.keyPath = credential.keyPath
    }
    private func chooseCredential(_ id: UUID?) {
        guard value.credentialID != id else { return }
        if value.credentialID == nil, secretLoaded {
            var host = Host(); host.username = value.username; host.auth = value.auth; host.keySource = value.keySource; host.keyPath = value.keyPath
            independentCredential = IndependentHostCredentialDraft(host: host, secret: secret, privateKey: privateKeyText)
        } else if id == nil, independentCredential == nil {
            var host = Host(); host.username = value.username; host.auth = value.auth; host.keySource = value.keySource; host.keyPath = value.keyPath
            independentCredential = IndependentHostCredentialDraft(host: host, secret: "", privateKey: "")
        }
        value.credentialID = id; secretLoaded = false; error = ""
    }
    private func newCredential() {
        var credential = VaultCredential(); credential.username = value.username; credential.auth = value.auth; credential.keyPath = value.keyPath; credential.keySource = value.keySource
        editingCredential = credential
    }
    func save() {
        guard canSave else { return }
        do {
            try store.upsertGroup(value, replacing: originalName.isEmpty ? nil : originalName, secret: secret, privateKey: privateKeyText)
            done()
        } catch { self.error = error.localizedDescription }
    }
}
