import AppKit
import SwiftUI

/// Uses the workspace's opaque surfaces instead of the system alert's app icon
/// and glass. Closing the panel only cancels this confirmation.
@MainActor final class HostDeletionConfirmationWindowController: NSObject, NSWindowDelegate {
    let host: Host
    let chinese: Bool
    private(set) var window: NSWindow?
    private var presenting = false
    private var confirmed = false

    init(host: Host, chinese: Bool) {
        self.host = host
        self.chinese = chinese
        super.init()
    }
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 304),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = chinese ? "删除主机" : "Delete host"
        panel.identifier = NSUserInterfaceItemIdentifier("axon-host-delete-dialog")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(Palette.card)
        panel.appearance = NSAppearance(named: .aqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        let hosting = NSHostingView(rootView: HostDeletionConfirmationView(host: host, chinese: chinese,
            cancel: { [weak self] in self?.cancel() }, confirm: { [weak self] in self?.confirm() })
            .preferredColorScheme(.light).ignoresSafeArea())
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window = panel
        return panel
    }
    func present() -> Bool {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let previousResponder = parent?.firstResponder
        let panel = prepareWindow()
        if let parent, parent !== panel {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                        y: parent.frame.midY - panel.frame.height / 2))
        } else { panel.center() }
        confirmed = false
        presenting = true
        defer {
            presenting = false
            panel.orderOut(nil)
            panel.delegate = nil
            panel.close()
            window = nil
            if let parent, parent !== panel, parent.isVisible {
                parent.makeKeyAndOrderFront(nil)
                if let previousResponder { parent.makeFirstResponder(previousResponder) }
            }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        if let cancel = actionButton("axon-host-delete-cancel", in: panel.contentView) {
            // Return is deliberately a safe default. The red action requires
            // an explicit click or keyboard focus on the Delete button.
            cancel.keyEquivalent = "\r"
            panel.defaultButtonCell = cancel.cell as? NSButtonCell
        }
        NSApp.runModal(for: panel)
        return confirmed
    }
    func cancel() { finish(false) }
    func confirm() { finish(true) }
    private func finish(_ value: Bool) {
        guard presenting, let window, NSApp.modalWindow === window else { return }
        confirmed = value
        NSApp.stopModal(withCode: value ? .OK : .cancel)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    private func actionButton(_ identifier: String, in root: NSView?) -> NSButton? {
        guard let root else { return nil }
        if let button = root as? NSButton, button.identifier?.rawValue == identifier { return button }
        for child in root.subviews {
            if let button = actionButton(identifier, in: child) { return button }
        }
        return nil
    }
}

struct HostDeletionConfirmationView: View {
    let host: Host
    let chinese: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    private var endpoint: String {
        let address = host.address.contains(":") && !host.address.hasPrefix("[") ? "[\(host.address)]" : host.address
        return (host.username.isEmpty ? "" : host.username + "@") + address + ":\(host.port)"
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.danger).frame(width: 42, height: 42)
                        .background(Palette.danger.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text("Delete host?", "删除主机？")).font(.system(size: 18, weight: .semibold))
                        Text(text("This action cannot be undone.", "此操作无法撤销。"))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }.padding(.top, 1)
                    Spacer(minLength: 0)
                    Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(IconButtonStyle()).focusEffectDisabled()
                        .accessibilityLabel(text("Cancel deletion", "取消删除"))
                        .accessibilityIdentifier("axon-host-delete-close")
                }
                HStack(spacing: 12) {
                    IconTile(symbol: "server.rack", color: Palette.blue, size: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(host.name.isEmpty ? host.address : host.name).font(.system(size: 13, weight: .semibold))
                            .lineLimit(2).truncationMode(.middle).accessibilityIdentifier("axon-host-delete-name")
                        Text(endpoint).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.middle).help(endpoint)
                            .accessibilityIdentifier("axon-host-delete-endpoint")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(14).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(Palette.sidebar).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.opacity(0.65), lineWidth: 1))
                Text(text("The saved connection and its own credentials will be removed.", "将移除已保存的连接配置及其独立凭据。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Spacer(minLength: 0)
            Rectangle().fill(Palette.border.opacity(0.6)).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                PreferencesActionButton(title: text("Cancel", "取消"), identifier: "axon-host-delete-cancel", action: cancel)
                    .frame(width: 96, height: 36)
                PreferencesActionButton(title: text("Delete host", "删除主机"), identifier: "axon-host-delete-confirm",
                                        prominent: true, destructive: true, action: confirm)
                    .frame(width: 112, height: 36)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 440, height: 304).background(Palette.card).foregroundStyle(Palette.text)
            .onExitCommand(perform: cancel)
    }
}
