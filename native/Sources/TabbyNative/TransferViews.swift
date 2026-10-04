import SwiftUI
import AppKit

/// Observe the queue at the visibility boundary so clearing its last job also
/// removes the panel immediately, even when neither file pane has changed.
struct TransferQueuePanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var queue: TransferQueue

    var body: some View {
        if !queue.jobs.isEmpty {
            if queue.panelExpanded {
                TransferQueueView(queue: queue).frame(height: 150)
            } else {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Button { queue.expandPanel() } label: {
                            Label("\(store.text("Transfers", "传输队列"))  \(queue.jobs.count)", systemImage: "arrow.up.arrow.down")
                                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help(store.text("Show transfers", "展开传输队列"))
                        HostCardActionButton(symbol: "chevron.up", color: NSColor(Palette.muted), label: store.text("Show transfers", "展开传输队列"), identifier: "transfer-queue-expand", action: queue.expandPanel)
                            .frame(width: 28, height: 28)
                    }.padding(.horizontal, 14).frame(height: 35)
                }.frame(height: 36).foregroundStyle(Palette.text).background(Palette.sidebar)
            }
        }
    }
}

struct TransferQueueView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(store.text("Transfers", "传输队列")).font(.headline)
                Text("\(queue.jobs.count)").foregroundStyle(Palette.muted)
                Spacer()
                Button(store.text("Clear finished", "清理已完成"), action: queue.clearFinished)
                HostCardActionButton(symbol: "xmark", color: NSColor(Palette.muted), label: store.text("Hide transfers", "收起传输队列"), identifier: "transfer-queue-collapse", action: queue.collapsePanel)
                    .frame(width: 28, height: 28)
            }.buttonStyle(ChromeButtonStyle()).padding(.horizontal, 14).frame(height: 44)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(queue.jobs) { job in TransferRow(job: job, queue: queue) }
                }.padding(.bottom, 8)
            }.padding(.horizontal, 10)
        }.foregroundStyle(Palette.text).background(Palette.sidebar)
    }
}

struct TransferRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var job: TransferJob
    @ObservedObject var queue: TransferQueue

    private var statusTitle: String {
        switch job.state {
        case "running": return store.text("In progress", "进行中")
        case "failed": return store.text("Failed", "失败")
        case "completed": return store.text("Completed", "完成")
        case "queued": return store.text("Queued", "等待中")
        case "cancelled": return store.text("Cancelled", "已取消")
        default: return job.state
        }
    }

    private var statusColor: Color {
        switch job.state {
        case "running": return Color(hex: "#1766B5")
        case "failed": return Color(hex: "#B83236")
        case "completed": return Color(hex: "#1C7C43")
        case "queued": return Color(hex: "#996510")
        default: return Palette.muted
        }
    }

    private var statusSymbol: String {
        switch job.state {
        case "running": return "arrow.triangle.2.circlepath"
        case "failed": return "xmark.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "queued": return "clock"
        case "cancelled": return "slash.circle"
        default: return "circle"
        }
    }

    private var directionSymbol: String {
        switch job.direction {
        case "upload": return "arrow.up.circle"
        case "download": return "arrow.down.circle"
        default: return "arrow.left.arrow.right"
        }
    }

    private var directionTitle: String {
        switch job.direction {
        case "upload": return store.text("Upload", "上传")
        case "download": return store.text("Download", "下载")
        default: return store.text("Copy", "复制")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: directionSymbol)
                .font(.system(size: 18)).foregroundStyle(statusColor)
                .frame(width: 24, height: 36).help(directionTitle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.entry.name).font(.caption.bold())
                    .lineLimit(1).truncationMode(.middle).help(job.entry.name)
                HStack(spacing: 8) {
                    Label(statusTitle, systemImage: statusSymbol)
                        .font(.caption2.weight(.semibold)).foregroundStyle(statusColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(statusColor.opacity(0.10)).clipShape(Capsule()).fixedSize()
                    Text(directionTitle).font(.caption2).foregroundStyle(Palette.muted).fixedSize()
                }
                if job.state == "failed", !job.error.isEmpty {
                    Text(job.error).font(.caption2).foregroundStyle(statusColor)
                        .lineLimit(2).help(job.error)
                }
                if job.state == "running" {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(job.completed), total: Double(max(job.total, 1)))
                            .tint(statusColor).frame(maxWidth: 180)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(job.speed), countStyle: .file) + "/s")
                            .font(.caption2).monospacedDigit().foregroundStyle(Palette.muted).fixedSize()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if job.state == "failed" || job.state == "cancelled" {
                Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle()).disabled(!job.retryAvailable)
                    .help(job.retryReason.isEmpty ? store.text("Retry transfer", "重试传输") : job.retryReason)
                    .accessibilityLabel(store.text("Retry transfer", "重试传输"))
            }
            if job.state == "running" || job.state == "queued" {
                Button { queue.cancel(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help(store.text("Cancel transfer", "取消传输"))
                    .accessibilityLabel(store.text("Cancel transfer", "取消传输"))
            }
        }.padding(10).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
