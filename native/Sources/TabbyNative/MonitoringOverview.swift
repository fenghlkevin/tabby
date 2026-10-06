import AppKit
import SwiftUI

struct MonitoringLayoutPicker: NSViewRepresentable {
    @Binding var grid: Bool
    var chinese: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2; control.trackingMode = .selectOne; control.segmentStyle = .rounded
        control.target = context.coordinator; control.action = #selector(Coordinator.selectLayout(_:))
        control.identifier = NSUserInterfaceItemIdentifier("monitoring-layout-picker")
        control.setAccessibilityIdentifier("monitoring-layout-picker")
        for index in 0..<2 {
            control.setImage(NSImage(systemSymbolName: index == 0 ? "square.grid.2x2" : "list.bullet", accessibilityDescription: nil), forSegment: index)
            control.setWidth(32, forSegment: index)
        }
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = { grid = $0 }
        control.selectedSegment = grid ? 0 : 1
        control.setToolTip(chinese ? "卡片视图" : "Card view", forSegment: 0)
        control.setToolTip(chinese ? "列表视图" : "List view", forSegment: 1)
        control.setAccessibilityLabel(chinese ? "监控显示方式" : "Monitoring layout")
        control.setAccessibilityValue(grid ? (chinese ? "卡片视图" : "Card view") : (chinese ? "列表视图" : "List view"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { CGSize(width: 70, height: 32) }
    @MainActor final class Coordinator: NSObject {
        var choose: (Bool) -> Void = { _ in }
        @objc func selectLayout(_ sender: NSSegmentedControl) { choose(sender.selectedSegment == 0) }
    }
}

/// A sibling control, outside the card's details button, ensures opening a
/// terminal cannot also select the card or accidentally start SSH on selection.
struct MonitoringTerminalButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let entry: MonitoringEntry
    var chinese: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> MonitoringTerminalNativeButton { MonitoringTerminalNativeButton(frame: .zero) }
    func updateNSView(_ button: MonitoringTerminalNativeButton, context: Context) {
        let title = entry.isConnected ? (chinese ? "打开终端" : "Terminal") : (chinese ? "连接" : "Connect")
        let label = (entry.isConnected ? (chinese ? "打开终端：" : "Open terminal for ") : (chinese ? "后台连接：" : "Connect in background to ")) + entry.label
        button.prominent = !entry.isConnected
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(entry.isConnected ? Palette.text : Palette.card)])
        button.contentTintColor = NSColor(entry.isConnected ? Palette.text : Palette.card)
        button.imagePosition = .imageLeading
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier("monitoring-connect-" + entry.address)
        button.setAccessibilityIdentifier(button.identifier?.rawValue)
        button.isEnabled = enabled; button.alphaValue = enabled ? 1 : 0.4; button.invoke = action
        button.refreshAppearance()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MonitoringTerminalNativeButton, context: Context) -> CGSize? { CGSize(width: MonitoringTerminalNativeButton.width, height: MonitoringTerminalNativeButton.height) }
}

final class MonitoringTerminalNativeButton: NSButton {
    static let width: CGFloat = 116
    static let height: CGFloat = 36
    var invoke: () -> Void = {}
    var prominent = true
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryChange); isBordered = false
        font = .systemFont(ofSize: 12, weight: .semibold)
        image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        target = self; action = #selector(activate)
        wantsLayer = true; layer?.cornerRadius = 8
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { if isEnabled { invoke() } }
    override func draw(_ dirtyRect: NSRect) {
        // imageLeading anchors the native image to the control's outer edge.
        // Draw the same attributed title and glyph as one centered label while
        // retaining NSButton's native target, tracking, AX and disabled state.
        let titleSize = attributedTitle.size()
        let imageWidth: CGFloat = 14, gap: CGFloat = 7
        let start = max(10, (bounds.width - imageWidth - gap - titleSize.width) / 2)
        let glyph = image?.withSymbolConfiguration(.init(paletteColors: [contentTintColor ?? .white]))
        glyph?.draw(in: NSRect(x: start, y: (bounds.height - imageWidth) / 2, width: imageWidth, height: imageWidth))
        attributedTitle.draw(in: NSRect(x: start + imageWidth + gap, y: (bounds.height - titleSize.height) / 2, width: titleSize.width + 1, height: titleSize.height + 1))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            focus.lineWidth = 2; focus.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshAppearance() }
    override func highlight(_ flag: Bool) { super.highlight(flag); refreshAppearance() }
    func refreshAppearance() {
        let background = prominent ? Palette.accent : (hovered || isHighlighted ? Palette.selected : Palette.field)
        layer?.backgroundColor = NSColor(background).cgColor
        layer?.opacity = isHighlighted ? 0.72 : hovered && prominent ? 0.88 : 1
    }
}

struct MonitoringHostCard: View {
    @EnvironmentObject var store: AppStore
    let entry: MonitoringEntry
    let snapshot: MonitoringSnapshot?
    let state: String
    let select: () -> Void
    let connect: () -> Void
    var canConnect: Bool
    static let height: CGFloat = 206
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        IconTile(symbol: "server.rack", color: Palette.blue, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(entry.address).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.frame(height: 52)
                    metrics.frame(height: 62, alignment: .center)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel(store.text("Monitoring details for \(entry.label)", "\(entry.label) 的监控详情"))
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.group.isEmpty ? "SSH" : entry.group).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(entry.isConnected ? Palette.accent : Palette.muted).frame(width: 5, height: 5)
                        Text(state).lineLimit(1)
                    }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                MonitoringTerminalButton(entry: entry, chinese: store.chinese, action: connect).frame(width: MonitoringTerminalNativeButton.width, height: MonitoringTerminalNativeButton.height).disabled(!canConnect)
            }.frame(height: MonitoringTerminalNativeButton.height)
        }.padding(16).frame(maxWidth: .infinity).frame(height: Self.height)
            .foregroundStyle(Palette.text).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var metrics: some View {
        if entry.isConnected, let snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    MonitoringMeter(label: "CPU", percentage: snapshot.cpu?.usagePercent)
                    MonitoringMeter(label: store.text("Memory", "内存"), percentage: snapshot.memory?.usedPercent, color: .purple)
                }
                HStack {
                    Text(snapshot.os).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(snapshot.timestamp, format: .dateTime.hour().minute().second())
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .accessibilityLabel(store.text("Last successful sample", "上次成功采样"))
            }
        } else {
            Text(entry.isConnected ? state : store.text("SSH is not connected. Connect to view metrics.", "未连接 SSH，连接后可查看。"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MonitoringHostRow: View {
    @EnvironmentObject var store: AppStore
    let entry: MonitoringEntry
    let snapshot: MonitoringSnapshot?
    let state: String
    let select: () -> Void
    let connect: () -> Void
    var canConnect: Bool
    var body: some View {
        HStack(spacing: 14) {
            Button(action: select) {
                HStack(spacing: 12) {
                    IconTile(symbol: "server.rack", color: Palette.blue, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(entry.address + (entry.group.isEmpty ? "" : " · " + entry.group)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            summary(label: "CPU", value: MonitoringPresentation.percentage(entry.isConnected ? snapshot?.cpu?.usagePercent : nil))
                            summary(label: store.text("Memory", "内存"), value: MonitoringPresentation.percentage(entry.isConnected ? snapshot?.memory?.usedPercent : nil))
                            Text(state).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 112, alignment: .trailing).lineLimit(1)
                        }.fixedSize(horizontal: true, vertical: false)
                        Text(state).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel(store.text("Monitoring details for \(entry.label)", "\(entry.label) 的监控详情"))
            MonitoringTerminalButton(entry: entry, chinese: store.chinese, action: connect).frame(width: MonitoringTerminalNativeButton.width, height: MonitoringTerminalNativeButton.height).disabled(!canConnect)
        }.padding(.horizontal, 16).frame(height: 76).foregroundStyle(Palette.text).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func summary(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }.frame(width: 65, alignment: .trailing)
    }
}
