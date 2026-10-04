import SwiftUI

struct MonitoringTerminalPanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: MonitoringCenter
    let sessionID: UUID?
    var scrollsInternally = true
    private var session: TerminalSession? { store.sessions.first { $0.id == sessionID } }
    private var targetID: MonitoringTargetID? { session.flatMap { center.targetID(for: $0) } }
    private var snapshot: MonitoringSnapshot? { targetID.flatMap { center.snapshots[$0] } }
    @ViewBuilder var body: some View {
        if scrollsInternally { ScrollView { content } }
        else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.text("Host status", "主机状态")).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                if let id = targetID {
                    Button { center.refresh(id) } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(store.text("Refresh status", "刷新状态")).accessibilityLabel(store.text("Refresh status", "刷新状态"))
                        .disabled(!canRefresh(id))
                }
            }
            if let session, session.host != nil, let id = targetID {
                Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                status(center.states[id] ?? .disconnected)
                if let snapshot, snapshot.isSupported {
                    metric(store.text("CPU", "CPU"), value: percent(snapshot.cpu?.usagePercent), color: Palette.accent)
                    metric(store.text("Memory", "内存"), value: percent(snapshot.memory?.usedPercent), color: Color(hex: "#B084E2"))
                    if snapshot.cpu != nil && snapshot.cpu?.usagePercent == nil {
                        Text(store.text("CPU and rates need two consecutive samples.", "CPU 和速率将在连续两次采样后显示。"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    if let load = snapshot.load {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.text("Load · 1 / 5 / 15 min", "负载 · 1 / 5 / 15 分钟")).foregroundStyle(Palette.muted)
                            HStack { Text(String(format: "%.2f", load.oneMinute)); Spacer(); Text(String(format: "%.2f", load.fiveMinutes)); Spacer(); Text(String(format: "%.2f", load.fifteenMinutes)) }.monospacedDigit()
                        }.padding(12).background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let memory = snapshot.memory {
                        summary(store.text("Used / total", "已用 / 总内存"), value: bytes(memory.usedBytes) + " / " + bytes(memory.totalBytes))
                        summary("Swap", value: bytes(memory.swapUsedBytes) + " / " + bytes(memory.swapTotalBytes))
                    }
                    if let network = snapshot.interfaces.first(where: { $0.name != "lo" }) {
                        Divider().overlay(Color.white.opacity(0.1))
                        Text(network.name).foregroundStyle(Palette.muted)
                        summary(store.text("Upload", "上传"), value: rate(network.transmitBytesPerSecond))
                        summary(store.text("Download", "下载"), value: rate(network.receiveBytesPerSecond))
                    }
                    if !snapshot.processes.isEmpty {
                        Divider().overlay(Color.white.opacity(0.1))
                        Text(store.text("Processes · CPU average", "进程 · CPU 平均")).foregroundStyle(Palette.muted)
                        ForEach(snapshot.processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }.prefix(3)) { process in
                            summary(process.command, value: percent(process.cpuPercent))
                        }
                    }
                    HStack { Text(store.text("Last successful sample", "上次成功采样")); Text(snapshot.timestamp, style: .time) }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else if let snapshot, !snapshot.isSupported {
                    Text(store.text("This host runs \(snapshot.os). Monitoring currently supports Linux.", "此主机运行 \(snapshot.os)，当前监控支持 Linux。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if session.connected {
                    Text(store.text("Waiting for a sample. Sampling runs while this panel is visible and Axon is in the foreground.", "等待采样。此面板可见且 Axon 位于前台时采集。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    Text(store.text("Connect this SSH session to view its status.", "连接此 SSH 会话后可查看状态。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Button {
                    center.select(id)
                    store.section = "monitoring"
                } label: { Label(store.text("View details", "查看详情"), systemImage: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(store.text("Status is available for connected Linux SSH sessions. Select a remote terminal to view it here.", "状态面板用于已连接的 Linux SSH 会话。选择远程终端后可在这里查看。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func status(_ state: MonitoringState) -> some View {
        switch state {
        case .collecting: Label(store.text("Monitoring · about every 5 s", "监控中 · 约每 5 秒"), systemImage: "waveform.path.ecg").foregroundStyle(Palette.accent)
        case .paused: Label(store.text("Sampling paused", "采样已暂停"), systemImage: "pause.circle").foregroundStyle(Palette.muted)
        case .disconnected: Label(store.text("SSH disconnected", "SSH 未连接"), systemImage: "circle").foregroundStyle(Palette.muted)
        case .error(let message): Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color(hex: "#F39E74")).fixedSize(horizontal: false, vertical: true)
        case .unsupported(let message): Label(message, systemImage: "info.circle").foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func summary(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(Palette.muted).lineLimit(1); Spacer(minLength: 8); Text(value).monospacedDigit().lineLimit(1) }
    }
    private func metric(_ title: String, value: String, color: Color) -> some View {
        HStack { Text(title).foregroundStyle(Palette.muted); Spacer(); Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit().foregroundStyle(color) }
            .padding(12).background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func canRefresh(_ id: MonitoringTargetID) -> Bool {
        switch center.states[id] {
        case .paused, .disconnected, nil: return false
        default: return true
        }
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
    }
    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(UInt64(min(value, Double(Int64.max)))) + "/s"
    }
}
