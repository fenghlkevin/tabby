import SwiftUI
import AppKit

struct CredentialsView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: VaultCredential?
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                VaultSearchField(placeholder: store.text("Search keys or identities", "搜索私钥或身份"), text: $search)
                HStack {
                    HStack(spacing: 0) {
                        Button { newCredential("key") } label: { Label(store.text("NEW KEY", "新建私钥"), systemImage: "key.fill") }.buttonStyle(ChromeButtonStyle())
                        AppActionMenu {
                            Button(store.text("New key", "新建私钥")) { newCredential("key") }
                            Button(store.text("New identity", "新建身份")) { newCredential("password") }
                        } label: { Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Palette.text).fixedSize().padding(.trailing, 6).accessibilityLabel(store.text("New credential menu", "新建凭据菜单"))
                    }.background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }.padding(12).background(Palette.sidebar)
            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack { PaneHeading(title: store.text("Keychain", "凭据库")); Text(String(store.workspace.credentials.count)).font(.caption).foregroundStyle(Palette.muted); Spacer() }
                    ForEach(store.workspace.credentials.filter { search.isEmpty || "\($0.name) \($0.username)".localizedCaseInsensitiveContains(search) }) { value in
                        HStack {
                            IconTile(symbol: value.auth == "key" ? "key.fill" : "person.fill", color: Palette.blue)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(value.name).font(.headline)
                                Text(value.username + " · " + (value.auth == "key" ? store.text("Private key", "私钥") : store.text("Password", "密码"))).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Text("\(store.workspace.hosts.filter { $0.credentialID == value.id }.count) " + store.text("hosts", "台主机")).foregroundStyle(Palette.muted)
                            Button(store.text("Edit", "编辑")) { editing = value }.buttonStyle(ChromeButtonStyle())
                            Button(store.text("Remove", "移除")) { remove(value) }.buttonStyle(ChromeButtonStyle())
                        }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if store.workspace.credentials.isEmpty {
                        VStack(spacing: 16) {
                            IconTile(symbol: "key.fill", color: Palette.blue, size: 58)
                            Text(store.text("Add your credentials", "添加连接凭据")).font(.system(size: 17, weight: .medium))
                            Text(store.text("Save a key or identity to reuse it across hosts.", "添加私钥或密码身份，供多台主机引用。 ")).foregroundStyle(Palette.muted)
                            Button(store.text("New identity", "新建身份")) { newCredential("password") }.buttonStyle(ChromeButtonStyle())
                        }.frame(maxWidth: .infinity).padding(30)
                    }
                }.padding(22)
            }
        }.sheet(item: $editing) { value in CredentialEditor(value: value).environmentObject(store) }
    }
    func newCredential(_ auth: String) { var value = VaultCredential(); value.auth = auth; if auth == "key" { value.keySource = "text" }; editing = value }
    func remove(_ value: VaultCredential) {
        let alert = AppModalAlert(); alert.messageText = store.text("Remove identity?", "移除此凭据？")
        alert.informativeText = store.text("Linked hosts keep independent copies of the credentials.", "引用它的主机会保留独立凭据，不影响后续连接。")
        alert.addButton(withTitle: store.text("Remove", "移除")); alert.addButton(withTitle: store.text("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn { do { try store.removeCredential(value.id) } catch { store.error = error.localizedDescription } }
    }
}

struct CredentialEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var value: VaultCredential
    var onSaved: ((VaultCredential) -> Void)? = nil
    @State private var secret = ""
    @State private var privateKeyText = ""
    @State private var ready = false
    @State private var loading = false
    @State private var loadFailure = ""
    @State private var loadAttempt = 0
    @State private var error = ""
    private var existing: Bool { store.workspace.credentials.contains { $0.id == value.id } }
    private var validationError: String? {
        do { _ = try ConnectionValidation.credential(value, chinese: store.chinese); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeading(title: existing ? store.text("Edit identity", "编辑凭据身份") : store.text("New identity", "新建凭据身份"))
            TextField(store.text("Name", "名称"), text: $value.name).appInput()
            TextField(store.text("Username", "用户名"), text: $value.username).appInput()
            AuthenticationSelector(selection: $value.auth, passwordTitle: store.text("Password", "密码"),
                                   keyTitle: store.text("Private key", "私钥"), enabled: ready)
                .onChange(of: value.auth) { _, auth in if auth == "key", value.keySource == nil, value.keyPath.isEmpty { value.keySource = "text" } }
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.text("Loading saved credentials…", "正在读取已保存的凭据…")) }
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if !loadFailure.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.text("Could not read the saved credentials. Unlock macOS Keychain and retry. Saving stays disabled to protect the existing secrets.", "无法读取已保存的凭据。请解锁 macOS 钥匙串后重试；读取成功前不能保存，以保护原凭据。"))
                        .font(.caption).foregroundStyle(.red)
                    Text(loadFailure).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                    Button(store.text("Retry loading", "重新读取")) { loadAttempt += 1 }.buttonStyle(ChromeButtonStyle())
                }
            }
            if value.auth == "key" {
                PrivateKeyInput(source: $value.keySource, path: $value.keyPath, text: $privateKeyText).disabled(!ready)
            }
            PreferencesSecureField(title: value.auth == "key" ? store.text("Passphrase (optional)", "私钥口令（可选）") : store.text("Password", "密码"), text: $secret, identifier: "axon-vault-secret", chinese: store.chinese).appInput().disabled(!ready)
            Text(store.text("Updating this identity applies to future connections of all linked hosts.", "修改身份后，所有引用它的主机会在下次连接时使用新凭据。 ")).font(.caption).foregroundStyle(Palette.muted)
            if !error.isEmpty || (validationError != nil && !value.name.isEmpty) {
                Text(error.isEmpty ? (validationError ?? "") : error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle())
                Spacer()
                Button(store.text("Save", "保存")) {
                    guard ready, !loading else { return }
                    do {
                        try store.saveCredential(value, secret: secret, privateKey: privateKeyText)
                        onSaved?(store.workspace.credentials.first { $0.id == value.id } ?? value)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!ready || validationError != nil)
            }
        }.padding(24).frame(width: 500).background(Palette.sidebar).foregroundStyle(Palette.text)
        .task(id: loadAttempt) {
            ready = false; loading = true; loadFailure = ""; error = ""
            // A new identity has no stored secrets to read. Existing identities only
            // become editable after both Keychain values have been read successfully.
            guard existing else {
                if value.auth == "key", value.keySource == nil, value.keyPath.isEmpty { value.keySource = "text" }
                loading = false; ready = true; return
            }
            do {
                let id = value.id; let saved = try await Task.detached { try Secrets.readCredential(id) }.value
                guard !Task.isCancelled else { return }
                secret = saved.secret; privateKeyText = saved.privateKey; ready = true; loading = false
            }
            catch {
                guard !Task.isCancelled else { return }
                loading = false; loadFailure = error.localizedDescription
            }
        }
    }
}
