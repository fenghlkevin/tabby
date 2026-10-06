import SwiftUI
import AppKit

/// These fields retain their background and entire hit area in AppKit.
struct NativeSelectionField: NSViewRepresentable {
    let title: String
    let symbol: String
    let label: String
    let identifier: String
    let open: (SelectionFieldButton) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> SelectionFieldButton { SelectionFieldButton(frame: .zero) }
    func updateNSView(_ button: SelectionFieldButton, context: Context) {
        button.title = title; button.symbol = symbol; button.isEnabled = enabled
        button.setAccessibilityLabel(label); button.setAccessibilityValue(title)
        button.setAccessibilityIdentifier(identifier)
        button.onOpen = { [weak button] in if let button, button.isEnabled { open(button) } }
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectionFieldButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: 38)
    }
}

final class SelectionFieldButton: NSButton {
    var symbol = "folder"
    var onOpen: () -> Void = {}
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 38) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; focusRingType = .none; setButtonType(.momentaryPushIn)
        target = self; action = #selector(openField); setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openField() { guard isEnabled else { return }; window?.makeFirstResponder(self); onOpen() }
    override func keyDown(with event: NSEvent) {
        if isEnabled && [36, 49, 76, 125].contains(Int(event.keyCode)) { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        NSColor(cell?.isHighlighted == true ? Palette.selected : Palette.field).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(Palette.text).withAlphaComponent(opacity), .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        let textRect = NSRect(x: 36, y: (bounds.height - height) / 2, width: max(0, bounds.width - 68), height: height)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: textRect).addClip()
        (title as NSString).draw(in: textRect, withAttributes: attributes); NSGraphicsContext.restoreGraphicsState()
        drawSymbol(symbol, in: NSRect(x: 12, y: 12, width: 14, height: 14), opacity: opacity)
        drawSymbol("chevron.down", in: NSRect(x: bounds.width - 23, y: 14, width: 10, height: 10), opacity: opacity)
        if isEnabled && window?.firstResponder === self {
            NSColor(Palette.accent).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            outline.lineWidth = 1.5; outline.stroke()
        }
    }
    private func drawSymbol(_ symbol: String, in rect: NSRect, opacity: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [NSColor(Palette.muted)]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
    }
}

final class SelectionMenuAction: NSObject {
    let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }
    @objc(axonSelectGroup:) func selectGroup(_ sender: NSMenuItem) { invoke() }
}

struct GroupPicker: View {
    @Binding var selection: String
    let groups: [String]
    let chinese: Bool
    var body: some View {
        NativeSelectionField(title: selection.isEmpty ? (chinese ? "无分组" : "Ungrouped") : selection,
                             symbol: "folder", label: chinese ? "选择分组" : "Choose group", identifier: "host-group-picker") { button in
            AxonMenuPopover.show(makeMenu(width: button.bounds.width), from: button)
        }
    }
    func makeMenu(width: CGFloat = 280) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.minimumWidth = width
        let values = [""] + CatalogNames.unique(groups + (selection.isEmpty ? [] : [selection])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for group in values {
            let item = NSMenuItem(title: group.isEmpty ? (chinese ? "无分组" : "Ungrouped") : group, action: #selector(SelectionMenuAction.selectGroup(_:)), keyEquivalent: "")
            let action = SelectionMenuAction { selection = group }
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.target = action; item.representedObject = action; item.state = CatalogNames.matches(selection, group) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

enum JumpHostChoices {
    static func candidates(for host: Host, hosts: [Host]) -> [Host] {
        hosts.filter { candidate in
            var seen: Set<UUID> = [host.id]
            var next: Host? = candidate
            while let current = next {
                guard seen.insert(current.id).inserted else { return false }
                guard let id = current.jumpHostID else { return true }
                guard let parent = hosts.first(where: { $0.id == id }) else { return false }
                next = parent
            }
            return true
        }.sorted { ($0.name.isEmpty ? $0.address : $0.name).localizedStandardCompare($1.name.isEmpty ? $1.address : $1.name) == .orderedAscending }
    }
}

struct JumpHostPicker: View {
    @Binding var selection: UUID?
    let host: Host
    let hosts: [Host]
    let chinese: Bool
    @State private var showing = false
    private var title: String {
        guard let selection else { return chinese ? "无跳板机（直接连接）" : "None — connect directly" }
        guard let selected = hosts.first(where: { $0.id == selection }) else { return chinese ? "跳板机已不存在" : "Jump host unavailable" }
        return selected.name.isEmpty ? selected.address : selected.name
    }
    var body: some View {
        NativeSelectionField(title: title, symbol: "point.3.connected.trianglepath.dotted", label: chinese ? "选择跳板机" : "Choose jump host", identifier: "host-jump-picker") { _ in showing = true }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                JumpHostChooser(selection: selection, hosts: JumpHostChoices.candidates(for: host, hosts: hosts), chinese: chinese) { id in
                    selection = id; showing = false
                }
            }
    }
}

struct JumpHostChooser: View {
    let selection: UUID?
    let hosts: [Host]
    let chinese: Bool
    let select: (UUID?) -> Void
    @State private var search = ""
    @FocusState private var focused: Bool
    private var matches: [Host] {
        hosts.filter { search.isEmpty || "\($0.name) \($0.address) \($0.username) \($0.group)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chinese ? "选择跳板机" : "Choose jump host").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(chinese ? "搜索名称、地址或分组" : "Search name, address or group", text: $search).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let first = matches.first { select(first.id) } }
            }.padding(.horizontal, 10).frame(height: 34).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
            Button { select(nil) } label: {
                HStack { Image(systemName: "network"); Text(chinese ? "无跳板机（直接连接）" : "None — connect directly"); Spacer(); if selection == nil { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.padding(10).contentShape(Rectangle())
            }.buttonStyle(AxonSurfaceButtonStyle())
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(matches) { candidate in
                        Button { select(candidate.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack").foregroundStyle(Palette.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name.isEmpty ? candidate.address : candidate.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("\(candidate.username)@\(candidate.address)" + (candidate.group.isEmpty ? "" : " · " + candidate.group)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                Spacer()
                                if selection == candidate.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(selection == candidate.id ? Palette.selected : Palette.card).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.buttonStyle(AxonSurfaceButtonStyle())
                    }
                    if matches.isEmpty { Text(chinese ? "没有可用的跳板机" : "No available jump hosts").foregroundStyle(Palette.muted).padding(20) }
                }
            }
            Text(chinese ? "仅显示不会造成跳板循环的主机。" : "Hosts that would create a jump cycle are excluded.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(16).frame(width: 340, height: 390).foregroundStyle(Palette.text).background(Palette.sidebar)
            .onAppear { focused = true }
    }
}

/// Typed choices share Axon's selection surface and below-field menu placement.
struct AxonChoiceField<Value: Equatable>: View {
    @Binding var selection: Value
    let choices: [(Value, String)]
    let placeholder: String
    let symbol: String
    let identifier: String
    var menuTitle: String? = nil
    var descriptions: [String: String] = [:]
    var body: some View {
        NativeSelectionField(title: choices.first { $0.0 == selection }?.1 ?? placeholder,
                             symbol: symbol, label: placeholder, identifier: identifier) { button in
            AxonMenuPopover.show(makeMenu(width: button.bounds.width), from: button)
        }
    }
    func makeMenu(width: CGFloat) -> NSMenu {
        let menu = NSMenu(title: menuTitle ?? ""); menu.autoenablesItems = false; menu.minimumWidth = width
        for (value, title) in choices {
            let item = NSMenuItem(title: title, action: #selector(SelectionMenuAction.selectGroup(_:)), keyEquivalent: "")
            let action = SelectionMenuAction { selection = value }
            item.toolTip = descriptions[title]
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = action; item.representedObject = action; item.state = selection == value ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
