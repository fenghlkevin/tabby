import SwiftUI
import AppKit

struct MonitoringResourcesView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    let history: [MonitoringSnapshot]
    @State private var coresExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MonitoringEqualHeightGrid(minimumWidth: 320) {
                MonitoringPanel(title: "CPU", symbol: "cpu", fillsRow: true) {
                    if let cpu = snapshot.cpu {
                        if let model = snapshot.cpuModel { Text(model).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                        if let architecture = snapshot.architecture { MonitoringValue(label: store.text("Architecture", "架构"), value: architecture) }
                        MonitoringMeter(label: store.text("Usage", "占用"), percentage: cpu.usagePercent)
                        if cpu.usagePercent == nil { waitingRate }
                        HStack { Text("User " + MonitoringPresentation.percentage(cpu.userPercent)); Text("System " + MonitoringPresentation.percentage(cpu.systemPercent)) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text("Nice \(MonitoringPresentation.percentage(cpu.nicePercent)) · IOWait \(MonitoringPresentation.percentage(cpu.ioWaitPercent)) · Steal \(MonitoringPresentation.percentage(cpu.stealPercent))")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        MonitoringDisclosureGroup(store.text("Logical cores (\(cpu.cores.count))", "逻辑核心（\(cpu.cores.count)）"), isExpanded: $coresExpanded, identifier: "axon-cpu-cores", expandedAccessibilityValue: store.text("Expanded", "已展开"), collapsedAccessibilityValue: store.text("Collapsed", "已收起")) {
                            VStack(spacing: 14) {
                                ForEach(cpu.cores) { core in
                                    VStack(alignment: .leading, spacing: 5) {
                                        MonitoringMeter(label: store.text("Core \(core.id)", "核心 \(core.id)"), percentage: core.usagePercent)
                                        Text("User \(MonitoringPresentation.percentage(core.userPercent)) · System \(MonitoringPresentation.percentage(core.systemPercent))")
                                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    }
                                }
                            }.padding(.top, 10)
                        }.font(.system(size: 12))
                    } else { unavailable("cpu") }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("axon-resource-cpu")
                MonitoringPanel(title: store.text("Load", "负载"), symbol: "waveform.path", fillsRow: true) {
                    if let load = snapshot.load {
                        MonitoringValue(label: store.text("1 / 5 / 15 minutes", "1／5／15 分钟"), value: "\(MonitoringPresentation.number(load.oneMinute)) / \(MonitoringPresentation.number(load.fiveMinutes)) / \(MonitoringPresentation.number(load.fifteenMinutes))")
                        let points = MonitoringPresentation.trendSamples(history.compactMap { sample in sample.load.map { MonitoringTrendPoint(timestamp: sample.timestamp, value: $0.oneMinute) } })
                        if points.count > 1 {
                            MonitoringSparkline(points: points, label: store.text("Recent one-minute load samples", "最近的一分钟负载采样"))
                            Text(store.text("Latest \(points.count) samples", "最近 \(points.count) 次采样")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        else { Text(store.text("Trend appears after multiple samples.", "多次采样后显示负载趋势。" )).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        if let cores = snapshot.coreCount { MonitoringValue(label: store.text("Logical cores", "逻辑核心"), value: String(cores)) }
                        if let uptime = snapshot.uptime { MonitoringValue(label: store.text("Uptime", "运行时间"), value: uptimeString(uptime)) }
                    } else { unavailable("load") }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("axon-resource-load")
                MonitoringPanel(title: store.text("Memory", "内存"), symbol: "memorychip", fillsRow: true) {
                    if let memory = snapshot.memory {
                        MonitoringMeter(label: store.text("Used", "已使用"), percentage: memory.usedPercent, color: .purple)
                        MonitoringValue(label: store.text("Used / total", "已使用／总量"), value: "\(MonitoringPresentation.bytes(memory.usedBytes)) / \(MonitoringPresentation.bytes(memory.totalBytes))")
                        MonitoringValue(label: store.text("Available", "可用"), value: MonitoringPresentation.bytes(memory.availableBytes))
                        MonitoringValue(label: store.text("Free", "空闲"), value: MonitoringPresentation.bytes(memory.freeBytes))
                        MonitoringValue(label: store.text("Cache / buffers", "缓存／缓冲区"), value: "\(MonitoringPresentation.bytes(memory.cachedBytes)) / \(MonitoringPresentation.bytes(memory.buffersBytes))")
                        MonitoringValue(label: "Swap", value: "\(MonitoringPresentation.bytes(memory.swapUsedBytes)) / \(MonitoringPresentation.bytes(memory.swapTotalBytes))")
                    } else { unavailable("memory") }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("axon-resource-memory")
            }
            MonitoringStorageView(snapshot: snapshot)
        }
    }
    private var waitingRate: some View { Text(store.text("Rate requires two samples.", "速率需要两次采样。" )).font(.system(size: 11)).foregroundStyle(Palette.muted) }
    private func unavailable(_ key: String) -> some View { MonitoringUnavailable(snapshot: snapshot, key: key) }
    private func uptimeString(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60)), days = minutes / 1440, hours = minutes / 60 % 24
        return store.text("\(days)d \(hours)h \(minutes % 60)m", "\(days) 天 \(hours) 小时 \(minutes % 60) 分钟")
    }
}

