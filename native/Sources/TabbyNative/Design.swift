import SwiftUI
import AppKit

struct ChromeButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Palette.background : Palette.text)
            .padding(.horizontal, 14).frame(height: 34)
            .background(prominent ? Palette.accent : Palette.field)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).foregroundStyle(Palette.muted)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? Palette.selected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
struct WorkspaceMenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceMenuItemBody(label: configuration.label, pressed: configuration.isPressed)
    }
}
private struct WorkspaceMenuItemBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false
    var body: some View {
        label.contentShape(Rectangle()).background(hovering || pressed ? Palette.selected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8)).onHover { hovering = $0 }
    }
}
struct WorkspaceIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14)).foregroundStyle(Palette.chromeText)
            .frame(width: 28, height: 34).contentShape(Rectangle())
            .background(configuration.isPressed ? Color(hex: "#45475F") : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
struct VaultSearchField: View {
    @EnvironmentObject var store: AppStore
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 14))
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel(store.text("Clear search", "清除搜索")) }
        }.padding(.horizontal, 14).frame(height: 36).background(Palette.field)
            .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
    }
}
struct InputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 12).frame(height: 38)
            .background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border.opacity(0.7), lineWidth: 1))
    }
}
extension View { func appInput() -> some View { modifier(InputSurface()) } }
struct IconTile: View {
    let symbol: String
    var color = Palette.orange
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size).background(color).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
    }
}
struct PaneHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.text)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted) }
        }
    }
}

/// Native sibling buttons keep their whole square clickable, including space around the symbol.
struct HostCardActionButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let color: NSColor
    let label: String
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> HostCardNativeActionButton { HostCardNativeActionButton(frame: .zero) }
    func updateNSView(_ button: HostCardNativeActionButton, context: Context) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.contentTintColor = color
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.invoke = action
        button.isEnabled = isEnabled
        button.alphaValue = isEnabled ? 1 : 0.4
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostCardNativeActionButton, context: Context) -> CGSize? { CGSize(width: 32, height: 32) }
}

final class HostCardNativeActionButton: NSButton {
    var invoke: () -> Void = {}
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    // AppKit's image-dependent control padding must not enlarge the SwiftUI square.
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        action = #selector(performAction)
        updateBackground(pressed: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { if isEnabled { invoke() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground(pressed: isHighlighted) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBackground(pressed: isHighlighted) }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateBackground(pressed: flag) }
    private func updateBackground(pressed: Bool) { layer?.backgroundColor = NSColor(pressed || hovered ? Palette.selected : Palette.field).cgColor }
}

struct HostCard: View {
    @EnvironmentObject var store: AppStore
    let host: Host
    let selected: Bool
    let compact: Bool
    let select: () -> Void
    let connect: () -> Void
    let edit: () -> Void
    let favorite: () -> Void
    let delete: () -> Void
    var showGroup = false
    var monitor: (() -> Void)? = nil
    @State private var hovering = false
    var icon: String { host.tags.localizedCaseInsensitiveContains("database") || host.tags.localizedCaseInsensitiveContains("db") ? "externaldrive.fill" : "server.rack" }
    var subtitle: String {
        var seen = Set<String>()
        let details = (["ssh", RecentTargets.effectiveUsername(host, workspace: store.workspace)] + TagTokens.parse(host.tags)).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
        return showGroup && !host.group.isEmpty ? details + " · " + host.group : details
    }
    var tileColor: Color { icon == "externaldrive.fill" ? Color(hex: "#7758AC") : Palette.orange }
    var body: some View {
        HStack(spacing: 10) {
            Button(action: connect) {
                HStack(spacing: 12) {
                    IconTile(symbol: icon, color: tileColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(host.name.isEmpty ? host.address : host.name).font(.system(size: 14)).foregroundStyle(Palette.text).lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !compact { Text(host.address).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).frame(width: 180, alignment: .leading) }
                }.frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60).contentShape(Rectangle())
            }.buttonStyle(.plain).help(store.text("Connect with one click; right-click to edit", "单击连接，右键编辑"))
                .accessibilityLabel(store.text("Connect to \(host.name.isEmpty ? host.address : host.name)", "连接 \(host.name.isEmpty ? host.address : host.name)"))
            HStack(spacing: 4) {
                HostCardActionButton(symbol: host.favorite ? "star.fill" : "star", color: host.favorite ? NSColor(hex: "#EFB143") : NSColor(Palette.muted),
                                     label: host.favorite ? store.text("Remove favorite", "取消收藏") : store.text("Add favorite", "收藏"),
                                     identifier: "axon-host-favorite-" + host.id.uuidString, action: favorite).frame(width: 32, height: 32)
                HostCardActionButton(symbol: "pencil", color: NSColor(Palette.muted), label: store.text("Edit", "编辑"),
                                     identifier: "axon-host-edit-" + host.id.uuidString, action: edit).frame(width: 32, height: 32)
            }.fixedSize()
        }.padding(.horizontal, 14).frame(height: 60)
            .background(hovering || selected ? Palette.selected : Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.accent : .clear, lineWidth: 1.5))
            .onHover { hovering = $0 }
            .contextMenu { Button(store.text("Connect", "连接"), action: connect); Button(store.text("Edit", "编辑"), action: edit); if let monitor { Button(store.text("View status", "查看状态"), action: monitor) }; Button(store.text("Duplicate", "复制主机")) { do { try store.duplicateHost(host) } catch { store.error = error.localizedDescription } }; Menu(store.text("Move to group", "移到分组")) { Button(store.text("Ungrouped", "未分组")) { store.moveHost(host.id, to: "") }; ForEach(store.groups, id: \.self) { group in Button(group) { store.moveHost(host.id, to: group) } } }; Button(store.text("Delete", "删除"), role: .destructive, action: delete) }
    }
}

struct WorkspaceTabStyle: ButtonStyle {
    var selected: Bool
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceTabBody(label: configuration.label, selected: selected, dark: dark, pressed: configuration.isPressed)
    }
}
private struct WorkspaceTabBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let dark: Bool
    let pressed: Bool
    @State private var hovering = false
    var body: some View {
        label.font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Palette.chromeText : Color(hex: "#969BB0"))
            .padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
            .background(Color(hex: selected || hovering ? "#45475F" : dark ? "#252738" : "#393C52"))
            .clipShape(RoundedRectangle(cornerRadius: 10)).opacity(pressed ? 0.75 : 1)
            .onHover { hovering = $0 }.animation(.easeOut(duration: 0.12), value: hovering)
    }
}
struct WindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = NSColor(hex: Palette.surfaceHex)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}

func parseQuickHost(_ text: String) -> Host? {
    var parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
    if parts.first == "ssh" { parts.removeFirst() }
    guard parts.count == 1 || (parts.count == 3 && parts[1] == "-p"), let target = parts.first else { return nil }
    let credentials = target.split(separator: "@", omittingEmptySubsequences: false)
    guard credentials.count == 2, !credentials[0].isEmpty, !credentials[1].isEmpty, !target.contains("/") else { return nil }
    guard let address = try? ConnectionValidation.address(String(credentials[1])) else { return nil }
    var host = Host(); host.username = String(credentials[0]); host.address = address; host.name = address
    if parts.count == 3 { guard let port = ConnectionValidation.integer(parts[2], range: 1...65535) else { return nil }; host.port = port }
    return host
}

struct KnownHostsView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    var endpoints: [String] { store.workspace.trustedKeys.keys.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.sorted() }
    var body: some View {
        VStack(spacing: 0) {
            VaultSearchField(placeholder: store.text("Search known hosts", "搜索已知主机"), text: $search).padding(12).background(Palette.sidebar)
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeading(title: store.text("Known hosts", "已知主机"), subtitle: store.text("Server identities verified when connecting.", "已在连接时确认的服务器身份。"))
                if store.workspace.trustedKeys.isEmpty {
                    ContentUnavailableView(store.text("No verified servers yet", "尚未确认服务器"), systemImage: "checkmark.shield", description: Text(store.text("Server fingerprints appear here after your first connection.", "首次确认主机指纹后，服务器会显示在这里。")))
                }
                ForEach(endpoints, id: \.self) { endpoint in
                    HStack(spacing: 14) { IconTile(symbol: "checkmark.shield", color: Palette.blue); VStack(alignment: .leading, spacing: 6) { Text(endpoint).font(.system(size: 14, weight: .medium)); Text(store.workspace.trustedKeys[endpoint]?.split(separator: " ").first.map(String.init) ?? "SSH").font(.system(size: 11)).foregroundStyle(Palette.muted) }; Spacer(); Text(store.text("Verified", "已确认")).font(.system(size: 12)).foregroundStyle(Palette.accent) }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }.padding(22)
            }
        }.background(Palette.background)
    }
}

/// Only the empty title-bar area starts a native window drag.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
