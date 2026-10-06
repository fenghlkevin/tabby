import SwiftUI
import AppKit

enum MonitoringStoragePresentation {
    /// RAM filesystems and per-container overlay mounts obscure the actual
    /// storage volumes. Keep their original records available in a disclosure.
    static func isSystemMount(_ disk: MonitoringDisk) -> Bool {
        // A host reached inside a container can itself use overlay for /.
        // Its root capacity remains useful, even when other overlays collapse.
        guard disk.mountpoint != "/" else { return false }
        let filesystem = (disk.filesystem ?? "").lowercased()
        return ["tmpfs", "devtmpfs", "overlay", "aufs", "proc", "sysfs", "cgroup", "cgroup2", "devpts", "securityfs", "pstore", "squashfs", "nsfs", "mqueue", "debugfs", "tracefs", "fusectl"].contains(filesystem)
    }
    static func volumes(_ disks: [MonitoringDisk], system: Bool) -> [MonitoringDisk] {
        disks.filter { isSystemMount($0) == system }.sorted {
            if $0.mountpoint == "/" || $1.mountpoint == "/" { return $0.mountpoint == "/" && $1.mountpoint != "/" }
            return $0.mountpoint.localizedStandardCompare($1.mountpoint) == .orderedAscending
        }
    }
}

@MainActor enum MonitoringClipboard {
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

struct MonitoringStorageView: View {
    @EnvironmentObject var store: AppStore
    let snapshot: MonitoringSnapshot
    @State private var systemMountsExpanded = false
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(store.text("Storage volumes", "存储卷"), systemImage: "internaldrive").font(.system(size: 14, weight: .semibold))
            if snapshot.disks.isEmpty { MonitoringPanel(title: store.text("Disks", "磁盘"), symbol: "internaldrive") { MonitoringUnavailable(snapshot: snapshot, key: "disks") } }
            let volumes = MonitoringStoragePresentation.volumes(snapshot.disks, system: false)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(volumes) { MonitoringVolumeCard(disk: $0) }
            }
            let system = MonitoringStoragePresentation.volumes(snapshot.disks, system: true)
            if !system.isEmpty {
                MonitoringDisclosureGroup(store.text("System and container mounts (\(system.count))", "系统及容器挂载（\(system.count)）"),
                                          isExpanded: $systemMountsExpanded, identifier: "axon-system-mounts",
                                          expandedAccessibilityValue: store.text("Expanded", "已展开"),
                                          collapsedAccessibilityValue: store.text("Collapsed", "已折叠")) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(system) { MonitoringVolumeCard(disk: $0) }
                    }.padding(.top, 12)
                }
            }
            Label(store.text("Disk I/O", "磁盘 I/O"), systemImage: "arrow.left.arrow.right").font(.system(size: 14, weight: .semibold)).padding(.top, 4)
            if snapshot.diskIO.isEmpty { MonitoringPanel(title: store.text("Disk I/O", "磁盘 I/O"), symbol: "internaldrive") { MonitoringUnavailable(snapshot: snapshot, key: "diskIO") } }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(snapshot.diskIO) { io in
                    MonitoringPanel(title: io.device, symbol: "internaldrive") {
                        MonitoringValue(label: store.text("Read", "读取"), value: MonitoringPresentation.rate(io.readBytesPerSecond))
                        MonitoringValue(label: store.text("Write", "写入"), value: MonitoringPresentation.rate(io.writeBytesPerSecond))
                        MonitoringValue(label: store.text("Read / write IOPS", "读／写 IOPS"), value: "\(MonitoringPresentation.number(io.readIOPS)) / \(MonitoringPresentation.number(io.writeIOPS))")
                        if io.utilizationPercent != nil { MonitoringMeter(label: store.text("Utilization", "利用率"), percentage: io.utilizationPercent) }
                        if io.readBytesPerSecond == nil || io.writeBytesPerSecond == nil { Text(store.text("Rates appear after two samples.", "两次采样后显示速率。")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    }.accessibilityIdentifier("axon-disk-io-" + io.device)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonitoringVolumeCard: View {
    @EnvironmentObject var store: AppStore
    let disk: MonitoringDisk
    var pasteboard: NSPasteboard = .general
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").foregroundStyle(Palette.muted)
                Text(disk.mountpoint).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(disk.mountpoint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { MonitoringClipboard.copy(disk.mountpoint, to: pasteboard) } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted).help(store.text("Copy mount path", "复制挂载路径"))
                    .accessibilityLabel(store.text("Copy mount path: \(disk.mountpoint)", "复制挂载路径：\(disk.mountpoint)"))
            }
            MonitoringMeter(label: store.text("Used", "已使用"), percentage: disk.usedPercent)
            MonitoringValue(label: store.text("Used / total", "已使用／总量"), value: "\(MonitoringPresentation.bytes(disk.usedBytes)) / \(MonitoringPresentation.bytes(disk.totalBytes))")
            MonitoringValue(label: store.text("Available", "可用"), value: MonitoringPresentation.bytes(disk.availableBytes))
            Text(disk.device + (disk.filesystem.map { " · " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.middle).help(disk.device + (disk.filesystem.map { " · " + $0 } ?? ""))
                .appContextMenu { Button(store.text("Copy device", "复制设备")) { MonitoringClipboard.copy(disk.device, to: pasteboard) } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("axon-volume-" + disk.id)
    }
}
