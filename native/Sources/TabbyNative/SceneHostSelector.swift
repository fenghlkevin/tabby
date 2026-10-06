import SwiftUI

struct SceneHostSelector: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: UUID?
    @State private var opened = false
    @State private var query = ""
    @State private var group = ""
    private var host: Host? { store.workspace.hosts.first { $0.id == selection } }
    private var hosts: [Host] { store.workspace.hosts.filter { (group.isEmpty || $0.group == group) && (query.isEmpty || "\($0.name) \($0.address) \($0.username)".localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        Button { opened.toggle() } label: {
            HStack(spacing: 8) { Image(systemName: selection == nil ? "desktopcomputer" : "server.rack").foregroundStyle(selection == nil ? Palette.localTerminal : Palette.blue); Text(host.map { $0.name.isEmpty ? $0.address : $0.name } ?? (selection == nil ? store.text("Local terminal", "本地终端") : store.text("Host unavailable", "主机已移除"))).lineLimit(1); Spacer(minLength: 0); Image(systemName: "chevron.down").font(.system(size: 10)) }.padding(.horizontal, 12).frame(height: 38).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(AxonSurfaceButtonStyle()).popover(isPresented: $opened, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.text("Select connection", "选择连接目标")).font(.headline)
                VaultSearchField(placeholder: store.text("Search host name or address", "搜索主机名称或地址"), text: $query)
                AxonChoiceField(selection: $group, choices: [("", store.text("All groups", "全部分组"))] + store.groups.map { ($0, $0) }, placeholder: store.text("All groups", "全部分组"), symbol: "folder", identifier: "axon-scene-host-group")
                ScrollView {
                    LazyVStack(spacing: 6) {
                        choice(id: nil, title: store.text("Local terminal", "本地终端"), detail: store.text("Shell on this Mac", "当前 Mac 的 Shell"))
                        ForEach(hosts) { host in choice(id: host.id, title: host.name.isEmpty ? host.address : host.name, detail: "\(host.username)@\(host.address) · \(host.group)") }
                        if hosts.isEmpty { Text(store.text("No matching hosts", "没有匹配的主机")).font(.caption).foregroundStyle(Palette.muted).padding(12) }
                    }
                }.frame(height: 260)
            }.padding(16).frame(width: 340).background(Palette.sidebar).foregroundStyle(Palette.text)
        }
    }
    private func choice(id: UUID?, title: String, detail: String) -> some View {
        Button { selection = id; opened = false } label: {
            HStack(spacing: 10) { IconTile(symbol: id == nil ? "desktopcomputer" : "server.rack", color: id == nil ? Palette.localTerminal : Palette.blue, size: 28); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1) }; Spacer(); if selection == id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(selection == id ? Palette.selected : Palette.card).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(AxonSurfaceButtonStyle())
    }
}
