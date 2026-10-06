import SwiftUI
import AppKit

struct SSHAgentHostFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var host: Host
    @State private var identities: [AgentIdentity] = []
    @State private var checking = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.text("Agent socket · optional", "Agent Socket · 可选")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField(store.text("Use SSH_AUTH_SOCK", "默认使用 SSH_AUTH_SOCK"), text: Binding(get: { host.agentSocketPath ?? "" }, set: { host.agentSocketPath = $0.isEmpty ? nil : $0; identities = []; message = "" })).appInput()
            HStack(spacing: 10) {
                Button(store.text("Read agent identities", "读取 Agent 身份")) { check() }.buttonStyle(ChromeButtonStyle()).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            AxonChoiceField(selection: $host.agentFingerprint, choices: [(nil, store.text("Try available keys", "依次尝试可用密钥"))] + identities.map { (Optional($0.fingerprint), ($0.comment.isEmpty ? "Ed25519" : $0.comment) + " · " + $0.fingerprint) } + (host.agentFingerprint.flatMap { saved in identities.contains { $0.fingerprint == saved } ? nil : [(Optional(saved), saved)] } ?? []), placeholder: store.text("Agent identity", "Agent 身份"), symbol: "key", identifier: "axon-agent-identity")
            Text(store.text("Ed25519 / RSA-SHA2 identities. Private keys stay in your agent; Axon requests signatures. Forwarding is configured separately.", "支持 Ed25519／RSA-SHA2 身份，私钥留在 Agent 中，Axon 仅请求签名。转发需单独开启。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(identities.isEmpty ? Palette.danger : Palette.muted).textSelection(.enabled) }
        }
    }
    private func check() {
        guard !checking else { return }; checking = true; message = ""
        let snapshot = host
        Task { @MainActor in
            defer { checking = false }
            do {
                let keys = try await Task.detached { try AgentWire.identities(path: AgentWire.socketPath(snapshot)) }.value
                guard host.agentSocketPath == snapshot.agentSocketPath else { return }
                identities = keys; message = keys.isEmpty ? store.text("No supported identities. Add a key to your agent with ssh-add.", "未找到可用身份，请使用 ssh-add 添加密钥。") : store.text("\(keys.count) identities available", "找到 \(keys.count) 个可用身份")
            } catch { message = error.localizedDescription }
        }
    }
}

enum SSHConnectionDiagnostics {
    static func command(_ host: Host, workspace: Workspace) -> String {
        let host = GroupDefaults.resolved(host, workspace: workspace)
        var parts = ["ssh", "-p", String(host.port)]
        if host.auth == "key", host.keySource != "text", !host.keyPath.isEmpty { parts += ["-i", SnippetParameters.shellArgument(NSString(string: host.keyPath).expandingTildeInPath)] }
        if host.auth == "agent", let path = try? AgentWire.socketPath(host) { parts += ["-o", SnippetParameters.shellArgument("IdentityAgent=" + path)] }
        var hops: [String] = [], next = host.jumpHostID, seen: Set<UUID> = [host.id]
        while let id = next, seen.insert(id).inserted, let raw = workspace.hosts.first(where: { $0.id == id }) {
            let hop = GroupDefaults.resolved(raw, workspace: workspace)
            let address = hop.address.contains(":") ? "[\(hop.address)]" : hop.address
            hops.insert("\(hop.username)@\(address):\(hop.port)", at: 0); next = hop.jumpHostID
        }
        if !hops.isEmpty { parts += ["-J", SnippetParameters.shellArgument(hops.joined(separator: ","))] }
        parts += [SnippetParameters.shellArgument("\(host.username)@\(host.address)")]
        return parts.joined(separator: " ")
    }
}
struct SSHDiagnosticsControl: View {
    @EnvironmentObject var store: AppStore
    let host: Host
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label(store.text("Connection diagnostics", "连接诊断"), systemImage: "stethoscope") }.buttonStyle(ChromeButtonStyle()).disabled(host.address.isEmpty)
            .sheet(isPresented: $showing) { SSHDiagnosticsSheet(host: host).environmentObject(store) }
    }
}
struct SSHDiagnosticsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let host: Host
    private var validationError: String? {
        do { _ = try ConnectionValidation.host(host, workspace: store.workspace, chinese: store.chinese); return nil } catch { return error.localizedDescription }
    }
    private var session: TerminalSession? { store.sessions.last { $0.host?.id == host.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { IconTile(symbol: "stethoscope", size: 40); PaneHeading(title: store.text("SSH connection diagnostics", "SSH 连接诊断"), subtitle: host.name.isEmpty ? host.address : host.name); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(store.text("Connection profile", "连接配置")) {
                        row(store.text("Endpoint", "地址"), "\(host.username)@\(host.address):\(host.port)")
                        row(store.text("Authentication", "认证"), host.auth == "agent" ? "SSH Agent · Ed25519 / RSA-SHA2" : host.auth == "key" ? "OpenSSH Ed25519 / RSA" : store.text("Password", "密码"))
                        row(store.text("Jump route", "跳板路线"), BatchTargetSnapshot(host, workspace: store.workspace).route.map { "\($0.username)@\($0.address):\($0.port)" }.joined(separator: " → "))
                        if let session { row(store.text("Current status", "当前状态"), session.status) }
                        if let error = validationError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger) }
                        else { Label(store.text("Profile fields are valid", "配置字段有效"), systemImage: "checkmark.circle").foregroundStyle(Palette.accent) }
                    }
                    section(store.text("Compare with system OpenSSH", "使用系统 OpenSSH 对照")) {
                        Text(SSHConnectionDiagnostics.command(host, workspace: store.workspace)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(store.text("Copy command", "复制命令")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SSHConnectionDiagnostics.command(host, workspace: store.workspace), forType: .string) }.buttonStyle(ChromeButtonStyle())
                        Text(store.text("Run manually in a local shell. It uses OpenSSH's own trust and authentication; pasted private keys and saved passwords are not exported. Jump hosts may need additional ~/.ssh/config settings.", "请手动在本地 Shell 执行，使用 OpenSSH 自己的信任与认证。不会导出粘贴的私钥或保存的密码；跳板认证可能需要补充 ~/.ssh/config。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    section(store.text("Troubleshooting", "排查建议")) {
                        guidance("network", store.text("Timeout / connection refused", "超时／拒绝连接"), store.text("Check address, port, VPN and firewall; validate each jump host separately.", "检查地址、端口、VPN 与防火墙，逐台验证跳板连接。"))
                        guidance("key", store.text("Authentication rejected", "认证被拒绝"), store.text("Check username and authorized_keys. For Agent, confirm ssh-add -l shows an Ed25519 key and the socket is available to Axon.", "检查账号与 authorized_keys；使用 Agent 时确认 ssh-add -l 中有 Ed25519 密钥，且 Axon 可访问 Socket。"))
                        guidance("lock.shield", store.text("Host key changed", "主机密钥变化"), store.text("Verify the new fingerprint independently before removing the old trust record in Known hosts.", "独立核实新指纹后，再在已知主机中移除旧信任记录。"))
                        guidance("gearshape.2", store.text("Algorithm / enterprise authentication", "算法／企业认证"), store.text("Prefer Ed25519/ECDSA server host keys. RSA-SHA2, OpenSSH user certificates and selected-identity Agent forwarding are supported. PKCS#11, keyboard-interactive and ProxyCommand remain unavailable.", "优先使用 Ed25519／ECDSA 服务器主机密钥。已支持 RSA-SHA2、OpenSSH 用户证书与指定身份 Agent 转发；尚不提供 PKCS#11、键盘交互认证与 ProxyCommand。"))
                    }
                }.padding(20)
            }
            Divider()
            HStack { Text(store.text("Local checks only; opening this panel does not connect", "仅检查本机配置，打开面板不会发起连接")).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button(store.text("Done", "完成")) { dismiss() }.buttonStyle(ChromeButtonStyle(prominent: true)) }.padding(20)
        }.frame(width: 720, height: 700).background(Palette.card).foregroundStyle(Palette.text).font(.system(size: 12))
    }
    private func section<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 13, weight: .semibold)); content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 10)) }
    private func row(_ label: String, _ value: String) -> some View { HStack(alignment: .top, spacing: 14) { Text(label).foregroundStyle(Palette.muted).frame(width: 100, alignment: .leading); Text(value.isEmpty ? store.text("None", "无") : value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    private func guidance(_ icon: String, _ title: String, _ body: String) -> some View { HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 18); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(body).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) } } }
}

struct SSHCompatibilityFields: View {
    @EnvironmentObject var store: AppStore
    @Binding var host: Host
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if host.auth != "password" || host.certificatePath != nil {
                Toggle(store.text("Use an OpenSSH user certificate", "使用 OpenSSH 用户证书"), isOn: Binding(get: { host.certificatePath != nil }, set: { host.certificatePath = $0 ? "" : nil; if !$0 { host.certificateAuthorityPath = nil } })).toggleStyle(AxonCheckboxStyle())
                if host.certificatePath != nil {
                    certificateFile(store.text("User certificate", "用户证书"), path: $host.certificatePath, identifier: "axon-user-certificate")
                    certificateFile(store.text("Trusted CA public key", "受信 CA 公钥"), path: $host.certificateAuthorityPath, identifier: "axon-certificate-ca")
                    Text(store.text("Choose the CA public key from your administrator. Axon checks signature, validity, principal and key pairing; the server also applies its CA policy.", "选择管理员提供的 CA 公钥。Axon 校验证书签名、有效期、登录身份和密钥配对；服务器仍按其 CA 策略验证。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            certificateFile(store.text("Host certificate CA · optional", "服务器证书 CA · 可选"), path: $host.hostCertificateAuthorityPath, identifier: "axon-host-certificate-ca")
            Text(store.text("With a host CA, server certificates must match the address and be valid. Raw host keys still use fingerprint confirmation.", "配置服务器 CA 后，服务器证书须匹配连接地址并在有效期内。普通主机密钥仍需确认指纹。" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Toggle(store.text("Forward a selected SSH Agent identity", "转发指定 SSH Agent 身份"), isOn: Binding(get: { host.forwardAgent == true }, set: { host.forwardAgent = $0 })).toggleStyle(AxonCheckboxStyle())
            if host.forwardAgent == true {
                Text(store.text("Trusted hosts can request signatures with the chosen identity while this terminal is connected. Forwarding is off by default; choose one identity below.", "连接期间，受信主机可用所选身份请求签名。默认关闭转发，请在下方明确选择一个身份。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if host.auth != "agent" { SSHAgentHostFields(host: $host) }
                if host.agentFingerprint == nil { Label(store.text("Choose one Agent identity for forwarding", "请选择一个要转发的 Agent 身份"), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }
        }
    }
    private func certificateFile(_ title: String, path: Binding<String?>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                TextField(store.text("Choose a public key file", "选择公钥文件"), text: Binding(get: { path.wrappedValue ?? "" }, set: { path.wrappedValue = $0 })).appInput().accessibilityIdentifier(identifier)
                Button(store.text("Choose", "选择")) { let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; if panel.runModal() == .OK { path.wrappedValue = panel.url?.path } }.buttonStyle(ChromeButtonStyle())
            }
        }
    }
}
