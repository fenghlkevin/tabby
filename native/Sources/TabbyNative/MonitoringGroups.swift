import AppKit
import SwiftUI

enum MonitoringBrowseScope: Equatable {
    case all
    case group(String)
}

struct MonitoringGroupSummary: Identifiable, Equatable {
    let name: String
    let hostCount: Int
    let connectedCount: Int
    var id: String { name }
}

/// Browsing only filters the existing monitoring catalog. Group selection does
/// not create connections, flatten inherited authentication, or alter sampling.
struct MonitoringBrowseCatalog {
    let entries: [MonitoringEntry]
    let declaredGroups: [String]
    let scope: MonitoringBrowseScope?
    let query: String
    var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isRootBrowse: Bool { scope == nil && search.isEmpty }
    var groups: [MonitoringGroupSummary] {
        CatalogNames.unique(declaredGroups + entries.map(\.group))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let hosts = entries.filter { CatalogNames.matches($0.group.trimmingCharacters(in: .whitespacesAndNewlines), name) }
                return MonitoringGroupSummary(name: name, hostCount: hosts.count, connectedCount: hosts.filter(\.isConnected).count)
            }
    }
    var visibleEntries: [MonitoringEntry] {
        entries.filter { entry in
            let scopeMatches: Bool
            switch scope {
            case .group(let name): scopeMatches = CatalogNames.matches(entry.group.trimmingCharacters(in: .whitespacesAndNewlines), name)
            case .all: scopeMatches = true
            case nil: scopeMatches = !isRootBrowse || entry.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return scopeMatches && (search.isEmpty || "\(entry.label) \(entry.address) \(entry.group)".localizedCaseInsensitiveContains(search))
        }
    }
}

/// A native card makes the label, folder and all surrounding padding the same
/// action region, including the corners. It has no nested buttons.
struct MonitoringGroupButton: NSViewRepresentable {
    let group: MonitoringGroupSummary
    let chinese: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> MonitoringGroupNativeButton { MonitoringGroupNativeButton(frame: .zero) }
    func updateNSView(_ button: MonitoringGroupNativeButton, context: Context) {
        button.title = group.name
        button.subtitle = "\(group.hostCount)" + (chinese ? " 台主机" : " hosts") + " · " + "\(group.connectedCount)" + (chinese ? " 已连接" : " connected")
        let label = (chinese ? "监控分组：" : "Monitoring group: ") + group.name
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(button.subtitle)
        button.toolTip = label
        button.setAccessibilityIdentifier("monitoring-group-" + group.name)
        button.identifier = NSUserInterfaceItemIdentifier("monitoring-group-" + group.name)
        button.invoke = action
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MonitoringGroupNativeButton, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 280, height: 82) }
}

final class MonitoringGroupNativeButton: NSButton {
    var subtitle = ""
    var invoke: () -> Void = {}
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 82) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryChange); isBordered = false
        target = self; action = #selector(activate)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { if isEnabled { invoke() } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hovered || isHighlighted ? Palette.selected : Palette.card).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let tile = NSRect(x: 16, y: 20, width: 42, height: 42)
        NSColor(Palette.blue).setFill(); NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill()
        let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white]))
        folder?.draw(in: tile.insetBy(dx: 10, dy: 10))
        let available = max(0, bounds.width - 100)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(Palette.text), .paragraphStyle: paragraph])
            .draw(in: NSRect(x: 72, y: 23, width: available, height: 20))
        NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(Palette.muted), .paragraphStyle: paragraph])
            .draw(in: NSRect(x: 72, y: 45, width: available, height: 18))
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [NSColor(Palette.muted)]))
        chevron?.draw(in: NSRect(x: bounds.width - 27, y: 35, width: 8, height: 12))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
}
