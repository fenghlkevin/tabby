import SwiftUI

enum MonitoringNetworkPresentation {
    /// Keep down, loopback, bridge and address-only interfaces too. Sort for a
    /// stable layout, without substituting a single automatically chosen NIC.
    static func interfaces(_ values: [MonitoringInterface]) -> [MonitoringInterface] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func version(_ address: String) -> String { address.contains(":") ? "IPv6" : "IPv4" }
}

struct MonitoringNetworkView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    let entry: MonitoringEntry
    @State private var period = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(store.text("Network interfaces", "全部网卡"), systemImage: "network").font(.system(size: 14, weight: .semibold))
                Text(String(snapshot.interfaces.count)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            if snapshot.interfaces.isEmpty { MonitoringPanel(title: store.text("Network interfaces", "全部网卡"), symbol: "network") { MonitoringUnavailable(snapshot: snapshot, key: "interfaces") } }
            MonitoringInterfaceGrid {
                ForEach(MonitoringNetworkPresentation.interfaces(snapshot.interfaces)) { interface in
                    MonitoringInterfaceCard(interface: interface, snapshot: snapshot)
                }
            }
            MonitoringPanel(title: store.text("IP information", "IP 信息"), symbol: "globe") {
                MonitoringValue(label: store.text("SSH connection address", "SSH 连接地址"), value: entry.address)
                Text(store.text("Every interface address comes from this host. No external IP or location query is made.", "上方展示此主机全部网卡地址；不进行外部 IP 或地区查询。")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            MonitoringPanel(title: store.text("Traffic history", "历史流量"), symbol: "chart.bar") { history }
        }
    }
    @ViewBuilder private var history: some View {
        if let history = snapshot.trafficHistory {
            let periods = Array(Set(history.records.map(\.period))).sorted()
            let chosenPeriod = periods.contains(period) ? period : periods.first ?? ""
            if !periods.isEmpty {
                Picker(store.text("Period", "时间范围"), selection: Binding(get: { chosenPeriod }, set: { period = $0 })) {
                    ForEach(periods, id: \.self) { value in Text(periodTitle(value)).tag(value) }
                }.pickerStyle(.menu)
                Text(history.source).font(.system(size: 11)).foregroundStyle(Palette.muted)
                let names = Array(Set(history.records.map(\.interface))).sorted()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(names, id: \.self) { name in
                        let records = history.records.filter { $0.interface == name && $0.period == chosenPeriod }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(name).font(.system(size: 12, weight: .semibold))
                            let visible = records.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }.prefix(30)
                            ForEach(Array(visible)) { record in
                                VStack(alignment: .leading, spacing: 5) {
                                    if let time = record.timestamp { Text(time, format: .dateTime.year().month().day().hour().minute()).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                    MonitoringValue(label: "↑ / ↓", value: "\(MonitoringPresentation.bytes(record.transmittedBytes)) / \(MonitoringPresentation.bytes(record.receivedBytes))")
                                }
                                Divider()
                            }
                            if records.isEmpty { Text(store.text("No records for this period", "此时间范围暂无记录")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                            if records.count > 30 { Text(store.text("Showing the latest 30 records.", "显示最近 30 条记录。")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        }.padding(12).background(Palette.field.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else { MonitoringUnavailable(snapshot: snapshot, key: "history") }
        } else { MonitoringUnavailable(snapshot: snapshot, key: "history") }
    }
    private func periodTitle(_ value: String) -> String {
        switch value {
        case "total": return store.text("Total", "累计")
        case "day", "days": return store.text("Daily", "每日")
        case "month", "months": return store.text("Monthly", "每月")
        case "year", "years": return store.text("Yearly", "每年")
        case "hour", "hours": return store.text("Hourly", "每小时")
        case "fiveminute": return store.text("Every five minutes", "每五分钟")
        default: return value
        }
    }
}

struct MonitoringInterfaceCard: View {
    @EnvironmentObject var store: AppStore
    let interface: MonitoringInterface
    let snapshot: MonitoringSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(interface.name, systemImage: "network").font(.system(size: 14, weight: .semibold))
            MonitoringValue(label: store.text("State", "状态"), value: interface.state ?? "—")
            HStack(spacing: 24) {
                rate(store.text("↑ Transmit", "↑ 上传"), interface.transmitBytesPerSecond)
                rate(store.text("↓ Receive", "↓ 下载"), interface.receiveBytesPerSecond)
                Spacer(minLength: 0)
            }
            if interface.receiveBytesPerSecond == nil || interface.transmitBytesPerSecond == nil {
                Text(store.text("Rates appear after two samples.", "两次采样后显示速率。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            MonitoringValue(label: store.text("Total transmitted", "累计上传"), value: MonitoringPresentation.bytes(interface.transmittedBytes))
            MonitoringValue(label: store.text("Total received", "累计下载"), value: MonitoringPresentation.bytes(interface.receivedBytes))
            Divider()
            if interface.addresses.isEmpty {
                Text(snapshot.availability["addresses"] == "Available" ? store.text("No assigned addresses", "未分配地址") : store.text("Addresses unavailable", "地址不可用")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ForEach(interface.addresses, id: \.self) { address in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(MonitoringNetworkPresentation.version(address))
                        Text(MonitoringPresentation.addressKind(address)?.title(store) ?? store.text("Address", "地址"))
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text(address).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("axon-interface-" + interface.name)
    }
    private func rate(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(MonitoringPresentation.rate(value)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
        }
    }
}

// Preserve the existing NIC layout name while sharing row sizing with resources.
typealias MonitoringInterfaceGrid = MonitoringEqualHeightGrid
