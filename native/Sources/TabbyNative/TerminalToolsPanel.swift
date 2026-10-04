import AppKit
import SwiftUI

/// A stable-width sidebar that occupies the complete workspace height.
/// The header stays visible while long content scrolls within the sidebar.
struct TerminalToolsPanel: View {
    static let width: CGFloat = 320
    static let headerHeight: CGFloat = 58
    static let contentPadding: CGFloat = 16

    @EnvironmentObject var store: AppStore
    @Binding var selection: String
    @Binding var isVisible: Bool
    let availableHeight: CGFloat

    private var bodyHeight: CGFloat { max(0, availableHeight - Self.headerHeight - 1) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, Self.contentPadding)
                .frame(height: Self.headerHeight)
            Divider().overlay(Color(hex: "#303249"))
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Self.contentPadding)
                    .accessibilityIdentifier("axon-terminal-tools-content-" + selection)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: bodyHeight)
        }
        .frame(width: Self.width, height: max(0, availableHeight), alignment: .top)
        .foregroundStyle(Palette.chromeText)
        .colorScheme(.dark)
        .background(Color(hex: "#252738"))
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: "#303249")).frame(width: 1) }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("axon-terminal-tools-panel")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            tab("productivity", icon: "paperplane.fill", title: store.text("Session tools", "会话工具"))
            tab("status", icon: "waveform.path.ecg", title: store.text("Status", "状态"))
            tab("snippets", icon: "curlybraces", title: store.text("Snippets", "代码片段"))
            tab("theme", icon: "paintpalette.fill", title: store.text("Terminal settings", "终端设置"))
            Spacer(minLength: 8)
            TerminalToolButton(symbol: "xmark", selected: false, tint: NSColor(Palette.chromeText),
                               title: store.text("Close terminal tools", "关闭终端工具"), identifier: "axon-terminal-tools-close") { isVisible = false }
                .frame(width: 34, height: 34)
        }
    }

    private func tab(_ id: String, icon: String, title: String) -> some View {
        TerminalToolButton(symbol: icon, selected: selection == id, tint: NSColor(hex: store.workspace.preferences.foreground),
                           title: title, identifier: "axon-terminal-tool-" + id) { selection = id }
            .frame(width: 34, height: 34)
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case "snippets":
            SnippetTerminalPanel(sessionID: store.activeSession, scrollsInternally: false)
        case "status":
            MonitoringTerminalPanel(center: store.monitoring, sessionID: store.activeSession, scrollsInternally: false)
        case "productivity":
            sessionTools
        default:
            terminalSettings
        }
    }

    private var sessionTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.text("Session tools", "会话工具")).font(.system(size: 14, weight: .semibold))
            sessionAction(store.text("Split terminal", "终端分屏"), symbol: "rectangle.split.2x1") { store.split() }
            sessionAction(store.text("Find in terminal", "搜索终端"), symbol: "magnifyingglass") {
                let item = NSMenuItem()
                item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                store.sessions.first(where: { $0.id == store.activeSession })?.terminal?.performFindPanelAction(item)
            }
            if let session = store.sessions.first(where: { $0.id == store.activeSession }), session.host != nil {
                sessionAction(store.text("Reconnect", "重新连接"), symbol: "arrow.clockwise") { session.reconnect() }
            }
        }
    }

    private func sessionAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("Font & cursor", "字体与光标")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(store.workspace.preferences.fontName + " · " + TerminalFontSizeNativeEditor.display(store.workspace.preferences.fontSize) + " pt")
                .font(.system(size: 14, weight: .medium))
            PreferencesActionButton(title: store.text("Font & cursor settings", "字体与光标设置"), identifier: "axon-terminal-open-font-settings") {
                isVisible = false; store.openPreferences(.terminal)
            }.frame(height: 36)
            Divider().overlay(Color(hex: "#303249")).padding(.vertical, 2)
            Text(store.text("Terminal colors", "终端配色")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            TerminalColorPreview(preferences: store.workspace.preferences, identifier: "axon-terminal-tools-color-preview", chinese: store.chinese)
            Text(TerminalTheme.selected(store.workspace.preferences).name).font(.system(size: 12))
            PreferencesActionButton(title: store.text("Choose terminal colors", "选择终端配色"), identifier: "axon-terminal-open-color-settings") {
                isVisible = false; store.openPreferences(.appearance)
            }.frame(height: 36)
            Text(store.text("Edit and save in Settings to apply to all open terminals.", "在设置中编辑并保存，即可应用到所有已打开终端。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TerminalToolsToggleButton: NSViewRepresentable {
    let isVisible: Bool
    let title: String
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalToolsToggleNativeButton { TerminalToolsToggleNativeButton() }
    func updateNSView(_ button: TerminalToolsToggleNativeButton, context: Context) {
        button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier("axon-terminal-tools-toggle")
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isVisible ? "Expanded" : "Collapsed")
        button.toolTip = title; button.needsDisplay = true
    }
}

final class TerminalToolsToggleNativeButton: PreferencesRectNativeButton {
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor(hex: "#45475F").setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if let image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [NSColor(Palette.chromeText)])) ?? image
            tinted.draw(in: NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawFocus()
    }
}

private struct TerminalToolButton: NSViewRepresentable {
    let symbol: String
    let selected: Bool
    let tint: NSColor
    let title: String
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalToolNativeButton { TerminalToolNativeButton() }
    func updateNSView(_ button: TerminalToolNativeButton, context: Context) {
        button.symbol = symbol; button.selected = selected; button.tint = tint
        button.actionBlock = action; button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : "")
        button.toolTip = title; button.needsDisplay = true
    }
}

final class TerminalToolNativeButton: PreferencesRectNativeButton {
    var symbol = ""
    var tint = NSColor(Palette.chromeText)
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            NSColor(hex: selected ? "#1B4540" : "#303249").withAlphaComponent(isHighlighted ? 0.72 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let foreground = selected ? tint : NSColor(hex: "#969BB0")
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            tinted.draw(in: NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawFocus()
    }
}
