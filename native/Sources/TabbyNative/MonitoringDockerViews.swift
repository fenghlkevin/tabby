import SwiftUI
import AppKit

enum MonitoringContainerPresentation {
    /// Docker reports paused and restarting as distinct states. They are not
    /// actively running; human-readable status text must not override state.
    static func isRunning(_ container: MonitoringContainer) -> Bool {
        container.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running"
    }
    static func visible(_ containers: [MonitoringContainer], hideNotRunning: Bool) -> [MonitoringContainer] {
        hideNotRunning ? containers.filter(isRunning) : containers
    }
}

struct MonitoringDockerView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    @State private var selected: MonitoringContainer?
    @State private var hideNotRunning = false
    private var visible: [MonitoringContainer] { MonitoringContainerPresentation.visible(snapshot.containers, hideNotRunning: hideNotRunning) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.containers.isEmpty { MonitoringPanel(title: "Docker", symbol: "shippingbox") { MonitoringUnavailable(snapshot: snapshot, key: "containers") } }
            else {
                HStack {
                    Text(store.text("\(snapshot.containers.count) sampled containers · read-only", "已采样 \(snapshot.containers.count) 个容器 · 只读" )).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 10)
                    Toggle(store.text("Hide not running", "隐藏未运行容器"), isOn: $hideNotRunning).toggleStyle(.checkbox).font(.system(size: 12))
                        .accessibilityIdentifier("axon-docker-hide-not-running")
                }
                if hideNotRunning { Text(store.text("Showing \(visible.count) running containers", "显示 \(visible.count) 个运行中容器")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                if snapshot.availability["containerStats"] != "Available" { MonitoringUnavailable(snapshot: snapshot, key: "containerStats") }
                if visible.isEmpty { MonitoringPanel(title: store.text("No running containers", "暂无运行中的容器"), symbol: "shippingbox") { Text(store.text("Turn off the filter to view stopped, paused and restarting containers.", "关闭筛选可查看已停止、暂停及重启中的容器。")).font(.system(size: 12)).foregroundStyle(Palette.muted) } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(visible) { container in
                        Button { selected = container } label: {
                            MonitoringPanel(title: container.name, symbol: "shippingbox") {
                                Text(container.image).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                                MonitoringValue(label: store.text("State", "状态"), value: container.state)
                                Text(container.status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).help(container.status)
                                MonitoringValue(label: store.text("Health", "健康"), value: container.health ?? "—")
                                MonitoringMeter(label: "CPU", percentage: container.cpuPercent)
                                MonitoringValue(label: store.text("Memory", "内存"), value: "\(MonitoringPresentation.bytes(container.memoryUsedBytes)) / \(MonitoringPresentation.bytes(container.memoryLimitBytes))")
                                MonitoringValue(label: "↑ / ↓", value: "\(MonitoringPresentation.bytes(container.networkTransmittedBytes)) / \(MonitoringPresentation.bytes(container.networkReceivedBytes))")
                                HStack { Text(store.text("Resource details", "资源明细")); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(store.text("Container details: \(container.name)", "容器详情：\(container.name)"))
                    }
                }
            }
        }.sheet(item: $selected) { container in MonitoringContainerDetail(container: container).environmentObject(store) }
    }
}

private struct MonitoringContainerDetail: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let container: MonitoringContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeading(title: container.name, subtitle: container.image)
            MonitoringValue(label: "ID", value: container.id)
            MonitoringValue(label: store.text("State / status", "状态／详情"), value: container.state + " · " + container.status)
            MonitoringValue(label: store.text("Health", "健康"), value: container.health ?? "—")
            MonitoringValue(label: store.text("Started", "启动时间"), value: container.startedAt ?? "—")
            MonitoringValue(label: store.text("Restarts / PID", "重启次数／PID"), value: "\(container.restartCount.map(String.init) ?? "—") / \(container.pid.map(String.init) ?? "—")")
            MonitoringValue(label: "CPU", value: MonitoringPresentation.percentage(container.cpuPercent))
            MonitoringValue(label: store.text("Memory used / limit", "内存已使用／限制"), value: "\(MonitoringPresentation.bytes(container.memoryUsedBytes)) / \(MonitoringPresentation.bytes(container.memoryLimitBytes))")
            MonitoringValue(label: store.text("Network transmit / receive", "网络上传／下载"), value: "\(MonitoringPresentation.bytes(container.networkTransmittedBytes)) / \(MonitoringPresentation.bytes(container.networkReceivedBytes))")
            MonitoringValue(label: store.text("Block I/O read / write", "磁盘 I/O 读取／写入"), value: "\(MonitoringPresentation.bytes(container.blockReadBytes)) / \(MonitoringPresentation.bytes(container.blockWrittenBytes))")
            MonitoringValue(label: store.text("Processes", "进程"), value: container.pids.map(String.init) ?? "—")
            MonitoringValue(label: store.text("Port mappings", "端口映射"), value: container.ports ?? "—")
            HStack { Text(store.text("Read-only snapshot", "只读采样")).font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer(); Button(store.text("Close", "关闭")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 540).background(Palette.sidebar).foregroundStyle(Palette.text)
    }
}
