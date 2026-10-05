import AppKit
import SwiftUI

/// Application chrome stays independent of the user's terminal ANSI theme.
enum TerminalChrome {
    static let background = Color(hex: "#252A3B")
    static let header = Palette.chrome
    static let card = Color(hex: "#30364A")
    static let field = Color(hex: "#202536")
    static let border = Color(hex: "#41475E")
    static let text = Palette.chromeText
    static let muted = Color(hex: "#A1AAC1")
    static let accent = Color(hex: "#78B6F4")
}

/// A stable-width sidebar that occupies the complete workspace height.
/// The header stays visible while long content scrolls within the sidebar.
struct TerminalToolsPanel: View {
    static let width: CGFloat = 320
    static let headerHeight: CGFloat = 132
    static let contentPadding: CGFloat = 16

    @EnvironmentObject var store: AppStore
    @Binding var selection: String
    @Binding var isVisible: Bool
    let availableHeight: CGFloat

    private var bodyHeight: CGFloat { max(0, availableHeight - Self.headerHeight - 1) }
    private var session: TerminalSession? { store.sessions.first { $0.id == store.activeSession } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, Self.contentPadding)
                .padding(.vertical, 14)
                .frame(height: Self.headerHeight)
                .background(TerminalChrome.header)
            Rectangle().fill(TerminalChrome.border.opacity(0.7)).frame(height: 1)
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
        .foregroundStyle(TerminalChrome.text)
        .colorScheme(.dark)
        .background(TerminalChrome.background)
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Rectangle().fill(TerminalChrome.border).frame(width: 1)
                LinearGradient(colors: [Color.black.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("axon-terminal-tools-panel")
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.text("Terminal tools", "终端工具")).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(session?.connected == true ? Color(hex: "#55C996") : TerminalChrome.muted).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(session?.displayTitle ?? store.text("No active session", "尚未选择会话"))
                            .font(.system(size: 11)).foregroundStyle(TerminalChrome.muted).lineLimit(1).truncationMode(.middle)
                            .help(session?.displayTitle ?? "").accessibilityIdentifier("axon-terminal-tools-session")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                TerminalToolButton(symbol: "xmark", selected: false,
                                   title: store.text("Close terminal tools", "关闭终端工具"), identifier: "axon-terminal-tools-close") { isVisible = false }
                    .frame(width: 34, height: 34)
            }.frame(height: 36)
            HStack(spacing: 4) {
                tab("productivity", icon: "paperplane", title: store.text("Session tools", "会话工具"), caption: store.text("Tools", "会话"))
                tab("status", icon: "waveform.path.ecg", title: store.text("Status", "状态"), caption: store.text("Status", "状态"))
                tab("snippets", icon: "curlybraces", title: store.text("Snippets", "代码片段"), caption: store.text("Snippets", "片段"))
                tab("theme", icon: "paintpalette", title: store.text("Terminal settings", "终端设置"), caption: store.text("Style", "外观"))
            }.padding(4).background(TerminalChrome.field).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(TerminalChrome.border.opacity(0.45), lineWidth: 1))
        }
    }

    private func tab(_ id: String, icon: String, title: String, caption: String) -> some View {
        TerminalToolButton(symbol: icon, caption: caption, selected: selection == id,
                           title: title, identifier: "axon-terminal-tool-" + id) { selection = id }
            .frame(maxWidth: .infinity).frame(height: 48)
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
            Text(store.text("Quick actions", "快捷操作")).font(.system(size: 14, weight: .semibold))
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
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(TerminalChrome.accent).frame(width: 22)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(TerminalChrome.muted)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12).background(TerminalChrome.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(TerminalChrome.border.opacity(0.45), lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("Font & cursor", "字体与光标")).font(.system(size: 12)).foregroundStyle(TerminalChrome.muted)
            Text(store.workspace.preferences.fontName + " · " + TerminalFontSizeNativeEditor.display(store.workspace.preferences.fontSize) + " pt")
                .font(.system(size: 14, weight: .medium))
            TerminalPanelActionButton(title: store.text("Font & cursor settings", "字体与光标设置"), identifier: "axon-terminal-open-font-settings") {
                isVisible = false; store.openPreferences(.terminal)
            }.frame(height: 36)
            Rectangle().fill(TerminalChrome.border.opacity(0.6)).frame(height: 1).padding(.vertical, 2)
            Text(store.text("Terminal colors", "终端配色")).font(.system(size: 12)).foregroundStyle(TerminalChrome.muted)
            TerminalColorPreview(preferences: store.workspace.preferences, identifier: "axon-terminal-tools-color-preview", chinese: store.chinese)
            Text(TerminalTheme.selected(store.workspace.preferences).name).font(.system(size: 12))
            TerminalPanelActionButton(title: store.text("Choose terminal colors", "选择终端配色"), identifier: "axon-terminal-open-color-settings") {
                isVisible = false; store.openPreferences(.appearance)
            }.frame(height: 36)
            Text(store.text("Edit and save in Settings to apply to all open terminals.", "在设置中编辑并保存，即可应用到所有已打开终端。"))
                .font(.system(size: 11)).foregroundStyle(TerminalChrome.muted).fixedSize(horizontal: false, vertical: true)
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
        button.selected = isVisible
        button.toolTip = title; button.needsDisplay = true
    }
}

final class TerminalToolsToggleNativeButton: PreferencesRectNativeButton {
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            NSColor(selected ? TerminalChrome.accent.opacity(0.16) : TerminalChrome.border).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if let image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [NSColor(selected ? TerminalChrome.accent : TerminalChrome.text)])) ?? image
            tinted.draw(in: NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawFocus()
    }
}

private struct TerminalToolButton: NSViewRepresentable {
    let symbol: String
    var caption = ""
    let selected: Bool
    let title: String
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalToolNativeButton { TerminalToolNativeButton() }
    func updateNSView(_ button: TerminalToolNativeButton, context: Context) {
        button.symbol = symbol; button.caption = caption; button.selected = selected
        button.actionBlock = action; button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : "")
        button.toolTip = title; button.needsDisplay = true
    }
}

final class TerminalToolNativeButton: PreferencesRectNativeButton {
    var symbol = ""
    var caption = ""
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            NSColor(selected ? TerminalChrome.accent.opacity(isHighlighted ? 0.12 : 0.16) : TerminalChrome.card.opacity(isHighlighted ? 0.72 : 1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let foreground = NSColor(selected ? TerminalChrome.accent : TerminalChrome.muted)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            tinted.draw(in: NSRect(x: (bounds.width - 18) / 2, y: caption.isEmpty ? (bounds.height - 18) / 2 : 5, width: 18, height: 18),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if !caption.isEmpty {
            drawText(caption, rect: NSRect(x: 2, y: 25, width: bounds.width - 4, height: 14), color: foreground,
                     font: .systemFont(ofSize: 10, weight: selected ? .semibold : .medium), centered: true)
        }
        drawFocus()
    }
}

private struct TerminalPanelActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalPanelActionNativeButton { TerminalPanelActionNativeButton() }
    func updateNSView(_ button: TerminalPanelActionNativeButton, context: Context) {
        button.title = title; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title); button.needsDisplay = true
    }
}

private final class TerminalPanelActionNativeButton: PreferencesRectNativeButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hovering || isHighlighted ? TerminalChrome.border : TerminalChrome.card).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        drawText(title, rect: NSRect(x: 12, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 24), height: 17),
                 color: NSColor(TerminalChrome.accent), font: .systemFont(ofSize: 12, weight: .medium))
        drawFocus()
    }
}
