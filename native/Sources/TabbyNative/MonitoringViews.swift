import SwiftUI
import Darwin

struct MonitoringTrendPoint: Equatable {
    let timestamp: Date
    let value: Double
}

enum MonitoringPresentation {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var amount = Double(value), unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", amount, units[unit])
    }
    static func percent(_ used: UInt64, _ total: UInt64) -> Double? {
        guard total > 0, used <= total else { return nil }
        return Double(used) / Double(total) * 100
    }
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }
    static func percentage(_ value: Double?) -> String { value.flatMap { $0.isFinite ? number($0) + "%" : nil } ?? "—" }
    static func bytes(_ value: UInt64?) -> String { value.map(bytes) ?? "—" }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(UInt64.max) else { return "—" }
        return bytes(UInt64(value.rounded(.down))) + "/s"
    }
    static func sparklineSamples(_ values: [Double]) -> [Double] { Array(values.filter { $0.isFinite && $0 >= 0 }.suffix(60)) }
    static func trendSamples(_ points: [MonitoringTrendPoint]) -> [MonitoringTrendPoint] {
        var unique: [Date: MonitoringTrendPoint] = [:]
        for point in points where point.value.isFinite && point.value >= 0 && point.timestamp.timeIntervalSinceReferenceDate.isFinite { unique[point.timestamp] = point }
        return Array(unique.values.sorted { $0.timestamp < $1.timestamp }.suffix(60))
    }
    static func trendX(_ point: MonitoringTrendPoint, in points: [MonitoringTrendPoint]) -> Double {
        guard let first = points.first, let last = points.last, last.timestamp > first.timestamp else { return 0 }
        return point.timestamp.timeIntervalSince(first.timestamp) / last.timestamp.timeIntervalSince(first.timestamp)
    }
    static func trendSegments(_ points: [MonitoringTrendPoint]) -> [[MonitoringTrendPoint]] {
        guard let first = points.first else { return [] }
        let gaps = zip(points, points.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }.filter { $0 > 0 }.sorted()
        let typicalGap = gaps.isEmpty ? .infinity : gaps[(gaps.count - 1) / 2]
        var segments = [[first]]
        for (before, after) in zip(points, points.dropFirst()) {
            if after.timestamp.timeIntervalSince(before.timestamp) > typicalGap * 3 { segments.append([after]) }
            else { segments[segments.count - 1].append(after) }
        }
        return segments
    }
    static func addressKind(_ raw: String) -> MonitoringAddressKind? {
        let address = String(raw.split(separator: "/", maxSplits: 1).first ?? "")
        var v4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr), a = ip >> 24, b = ip >> 16 & 255, c = ip >> 8 & 255
            if a == 127 { return .loopback }
            if a == 169 && b == 254 { return .linkLocal }
            if a == 10 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 { return .privateAddress }
            if a == 100 && (64...127).contains(b) { return .shared }
            if a == 0 || a >= 224 || a == 192 && b == 0 && c == 2 || a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return .reserved }
            return .publicAddress
        }
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
            if bytes[0] & 254 == 252 { return .privateAddress }
            if bytes[0] == 254 && bytes[1] & 192 == 128 { return .linkLocal }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
                return addressKind(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            if bytes[0] == 32 && bytes[1] == 1 && bytes[2] == 13 && bytes[3] == 184 { return .reserved }
            return bytes[0] & 224 == 32 ? .publicAddress : .reserved
        }
        return nil
    }
}

enum MonitoringAddressKind: Equatable {
    case privateAddress, publicAddress, shared, loopback, linkLocal, reserved
    @MainActor func title(_ store: AppStore) -> String {
        switch self {
        case .privateAddress: return store.text("Private", "内网")
        case .publicAddress: return store.text("Public", "公网")
        case .shared: return store.text("Shared address space", "共享地址空间")
        case .loopback: return store.text("Loopback", "回环")
        case .linkLocal: return store.text("Link-local", "链路本地")
        case .reserved: return store.text("Reserved", "保留地址")
        }
    }
}

enum MonitoringModule: String, CaseIterable, Identifiable {
    case resources, processes, network, gpu, docker
    var id: Self { self }
    var symbol: String {
        switch self { case .resources: return "square.grid.2x2"; case .processes: return "list.bullet"; case .network: return "network"; case .gpu: return "cpu"; case .docker: return "shippingbox" }
    }
    @MainActor func title(_ store: AppStore) -> String {
        switch self { case .resources: return store.text("Overview", "概览"); case .processes: return store.text("Processes", "进程"); case .network: return store.text("Network & IP", "网络与 IP"); case .gpu: return "GPU"; case .docker: return "Docker" }
    }
}

struct MonitoringVaultView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: MonitoringCenter
    @State private var search = ""
    @State private var gridView = true
    @State private var scope: MonitoringBrowseScope?
    @State private var module = MonitoringModule.resources
    var selected: MonitoringEntry? { center.entries.first { $0.id == center.selectedTargetID } }
    private var catalog: MonitoringBrowseCatalog { MonitoringBrowseCatalog(entries: center.entries, declaredGroups: store.groups, scope: scope, query: search) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let entry = selected {
                    detail(entry)
                } else if center.selectedTargetID != nil {
                    Button { center.select(nil) } label: { Label(store.text("Monitoring overview", "监控概览"), systemImage: "chevron.left") }.buttonStyle(ChromeButtonStyle())
                    MonitoringEmpty(title: store.text("Host unavailable", "主机已不可用"), message: store.text("Return to the overview to choose another host.", "返回概览选择其他主机。"))
                } else {
                    overview
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.background).foregroundStyle(Palette.text)
            .onChange(of: center.selectedTargetID) { _, _ in module = .resources }
            .onChange(of: catalog.groups.map(\.name)) { _, names in
                if case .group(let name) = scope, !CatalogNames.contains(names, name) { scope = nil }
            }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PaneHeading(title: store.text("Monitoring", "监控"), subtitle: store.text("Saved hosts and connected SSH sessions. Read-only.", "已保存主机与已连接的 SSH 会话，只读监控。"))
                Spacer(minLength: 8)
                MonitoringLayoutPicker(grid: $gridView, chinese: store.chinese).frame(width: 70, height: 32)
                Button { for entry in center.entries where entry.isConnected { center.refresh(entry.id) } } label: { Label(store.text("Refresh", "刷新"), systemImage: "arrow.clockwise") }
                    .buttonStyle(ChromeButtonStyle()).disabled(!center.entries.contains { canRefresh($0) })
            }
            VaultSearchField(placeholder: store.text("Search hosts, addresses or groups", "搜索主机、地址或分组"), text: $search)
            if scope != nil || !catalog.search.isEmpty {
                HStack(spacing: 10) {
                    Button { scope = nil; search = "" } label: { Label(store.text("All groups", "全部分组"), systemImage: "chevron.left") }
                        .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("monitoring-groups-back")
                    Text(scopeTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                }
            }
            if catalog.isRootBrowse && !catalog.groups.isEmpty {
                HStack {
                    PaneHeading(title: store.text("Groups", "分组"))
                    Text("\(catalog.groups.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Button { scope = .all } label: { Label(store.text("All hosts", "全部主机"), systemImage: "server.rack") }
                        .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("monitoring-all-hosts")
                }
                LazyVGrid(columns: gridView ? [GridItem(.adaptive(minimum: 280), spacing: 14)] : [GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    ForEach(catalog.groups) { group in
                        MonitoringGroupButton(group: group, chinese: store.chinese) { scope = .group(group.name) }
                            .frame(maxWidth: .infinity).frame(height: 82)
                    }
                }
            }
            let entries = catalog.visibleEntries
            if !entries.isEmpty || !catalog.isRootBrowse || catalog.groups.isEmpty {
                HStack {
                    PaneHeading(title: catalog.isRootBrowse && !catalog.groups.isEmpty ? store.text("Ungrouped hosts", "未分组主机") : store.text("Hosts", "主机"))
                    Text("\(entries.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 4)
                }
                if gridView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(entries) { entry in
                            MonitoringHostCard(entry: entry, snapshot: center.snapshots[entry.id], state: stateText(entry),
                                select: { center.select(entry.id) }, connect: { store.openMonitoringTerminal(entry.id, activate: entry.isConnected) },
                                canConnect: MonitoringTerminalAction.resolve(entry.id, store: store) != nil)
                        }
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            MonitoringHostRow(entry: entry, snapshot: center.snapshots[entry.id], state: stateText(entry),
                                select: { center.select(entry.id) }, connect: { store.openMonitoringTerminal(entry.id, activate: entry.isConnected) },
                                canConnect: MonitoringTerminalAction.resolve(entry.id, store: store) != nil)
                        }
                    }
                }
                if entries.isEmpty {
                    MonitoringEmpty(title: store.text("No matching hosts", "没有匹配的主机"), message: store.text("Add a host to your vault or adjust the search. Monitoring never connects automatically.", "添加主机或调整搜索词后即可查看；监控不会自动连接。"), symbol: "magnifyingglass")
                }
            }
        }
    }
    private var scopeTitle: String {
        if case .group(let name) = scope { return name }
        return catalog.search.isEmpty ? store.text("All hosts", "全部主机") : store.text("Search results", "搜索结果")
    }
    private func stateText(_ entry: MonitoringEntry) -> String {
        guard entry.isConnected else { return store.text("Not connected", "未连接") }
        switch center.states[entry.id] {
        case .collecting: return store.text("Collecting", "正在采集")
        case .paused: return store.text("Paused", "已暂停")
        case .disconnected: return store.text("Not connected", "未连接")
        case .error: return store.text("Collection failed", "采集失败")
        case .unsupported: return store.text("Unsupported", "暂不支持")
        case nil: return store.text("Waiting for sample", "等待采样")
        }
    }
    private func detail(_ entry: MonitoringEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { center.select(nil) } label: { Label(store.text("Monitoring overview", "监控概览"), systemImage: "chevron.left") }.buttonStyle(ChromeButtonStyle())
            HStack(alignment: .top) {
                PaneHeading(title: entry.label, subtitle: entry.address)
                Spacer(minLength: 8)
                MonitoringTerminalButton(entry: entry, chinese: store.chinese, action: { store.openMonitoringTerminal(entry.id, activate: entry.isConnected) })
                    .frame(width: MonitoringTerminalNativeButton.width, height: MonitoringTerminalNativeButton.height).disabled(MonitoringTerminalAction.resolve(entry.id, store: store) == nil)
                Button { center.refresh(entry.id) } label: { Label(store.text("Refresh", "刷新"), systemImage: "arrow.clockwise") }.buttonStyle(ChromeButtonStyle()).disabled(!canRefresh(entry))
            }
            if !entry.isConnected {
                MonitoringEmpty(title: store.text("SSH is not connected", "未连接 SSH"), message: store.text("Click Connect above to connect in the background. Metrics appear here after connecting.", "点击上方“连接”即可在后台登录，连接成功后这里会显示指标。"), symbol: "network.slash")
            } else {
                stateNotice(entry)
                MonitoringModuleNavigation(selection: $module)
                if let snapshot = center.snapshots[entry.id] {
                    HStack { Text(snapshot.os); if let kernel = snapshot.kernel { Text(kernel) }; Spacer(); Text(store.text("Last successful sample", "上次成功采样")); Text(snapshot.timestamp, format: .dateTime.month().day().hour().minute().second()) }.font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    switch module {
                    case .resources: MonitoringResourcesView(snapshot: snapshot, history: center.history[entry.id] ?? [])
                    case .processes: MonitoringProcessesView(snapshot: snapshot)
                    case .network: MonitoringNetworkView(snapshot: snapshot, entry: entry)
                    case .gpu: MonitoringGPUView(snapshot: snapshot)
                    case .docker: MonitoringDockerView(snapshot: snapshot)
                    }
                    Text(store.text("— means this host did not provide a value. Monitoring is read-only.", "— 表示此主机未提供该值；监控仅供查看。"))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    MonitoringEmpty(title: stateText(entry), message: store.text("Metrics appear after the first successful SSH sample.", "首次 SSH 采样成功后会显示指标。"), symbol: "waveform.path")
                }
            }
        }
    }
    @ViewBuilder private func stateNotice(_ entry: MonitoringEntry) -> some View {
        switch center.states[entry.id] {
        case .error(let message), .unsupported(let message): Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
        case .paused:
            Label(center.snapshots[entry.id] == nil
                ? store.text("Sampling paused. Keep this page visible and Axon in the foreground to collect metrics.", "采样已暂停。此页面可见且 Axon 位于前台时开始采集。")
                : store.text("Paused. Displaying the last sample.", "已暂停，显示上次采样。"), systemImage: "pause.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        default: EmptyView()
        }
    }
    private func canRefresh(_ entry: MonitoringEntry) -> Bool {
        entry.isConnected && center.states[entry.id] != .paused && center.states[entry.id] != .disconnected
    }
}

struct MonitoringUnavailable: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    let key: String
    var body: some View {
        let reason = snapshot.availability[key]
        VStack(alignment: .leading, spacing: 5) {
            Text(reason == "Available" ? store.text("No entries", "暂无条目") : store.text("Unavailable", "不可用")).font(.system(size: 12, weight: .medium))
            Text(reason == "Available" ? store.text("No entries returned for this sample.", "此采样未返回条目。") : reason ?? store.text("This host did not provide this metric.", "此主机未提供该指标。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
        }
    }
}

enum MonitoringProcessSort: String, CaseIterable { case pid, command, cpu, memory }
enum MonitoringProcessOrdering {
    static func sorted(_ processes: [MonitoringProcess], by key: MonitoringProcessSort, descending: Bool) -> [MonitoringProcess] {
        processes.sorted { first, second in
            switch key {
            case .command:
                let order = first.command.localizedStandardCompare(second.command)
                return order == .orderedSame ? first.pid < second.pid : (descending ? order == .orderedDescending : order == .orderedAscending)
            case .pid: return descending ? first.pid > second.pid : first.pid < second.pid
            case .cpu, .memory:
                let a = key == .cpu ? first.cpuPercent : first.memoryBytes.map { Double($0) }
                let b = key == .cpu ? second.cpuPercent : second.memoryBytes.map { Double($0) }
                if a == nil || b == nil { return a != nil && b == nil }
                if a == b { return first.pid < second.pid }
                return descending ? a! > b! : a! < b!
            }
        }
    }
}

struct MonitoringProcessesView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    @State private var query = ""
    @State private var sort = MonitoringProcessSort.cpu
    @State private var descending = true
    @State private var selected: MonitoringProcess?
    var visible: [MonitoringProcess] {
        MonitoringProcessOrdering.sorted(snapshot.processes.filter { query.isEmpty || "\($0.pid) \($0.command) \($0.user)".localizedCaseInsensitiveContains(query) }, by: sort, descending: descending)
    }
    var body: some View {
        MonitoringPanel(title: store.text("Processes", "进程"), symbol: "list.bullet") {
            Text(store.text("\(snapshot.processes.count) sampled processes · read-only · CPU is lifetime average", "已采样 \(snapshot.processes.count) 个进程 · 只读 · CPU 为生命周期平均值"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            VaultSearchField(placeholder: store.text("Search processes, PID or user", "搜索进程、PID 或用户"), text: $query)
            if snapshot.processes.isEmpty { MonitoringUnavailable(snapshot: snapshot, key: "processes") }
            else {
                HStack(spacing: 10) {
                    sortButton("PID", .pid).frame(width: 58, alignment: .leading)
                    sortButton(store.text("Process / user", "进程／用户"), .command).frame(maxWidth: .infinity, alignment: .leading)
                    sortButton(store.text("CPU avg", "CPU 平均"), .cpu).frame(width: 82, alignment: .trailing)
                    sortButton(store.text("Memory", "内存"), .memory).frame(width: 82, alignment: .trailing)
                    Color.clear.frame(width: 14, height: 1)
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                Divider()
                ForEach(visible) { process in
                    Button { selected = process } label: {
                        HStack(spacing: 10) {
                            Text(String(process.pid)).frame(width: 58, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.command).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(process.user).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(MonitoringPresentation.percentage(process.cpuPercent)).monospacedDigit().frame(width: 82, alignment: .trailing)
                            Text(MonitoringPresentation.bytes(process.memoryBytes)).monospacedDigit().frame(width: 82, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 14)
                        }.font(.system(size: 11)).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel(store.text("Process details: \(process.command), PID \(process.pid)", "进程详情：\(process.command)，PID \(process.pid)"))
                    Divider()
                }
                if visible.isEmpty { Text(store.text("No matching processes", "没有匹配的进程")).foregroundStyle(Palette.muted).padding(.vertical, 16) }
            }
            ForEach(snapshot.issues.filter { $0.localizedCaseInsensitiveContains("process") }, id: \.self) { issue in Text(issue).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }.sheet(item: $selected) { process in MonitoringProcessDetail(process: process).environmentObject(store) }
    }
    private func sortButton(_ title: String, _ key: MonitoringProcessSort) -> some View {
        Button {
            if sort == key { descending.toggle() } else { sort = key; descending = key == .cpu || key == .memory }
        } label: {
            HStack(spacing: 4) { Text(title); if sort == key { Image(systemName: descending ? "arrow.down" : "arrow.up").font(.system(size: 8)) } }
        }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel(title + (sort == key ? store.text(descending ? ", descending" : ", ascending", descending ? "，降序" : "，升序") : ""))
    }
}

private struct MonitoringProcessDetail: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let process: MonitoringProcess
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            PaneHeading(title: process.command, subtitle: "PID \(process.pid)")
            MonitoringValue(label: store.text("User", "用户"), value: process.user)
            MonitoringValue(label: store.text("State", "状态"), value: process.state)
            MonitoringValue(label: store.text("Threads", "线程"), value: process.threads.map(String.init) ?? "—")
            MonitoringValue(label: store.text("CPU lifetime average", "CPU 生命周期平均值"), value: MonitoringPresentation.percentage(process.cpuPercent))
            MonitoringValue(label: store.text("Memory", "内存"), value: MonitoringPresentation.bytes(process.memoryBytes))
            if let arguments = process.arguments {
                Text(store.text("Arguments (redacted)", "参数（已脱敏）")).font(.system(size: 12, weight: .medium))
                ScrollView { Text(arguments).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(maxHeight: 180).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack { Text(store.text("Read-only snapshot", "只读采样")).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button(store.text("Close", "关闭")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520).background(Palette.sidebar).foregroundStyle(Palette.text)
    }
}

struct MonitoringGPUView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    @State private var selectedID = ""
    var selected: MonitoringGPU? { snapshot.gpus.first { $0.uuid == selectedID } ?? snapshot.gpus.first }
    var body: some View {
        MonitoringPanel(title: "GPU", symbol: "cpu") {
            if let gpu = selected {
                AxonChoiceField(selection: Binding(get: { selected?.uuid ?? "" }, set: { selectedID = $0 }), choices: snapshot.gpus.map { ($0.uuid, "GPU \($0.index) · \($0.name)") }, placeholder: store.text("GPU device", "GPU 设备"), symbol: "cpu", identifier: "axon-gpu-device")
                Text(gpu.name).font(.system(size: 14, weight: .semibold))
                MonitoringValue(label: store.text("Driver", "驱动"), value: gpu.driverVersion ?? "—")
                MonitoringValue(label: store.text("Driver CUDA support", "驱动支持的 CUDA"), value: gpu.cudaVersion ?? "—")
                if gpu.cudaVersion == nil && snapshot.availability["gpuInfo"] != "Available" { MonitoringUnavailable(snapshot: snapshot, key: "gpuInfo") }
                MonitoringMeter(label: store.text("Utilization", "利用率"), percentage: gpu.utilizationPercent)
                if let used = gpu.memoryUsedBytes, let total = gpu.memoryTotalBytes { MonitoringMeter(label: store.text("GPU memory", "显存"), percentage: MonitoringPresentation.percent(used, total), color: .purple) }
                MonitoringValue(label: store.text("Memory used / total", "显存已使用／总量"), value: "\(MonitoringPresentation.bytes(gpu.memoryUsedBytes)) / \(MonitoringPresentation.bytes(gpu.memoryTotalBytes))")
                MonitoringValue(label: store.text("Temperature", "温度"), value: gpu.temperatureCelsius.map { MonitoringPresentation.number($0) + " °C" } ?? "—")
                MonitoringValue(label: store.text("Fan", "风扇"), value: MonitoringPresentation.percentage(gpu.fanPercent))
                MonitoringValue(label: store.text("Power / limit", "功耗／上限"), value: "\(MonitoringPresentation.number(gpu.powerWatts)) / \(MonitoringPresentation.number(gpu.powerLimitWatts)) W")
                Divider()
                Text(store.text("GPU processes", "GPU 进程")).font(.system(size: 13, weight: .semibold))
                let processes = snapshot.gpuProcesses.filter { $0.gpuUUID == gpu.uuid }
                if processes.isEmpty { MonitoringUnavailable(snapshot: snapshot, key: "gpuProcesses") }
                ForEach(processes) { process in MonitoringValue(label: "\(process.pid) · \(process.name)", value: MonitoringPresentation.bytes(process.usedMemoryBytes)) }
            } else { MonitoringUnavailable(snapshot: snapshot, key: "gpus") }
        }
    }
}

struct MonitoringPanel<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    let fillsRow: Bool
    init(title: String, symbol: String, fillsRow: Bool = false, @ViewBuilder content: () -> Content) { self.title = title; self.symbol = symbol; self.fillsRow = fillsRow; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            content
        }.padding(18).frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MonitoringValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Palette.muted)
            Spacer(minLength: 6)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.system(size: 12))
    }
}

struct MonitoringMeter: View {
    let label: String
    let percentage: Double?
    var color = Palette.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonitoringValue(label: label, value: MonitoringPresentation.percentage(percentage))
            GeometryReader { proxy in
                Capsule().fill(Palette.field)
                if let percentage, percentage.isFinite { Capsule().fill(color).frame(width: proxy.size.width * max(0, min(100, percentage)) / 100) }
            }.frame(height: 6).accessibilityHidden(true)
        }.accessibilityElement(children: .combine)
    }
}

private struct MonitoringEmpty: View {
    let title: String
    let message: String
    var symbol = "info.circle"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Palette.muted)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MonitoringSparkline: View {
    let points: [MonitoringTrendPoint]
    let label: String
    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let high = max(1, (points.map(\.value).max() ?? 0) * 1.1)
                Path { path in
                    for segment in MonitoringPresentation.trendSegments(points) {
                        for (index, sample) in segment.enumerated() {
                            let point = CGPoint(x: proxy.size.width * MonitoringPresentation.trendX(sample, in: points), y: proxy.size.height * (1 - sample.value / high))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            path.addEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
                            path.move(to: point)
                        }
                    }
                }.stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }.frame(height: 72)
            HStack {
                if let first = points.first { Text(first.timestamp, format: .dateTime.month().day().hour().minute().second()) }
                Spacer()
                if let last = points.last { Text(last.timestamp, format: .dateTime.month().day().hour().minute().second()) }
            }.font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(points.last.map { MonitoringPresentation.number($0.value) } ?? "—")
    }
}
