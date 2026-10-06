import AppKit
import SwiftUI

/// App-owned prompts share compact typography and buttons; OS file pickers stay native.
@MainActor final class AppModalAlert: NSAlert {
    var destructive = false
    var cancelButtonIndex: Int?
    var defaultButtonIndex: Int?
    override func runModal() -> NSApplication.ModalResponse {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = messageText
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("axon-modal-alert")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        if let field = accessoryView as? NSTextField {
            field.frame = NSRect(x: 0, y: 0, width: 432, height: 34)
            field.font = .systemFont(ofSize: 14)
            field.focusRingType = .none
        }
        let cancelIndex = cancelButtonIndex ?? buttons.firstIndex { $0.title == "取消" || $0.title.lowercased().hasPrefix("cancel") } ?? (buttons.count > 1 ? buttons.count - 1 : nil)
        let defaultIndex = defaultButtonIndex ?? (destructive ? cancelIndex : 0)
        let accessory = accessoryView
        let content = ModalAlertBody(title: messageText, detail: informativeText, accessory: accessory, titles: buttons.map(\.title), destructive: destructive, cancelIndex: cancelIndex, defaultIndex: defaultIndex) { index in
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        }
        let hosting = NSHostingView(rootView: content.preferredColorScheme(.light))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        if let field = accessory as? NSTextField { panel.makeFirstResponder(field); field.selectText(nil) }
        let result = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()
        return result
    }
}

private struct ModalAccessory: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
private struct ModalAlertBody: View {
    let title: String
    let detail: String
    let accessory: NSView?
    let titles: [String]
    let destructive: Bool
    let cancelIndex: Int?
    let defaultIndex: Int?
    let respond: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 18, weight: .semibold))
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let accessory { ModalAccessory(view: accessory).frame(height: max(34, accessory.frame.height)) }
            HStack(spacing: 10) {
                Spacer()
                ForEach(Array(titles.enumerated().reversed()), id: \.offset) { index, title in
                    ModalAlertActionButton(title: title, index: index, prominent: index == 0,
                        destructive: destructive && index == 0,
                        key: index == defaultIndex ? "\r" : index == cancelIndex ? "\u{1b}" : "") { respond(index) }
                        .frame(width: max(64, CGFloat(title.count) * 14 + 24), height: 34)
                }
            }
        }.padding(24).frame(width: 480).foregroundStyle(Palette.text).background(Palette.sidebar)
            .onExitCommand { if let cancelIndex { respond(cancelIndex) } }
    }
}

private struct ModalAlertActionButton: NSViewRepresentable {
    let title: String
    let index: Int
    let prominent: Bool
    let destructive: Bool
    let key: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesRectNativeButton { PreferencesRectNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.prominent = prominent; button.destructive = destructive
        button.actionBlock = action; button.keyEquivalent = key; button.keyEquivalentModifierMask = []
        button.identifier = NSUserInterfaceItemIdentifier("axon-modal-action-\(index)")
        button.setAccessibilityLabel(title); button.needsDisplay = true
    }
}

private enum AppAlertDismissKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
private extension EnvironmentValues {
    var dismissAppAlert: () -> Void {
        get { self[AppAlertDismissKey.self] }
        set { self[AppAlertDismissKey.self] = newValue }
    }
}
/// Own the action itself so pointer, keyboard and accessibility all dismiss.
/// A primitive style cannot intercept SwiftUI's original accessibility action.
struct AppAlertButton: View {
    let title: String
    let role: ButtonRole?
    let action: () -> Void
    @Environment(\.dismissAppAlert) private var closeAlert
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.action = action
    }
    var body: some View {
        Button(title, role: role) {
            // Data-bound confirmations may clear their optional target on close.
            // Execute while that target is still available.
            action()
            closeAlert()
            dismiss()
        }.fixedSize(horizontal: true, vertical: false)
            .buttonStyle(ChromeButtonStyle(prominent: role != .cancel, accentColor: role == .destructive ? Palette.danger : nil))
            .modifier(DialogShortcut(primary: false, cancel: role == .cancel))
    }
}

extension View {
    func appAlert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        sheet(isPresented: isPresented) {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 18, weight: .semibold))
                message().font(.system(size: 13)).foregroundStyle(Palette.muted)
                HStack(spacing: 10) { Spacer(minLength: 0); actions() }
                    .environment(\.dismissAppAlert, { isPresented.wrappedValue = false })
            }.padding(24).frame(width: 480).foregroundStyle(Palette.text).background(Palette.sidebar).onExitCommand { isPresented.wrappedValue = false }
        }
    }
    func appAlert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        appAlert(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
    func appAlert<D, A: View, M: View>(_ title: String, isPresented: Binding<Bool>, presenting data: D?, @ViewBuilder actions: @escaping (D) -> A, @ViewBuilder message: @escaping (D) -> M) -> some View {
        appAlert(title, isPresented: isPresented, actions: { if let data { actions(data) } }, message: { if let data { message(data) } })
    }
}

private struct DialogShortcut: ViewModifier {
    let primary: Bool
    let cancel: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if primary { content.keyboardShortcut(.return, modifiers: []) }
        else if cancel { content.keyboardShortcut(.escape, modifiers: []) }
        else { content }
    }
}
