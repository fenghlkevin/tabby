import AppKit
import SwiftUI

/// App-owned prompts share compact typography and buttons; OS file pickers stay native.
@MainActor final class AppModalAlert: NSAlert {
    override func runModal() -> NSApplication.ModalResponse {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = messageText
        if let field = accessoryView as? NSTextField {
            field.frame = NSRect(x: 0, y: 0, width: 432, height: 34)
            field.font = .systemFont(ofSize: 14)
            field.focusRingType = .none
        }
        let accessory = accessoryView
        let content = ModalAlertBody(title: messageText, detail: informativeText, accessory: accessory, titles: buttons.map(\.title)) { index in
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        }
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        if let field = accessory as? NSTextField { panel.makeFirstResponder(field); field.selectText(nil) }
        let result = NSApp.runModal(for: panel)
        panel.orderOut(nil)
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
    let respond: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 18, weight: .semibold))
            if !detail.isEmpty { Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let accessory { ModalAccessory(view: accessory).frame(height: max(34, accessory.frame.height)) }
            HStack(spacing: 10) {
                Spacer()
                ForEach(Array(titles.enumerated().reversed()), id: \.offset) { index, title in
                    Button(title) { respond(index) }.buttonStyle(ChromeButtonStyle(prominent: index == 0))
                        .modifier(DialogShortcut(primary: index == 0, cancel: title == "取消" || title == "Cancel"))
                }
            }
        }.padding(24).frame(width: 480).foregroundStyle(Palette.text).background(Palette.sidebar)
    }
}

private struct PromptActionStyle: PrimitiveButtonStyle {
    @Binding var presented: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.trigger(); presented = false } label: { configuration.label.frame(maxWidth: .infinity) }
            .buttonStyle(ChromeButtonStyle(prominent: configuration.role != .cancel, accentColor: configuration.role == .destructive ? .red : nil))
    }
}
extension View {
    func appAlert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        sheet(isPresented: isPresented) {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 18, weight: .semibold))
                message().font(.system(size: 13)).foregroundStyle(Palette.muted)
                VStack(spacing: 10) { actions() }.buttonStyle(PromptActionStyle(presented: isPresented))
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
