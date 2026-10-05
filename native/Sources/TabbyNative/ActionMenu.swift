import SwiftUI

private struct ActionMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ActionMenuDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
private extension EnvironmentValues {
    var dismissActionMenu: () -> Void {
        get { self[ActionMenuDismissKey.self] }
        set { self[ActionMenuDismissKey.self] = newValue }
    }
}

/// Shared anchored menus use readable rows and let AppKit keep the popover inside the window.
struct AppActionMenu<Content: View, Label: View>: View {
    @State private var presented = false
    @State private var contentHeight: CGFloat = 180
    private let content: Content
    private let label: Label
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label()
    }
    var body: some View {
        Button { presented.toggle() } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) { content }
                        .buttonStyle(ActionMenuRowStyle())
                        .environment(\.dismissActionMenu, { presented = false })
                        .padding(8)
                        .background(GeometryReader { geometry in Color.clear.preference(key: ActionMenuHeightKey.self, value: geometry.size.height) })
                }.scrollIndicators(.hidden).frame(width: 240, height: min(400, max(44, contentHeight)))
                    .onPreferenceChange(ActionMenuHeightKey.self) { if $0 > 0 { contentHeight = $0 } }
                    .font(.system(size: 13)).foregroundStyle(Palette.text)
                    .background(Palette.sidebar)
            }
    }
}

private struct ActionMenuRowStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.dismissActionMenu) private var dismiss
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            Button { dismiss(); configuration.trigger() } label: {
                configuration.label.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 10).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(configuration.role == .destructive ? Color.red : Palette.text)
                .opacity(enabled ? 1 : 0.45)
                .background(hovering && enabled ? Palette.selected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    func appContextMenu<MenuContent: View>(@ViewBuilder content: () -> MenuContent) -> some View {
        modifier(AppContextMenuModifier(menu: content()))
    }
}

private struct AppContextMenuModifier<MenuContent: View>: ViewModifier {
    let menu: MenuContent
    @State private var presented = false
    @State private var point = CGPoint.zero
    @State private var contentHeight: CGFloat = 180
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).offset(x: point.x, y: point.y)
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) { menu }
                            .buttonStyle(ActionMenuRowStyle())
                            .environment(\.dismissActionMenu, { presented = false })
                            .padding(8)
                            .background(GeometryReader { geometry in Color.clear.preference(key: ActionMenuHeightKey.self, value: geometry.size.height) })
                    }.scrollIndicators(.hidden).frame(width: 240, height: min(400, max(44, contentHeight)))
                        .onPreferenceChange(ActionMenuHeightKey.self) { if $0 > 0 { contentHeight = $0 } }
                        .font(.system(size: 13)).foregroundStyle(Palette.text).background(Palette.sidebar)
                }
        }.background(ContextClickSurface { location in point = location; presented = true })
    }
}

private struct ContextClickSurface: NSViewRepresentable {
    let action: (CGPoint) -> Void
    func makeNSView(context: Context) -> ContextClickView { ContextClickView() }
    func updateNSView(_ view: ContextClickView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: ContextClickView, coordinator: ()) { view.stopMonitoring() }
}

/// Observe only right clicks inside this visible view; ordinary clicks pass through untouched.
final class ContextClickView: NSView {
    var action: ((CGPoint) -> Void)?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window != nil, !isHiddenOrHasHiddenAncestor,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), visibleRect.contains(point) else { return false }
        action?(point); return true
    }
    func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
