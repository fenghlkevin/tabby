import SwiftUI
import AppKit

/// One anchored Axon surface for native choice fields. NSMenu remains the action
/// model so existing targets, enabled states and selected values stay intact.
@MainActor final class AxonMenuPopover: NSObject, NSPopoverDelegate, ObservableObject {
    static private(set) var active: AxonMenuPopover?
    let menu: NSMenu
    let popover = NSPopover()
    @Published var highlighted: Int
    private weak var anchor: NSView?
    var panelHeight: CGFloat { min(400, CGFloat(menu.items.reduce(0) { $0 + ($1.isSeparatorItem ? 13 : $1.toolTip == nil ? 38 : 56) }) + 16 + (menu.title.isEmpty ? 0 : 30)) }
    private var monitor: Any?
    init(menu: NSMenu) {
        self.menu = menu
        highlighted = menu.items.firstIndex { $0.state == .on && $0.isEnabled } ?? menu.items.firstIndex { !$0.isSeparatorItem && $0.isEnabled } ?? -1
        super.init()
    }
    static func show(_ menu: NSMenu, from anchor: NSView) {
        active?.popover.close()
        guard anchor.window != nil else { return }
        let presenter = AxonMenuPopover(menu: menu); active = presenter; presenter.anchor = anchor
        let width = min(420, max(240, anchor.bounds.width))
        presenter.popover.behavior = .transient; presenter.popover.animates = false; presenter.popover.delegate = presenter
        presenter.popover.contentViewController = NSHostingController(rootView: AxonMenuPanel(model: presenter, width: width))
        presenter.popover.contentSize = NSSize(width: width, height: presenter.panelHeight)
        presenter.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        presenter.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak presenter] event in
            guard let presenter, event.window === presenter.popover.contentViewController?.view.window || event.window === presenter.anchor?.window else { return event }
            return presenter.handleKey(event.keyCode) ? nil : event
        }
    }
    @discardableResult func handleKey(_ key: UInt16) -> Bool {
        switch key {
        case 53: popover.close()
        case 125, 126:
            let eligible = menu.items.indices.filter { menu.items[$0].isEnabled && !menu.items[$0].isSeparatorItem }
            guard !eligible.isEmpty else { return true }
            let index = eligible.firstIndex(of: highlighted) ?? 0
            highlighted = eligible[(index + (key == 125 ? 1 : eligible.count - 1)) % eligible.count]
        case 36, 49, 76: select(highlighted)
        default: return false
        }
        return true
    }
    func select(_ index: Int) {
        guard menu.items.indices.contains(index) else { return }
        let item = menu.items[index]
        guard item.isEnabled, !item.isSeparatorItem else { return }
        popover.close()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
    func popoverDidClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let anchor { anchor.window?.makeFirstResponder(anchor) }
        if Self.active === self { Self.active = nil }
        popover.contentViewController = nil
    }
}

struct AxonMenuPanel: View {
    @ObservedObject var model: AxonMenuPopover
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.menu.title.isEmpty { Text(model.menu.title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(model.menu.items.enumerated()), id: \.offset) { index, item in
                        if item.isSeparatorItem { Divider().padding(.vertical, 4) }
                        else {
                            Button { model.select(index) } label: {
                                HStack(spacing: 10) {
                                    if let icon = item.image { Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.attributedTitle.map { AttributedString($0) } ?? AttributedString(item.title)).lineLimit(2)
                                        if let detail = item.toolTip { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent).opacity(item.state == .on ? 1 : 0).frame(width: 16)
                                }.font(.system(size: 13)).padding(.horizontal, 10).frame(minHeight: item.toolTip == nil ? 34 : 52)
                                    .background(model.highlighted == index ? Palette.selected : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(AxonSurfaceButtonStyle()).disabled(!item.isEnabled).opacity(item.isEnabled ? 1 : 0.45)
                                .onHover { if $0 && item.isEnabled { model.highlighted = index } }.id(index)
                        }
                    }
                }.padding(8)
            }.scrollIndicators(.hidden).onChange(of: model.highlighted) { _, value in proxy.scrollTo(value) }
        }
        }.frame(width: width, height: model.panelHeight)
            .foregroundStyle(Palette.text).background(Palette.sidebar).preferredColorScheme(.light)
    }
}

struct AxonSelectionMark: View {
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(selected ? Palette.accent : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Palette.accent : Palette.muted, lineWidth: 1.2))
            .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
            .frame(width: 14, height: 14).accessibilityHidden(true)
    }
}
struct AxonCheckboxStyle: ToggleStyle {
    var terminal = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) { AxonSelectionMark(selected: configuration.isOn); configuration.label; Spacer(minLength: 0) }
                .padding(.horizontal, 10).frame(minHeight: 34)
                .foregroundStyle(terminal ? TerminalChrome.text : Palette.text)
                .background(terminal ? (configuration.isOn ? TerminalChrome.card : TerminalChrome.field) : (configuration.isOn ? Palette.selected : Palette.sidebar))
                .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityValue(configuration.isOn ? "1" : "0")
    }
}

enum AxonSelectionDrawing {
    static func mark(in rect: NSRect, selected: Bool, enabled: Bool = true) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor(selected ? Palette.accent : Palette.muted).withAlphaComponent(enabled ? 1 : 0.45).setStroke(); path.lineWidth = 1.2
        if selected { NSColor(Palette.accent).withAlphaComponent(enabled ? 1 : 0.45).setFill(); path.fill() }
        path.stroke()
        if selected {
            NSColor.white.setStroke(); let tick = NSBezierPath(); tick.lineWidth = 1.5
            tick.move(to: NSPoint(x: rect.minX + 3, y: rect.midY)); tick.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 3)); tick.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3)); tick.stroke()
        }
    }
}
