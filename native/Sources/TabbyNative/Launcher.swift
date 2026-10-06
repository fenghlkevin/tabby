import SwiftUI

/// Browsing shows folders; searching lists matching hosts directly.
struct LauncherCatalog {
    let hosts: [Host]
    let groups: [String]
    let query: String
    let selectedGroup: String?
    var workspace: Workspace? = nil
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    func matches(_ host: Host) -> Bool {
        let username = workspace.map { RecentTargets.effectiveUsername(host, workspace: $0) } ?? host.username
        return search.isEmpty || "\(host.name) \(host.address) \(username) \(host.tags) \(host.group)".localizedCaseInsensitiveContains(search)
    }
    var visibleGroups: [String] {
        guard selectedGroup == nil, search.isEmpty else { return [] }
        return Array(Set(groups + hosts.map(\.group))).filter { !$0.isEmpty }
            .filter { group in search.isEmpty || group.localizedCaseInsensitiveContains(search) || hosts.contains { $0.group == group && matches($0) } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var visibleHosts: [Host] {
        hosts.filter { host in
            (selectedGroup.map { host.group == $0 } ?? (search.isEmpty ? host.group.isEmpty : true)) && matches(host)
        }.sorted {
            ($0.name.isEmpty ? $0.address : $0.name).localizedStandardCompare($1.name.isEmpty ? $1.address : $1.name) == .orderedAscending
        }
    }
    func count(in group: String) -> Int { hosts.filter { $0.group == group }.count }
}

func parseLauncherQuickHost(_ query: String) -> Host? {
    if var host = parseQuickHost(query) {
        guard let address = try? ConnectionValidation.address(host.address) else { return nil }
        host.address = address
        return host
    }
    var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let explicitSSH = words.first == "ssh"
    if explicitSSH { words.removeFirst() }
    guard words.count == 1 || (words.count == 3 && words[1] == "-p"), let address = words.first,
          validQuickAddress(address), explicitSSH || address == "localhost" || address.contains(".") || address.contains(":") else { return nil }
    var host = Host(); host.address = (try? ConnectionValidation.address(address)) ?? address; host.name = host.address; host.username = "root"
    if words.count == 3 { guard let port = ConnectionValidation.integer(words[2], range: 1...65535) else { return nil }; host.port = port }
    return host
}

func validQuickAddress(_ address: String) -> Bool {
    (try? ConnectionValidation.address(address)) != nil
}

struct LauncherView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var selectedGroup: String?
    @State private var quickConnectOpen = false
    @State private var showRecentFiles = false
    @FocusState private var searchFocused: Bool
    var catalog: LauncherCatalog { LauncherCatalog(hosts: store.workspace.hosts, groups: store.groups, query: query, selectedGroup: selectedGroup, workspace: store.workspace) }
    var sessions: [TerminalSession] { store.sessions.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) } }
    var quickHost: Host? { parseLauncherQuickHost(query) }
    var recent: [RecentTarget] {
        store.recentTargets.filter { (showRecentFiles || !$0.kind.isFiles) && (query.isEmpty || (store.recentTitle($0) + " " + store.recentSubtitle($0)).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(store.text("Search groups, hosts or enter user@host", "搜索分组、主机，或输入 user@host"), text: $query)
                    .accessibilityIdentifier("axon-launcher-search").textFieldStyle(.plain).focused($searchFocused).onSubmit(activateFirstResult)
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted).accessibilityLabel(store.text("Clear search", "清除搜索")).accessibilityIdentifier("axon-launcher-clear-search")
                }
            }.padding(.horizontal, 14).frame(height: 40).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border, lineWidth: 1))
                .padding(.top, 30)
            HStack(spacing: 12) {
                Button { store.connect() } label: { Label(store.text("Local terminal", "本地终端"), systemImage: "terminal") }.buttonStyle(ChromeButtonStyle(prominent: true, accentColor: Palette.localTerminal))
                Button { quickConnectOpen = true } label: { Label(store.text("Quick connect", "快速连接"), systemImage: "bolt") }.buttonStyle(ChromeButtonStyle())
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if selectedGroup == nil { WorkSceneLibrary(query: query).padding(.bottom, 10) }
                    if selectedGroup == nil && !store.recentTargets.isEmpty {
                        HStack(spacing: 8) {
                            Text(store.text("Recently opened", "最近打开")).font(.system(size: 12, weight: .medium))
                            Text(store.text("Up to 5 per type · Last 7 days", "每类最多 5 项 · 最近 7 天")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            Spacer()
                            PreferencesActionButton(title: (showRecentFiles ? "✓ " : "") + "SFTP", identifier: "recent-files-filter", prominent: showRecentFiles) { showRecentFiles.toggle() }
                                .frame(width: 76, height: 28)
                                .accessibilityLabel(store.text("Show SFTP", "显示 SFTP"))
                                .accessibilityValue(showRecentFiles ? store.text("On", "已开启") : store.text("Off", "已关闭"))
                                .help(store.text("SSH stays visible. Includes local file browsing.", "SSH 始终显示，同时显示本地文件记录。"))
                            Button(store.text("Clear", "清空")) { store.clearRecent() }.buttonStyle(ChromeButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.padding(.vertical, 4)
                        if recent.isEmpty {
                            Text(store.text("No recent SSH connections", "暂无最近 SSH 连接")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.vertical, 10)
                        }
                        ForEach(recent) { target in
                            HStack(spacing: 6) {
                                Button { store.openRecent(target) } label: {
                                    HStack(spacing: 10) {
                                        IconTile(symbol: target.kind.isFiles ? "folder" : "terminal", color: (target.kind == .localTerminal || target.kind == .localFiles) ? Palette.localTerminal : (target.kind.isFiles ? Palette.sftp : Palette.blue), size: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 8) {
                                                Text(store.recentTypeTitle(target))
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(target.kind.isFiles ? Palette.sftp : Palette.blue)
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background((target.kind.isFiles ? Palette.sftp : Palette.blue).opacity(0.12))
                                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                                    .fixedSize()
                                                Text(store.recentTitle(target)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            }
                                            Text(store.recentSubtitle(target)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Text(target.lastOpened, style: .relative).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(AxonSurfaceButtonStyle())
                                Button { store.removeRecent(target) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 30) }
                                    .buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted).help(store.text("Remove from recent", "从最近打开中移除"))
                            }.padding(.horizontal, 10).padding(.vertical, 7).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                                .appContextMenu { Button(store.text("Remove from recent", "从最近打开中移除")) { store.removeRecent(target) } }
                        }
                        Divider().padding(.vertical, 6)
                    }
                    if let host = quickHost {
                        Button { store.connectQuick(host) } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: "bolt", color: Palette.blue, size: 32)
                                VStack(alignment: .leading, spacing: 4) { Text(store.text("Connect now", "立即连接")); Text("\(host.username)@\(host.address):\(host.port)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                Spacer(); Image(systemName: "return").foregroundStyle(Palette.muted)
                            }.padding(12).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        }.buttonStyle(AxonSurfaceButtonStyle()).padding(.bottom, 8)
                    }
                    if let group = selectedGroup {
                        HStack(spacing: 10) {
                            Button { selectedGroup = nil; searchFocused = true } label: { Label(store.text("All groups", "全部分组"), systemImage: "chevron.left") }.buttonStyle(ChromeButtonStyle())
                            Image(systemName: "folder.fill").foregroundStyle(Palette.blue)
                            Text(group).font(.system(size: 14, weight: .semibold)); Spacer()
                            Text(String(catalog.visibleHosts.count)).foregroundStyle(Palette.muted)
                        }.padding(.bottom, 6)
                    } else if !catalog.visibleGroups.isEmpty {
                        heading(store.text("Groups", "分组"), count: catalog.visibleGroups.count)
                        LazyVStack(spacing: 8) {
                            ForEach(catalog.visibleGroups, id: \.self) { group in
                                Button { selectedGroup = group; searchFocused = true } label: {
                                    HStack(spacing: 12) {
                                        IconTile(symbol: "folder.fill", color: Palette.blue, size: 34)
                                        VStack(alignment: .leading, spacing: 4) { Text(group).font(.system(size: 13, weight: .medium)).lineLimit(1); Text("\(catalog.count(in: group)) " + store.text("hosts", "台主机")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                        Spacer(minLength: 2); Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                                }.buttonStyle(AxonSurfaceButtonStyle())
                            }
                        }.padding(.bottom, 12)
                    }
                    if !catalog.visibleHosts.isEmpty {
                        if selectedGroup == nil { heading(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? store.text("Ungrouped hosts", "未分组主机") : store.text("Matching hosts", "匹配的主机"), count: catalog.visibleHosts.count) }
                        ForEach(catalog.visibleHosts) { host in
                            Button { store.connect(host) } label: {
                                HStack(spacing: 12) { IconTile(symbol: "server.rack", color: Palette.blue, size: 32); Text(host.name.isEmpty ? host.address : host.name).lineLimit(1); Spacer(); Text(host.address).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1) }
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle()).help(store.text("Connect with one click", "单击连接"))
                        }
                    }
                    if catalog.visibleHosts.isEmpty && catalog.visibleGroups.isEmpty && quickHost == nil && (selectedGroup != nil || recent.isEmpty) {
                        Text(selectedGroup != nil && query.isEmpty ? store.text("This group is empty", "此分组暂无主机") : store.text("No matching hosts or groups", "没有符合条件的主机或分组"))
                            .foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    if !sessions.isEmpty {
                        heading(store.text("Open sessions", "已打开的会话"), count: sessions.count).padding(.top, 16)
                        ForEach(sessions) { session in
                            Button { store.activeSession = session.id; store.showTerminalSection() } label: {
                                Label(session.displayTitle, systemImage: "terminal").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle())
                        }
                    }
                }.padding(.bottom, 24)
            }
        }.frame(maxWidth: 680).padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: store.launcherRequest) {
                query = ""; selectedGroup = nil; store.pruneRecentTargets()
                // Focus after the tab button's native click has finished assigning its responder.
                await Task.yield()
                if !Task.isCancelled { searchFocused = true }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    store.pruneRecentTargets()
                }
            }
            .sheet(isPresented: $quickConnectOpen) { QuickConnectView(initial: quickHost).environmentObject(store) }
    }
    func heading(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .medium)); Text(String(count)).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer() }.padding(.vertical, 4)
    }
    func activateFirstResult() {
        if let host = quickHost { store.connectQuick(host) }
        else if let group = catalog.visibleGroups.first { selectedGroup = group }
        else if let host = catalog.visibleHosts.first { store.connect(host) }
        else if let session = sessions.first { store.activeSession = session.id; store.showTerminalSection() }
    }
}

struct QuickConnectView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var portValid = true
    @State private var addressEdited = false
    @FocusState private var addressFocused: Bool
    init(initial: Host?) { var value = initial ?? Host(); if initial == nil { value.username = "root" }; _host = State(initialValue: value) }
    var validationMessage: String? {
        do { _ = try ConnectionValidation.host(host, workspace: store.workspace, chinese: store.chinese); return nil }
        catch { return error.localizedDescription }
    }
    var valid: Bool { portValid && validationMessage == nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "bolt.fill", color: Palette.blue, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.text("Quick connect", "快速连接")).font(.system(size: 16, weight: .semibold))
                    Text(store.text("Open a temporary SSH session", "打开临时 SSH 会话")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }.padding(24).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel(store.text("Hostname or IP address", "主机名或 IP 地址"), required: true)
                    TextField(store.text("e.g. server.example.com", "例如 server.example.com"), text: $host.address).appInput().focused($addressFocused)
                        .accessibilityIdentifier("axon-quick-address").onChange(of: host.address) { _, _ in addressEdited = true }
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("Username", "用户名"), required: true)
                        TextField(store.text("Username", "用户名"), text: $host.username).appInput().disabled(host.credentialID != nil)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(store.text("Port", "端口"), required: true)
                        PortInput(value: $host.port, valid: $portValid, label: store.text("Port", "端口"))
                    }.frame(width: 100)
                }
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel(store.text("Identity", "凭据"))
                    AxonChoiceField(selection: $host.credentialID,
                        choices: [(Optional<UUID>.none, store.text("Enter password on connect", "连接时输入密码"))] + store.workspace.credentials.map { (Optional($0.id), $0.name) },
                        placeholder: store.text("Choose identity", "选择凭据"), symbol: "key", identifier: "axon-quick-identity")
                        .onChange(of: host.credentialID) { _, id in
                            if let credential = store.workspace.credentials.first(where: { $0.id == id }) { host.username = credential.username }
                        }
                }
                Label(store.text("This session will not be added to your host vault.", "此会话不会添加到主机库。"), systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if (addressEdited || !host.address.isEmpty), let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("axon-quick-validation")
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button(store.text("Cancel", "取消")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    guard valid else { return }
                    host.name = host.address
                    if store.connectQuick(host) { dismiss() }
                } label: { Label(store.text("Connect", "连接"), systemImage: "terminal") }
                    .buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!valid).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("axon-quick-connect")
            }.padding(24).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 440, height: 520).background(Palette.sidebar).foregroundStyle(Palette.text)
            .task { await Task.yield(); if !Task.isCancelled { addressFocused = true } }
    }
    private func fieldLabel(_ title: String, required: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if required { Text(store.text("Required", "必填")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }
    }
}
