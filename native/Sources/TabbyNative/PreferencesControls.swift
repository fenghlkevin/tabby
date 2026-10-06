import AppKit
import SwiftUI

/// The NSButton owns the entire rectangular row, including its padding. Drawing
/// the label does not introduce child hit regions or a competing SwiftUI gesture.
struct PreferencesNavigationButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let selected: Bool
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesNavigationNativeButton { PreferencesNavigationNativeButton() }
    func updateNSView(_ button: PreferencesNavigationNativeButton, context: Context) {
        button.title = title; button.symbol = symbol; button.selected = selected; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : "")
        button.needsDisplay = true
    }
}

class PreferencesRectNativeButton: NSButton {
    var actionBlock: (() -> Void)?
    var prominent = false
    var selected = false
    var hovering = false
    var destructive = false
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    init() {
        super.init(frame: .zero); setButtonType(.momentaryPushIn); isBordered = false; target = self; action = #selector(activate); focusRingType = .none
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    @objc private func activate() { if isEnabled { actionBlock?() } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, actionBlock != nil else { return false }
        performClick(nil)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = prominent ? NSColor(destructive ? Palette.danger : Palette.accent) : NSColor(hovering || selected || isHighlighted ? Palette.selected : Palette.field)
        background.withAlphaComponent(isEnabled ? (isHighlighted ? 0.72 : 1) : 0.4).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: AxonButtonMetrics.radius, yRadius: AxonButtonMetrics.radius).fill()
        let textColor = prominent ? NSColor.white : destructive ? NSColor.systemRed : NSColor(Palette.text)
        drawText(title, rect: NSRect(x: 8, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 16), height: 17), color: textColor.withAlphaComponent(isEnabled ? 1 : 0.45), font: .systemFont(ofSize: 12, weight: .semibold), centered: true)
        drawFocus()
    }
    func drawText(_ text: String, rect: NSRect, color: NSColor, font: NSFont, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    func drawFocus() {
        if window?.firstResponder === self {
            NSColor(Palette.accent).setStroke(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6); path.lineWidth = 2; path.stroke()
        }
    }
}
final class PreferencesNavigationNativeButton: PreferencesRectNativeButton {
    var symbol = ""
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            NSColor(selected ? Palette.selected : Palette.field).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let foreground = NSColor(selected ? Palette.text : Palette.muted)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            tinted.draw(in: NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawText(title, rect: NSRect(x: 40, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 46), height: 17), color: foreground, font: .systemFont(ofSize: 12, weight: selected ? .semibold : .regular))
        drawFocus()
    }
}

struct PreferencesActionButton: NSViewRepresentable {
    let title: String
    var identifier = ""
    var prominent = false
    var destructive = false
    var enabled = true
    let action: () -> Void
    @Environment(\.isEnabled) private var environmentEnabled
    func makeNSView(context: Context) -> PreferencesRectNativeButton { PreferencesRectNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.prominent = prominent; button.destructive = destructive; button.isEnabled = enabled && environmentEnabled; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title); button.needsDisplay = true
    }
}

struct TerminalThemeCardButton: NSViewRepresentable {
    let theme: TerminalTheme
    let selected: Bool
    let chinese: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> TerminalThemeCardNativeButton { TerminalThemeCardNativeButton() }
    func updateNSView(_ button: TerminalThemeCardNativeButton, context: Context) {
        button.theme = theme; button.selected = selected; button.chinese = chinese; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier("axon-theme-card-" + theme.id)
        button.setAccessibilityLabel(theme.name + (selected ? (chinese ? "，已选择" : ", selected") : "")); button.refreshLabels(); button.needsDisplay = true
    }
}
final class TerminalThemeCardNativeButton: PreferencesRectNativeButton {
    var theme = TerminalTheme.all[0]
    var chinese = false
    private let promptLabel = ThemeCardLabel("axon@server ~ %", font: .monospacedSystemFont(ofSize: 11, weight: .medium))
    private let commandLabel = ThemeCardLabel("ls  README.md", font: .monospacedSystemFont(ofSize: 11, weight: .regular))
    private let nameLabel = ThemeCardLabel("", font: .systemFont(ofSize: 12, weight: .semibold))
    private let captionLabel = ThemeCardLabel("", font: .systemFont(ofSize: 10))
    private let selectedLabel = ThemeCardLabel("✓", font: .systemFont(ofSize: 14, weight: .bold))

    override init() {
        super.init()
        for label in [promptLabel, commandLabel, nameLabel, captionLabel, selectedLabel] { addSubview(label) }
        refreshLabels()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Native labels own stable text/font attributes. Creating NSString drawing
    /// attributes inside lazy-grid redraws triggered a CoreText exception when
    /// cards were scrolled into view on macOS 27.
    func refreshLabels() {
        promptLabel.textColor = NSColor(hex: theme.foreground)
        commandLabel.textColor = NSColor(hex: theme.previewANSI[2])
        nameLabel.stringValue = theme.name; nameLabel.textColor = NSColor(Palette.text)
        captionLabel.stringValue = theme.isCustom ? (chinese ? "自定义方案" : "Custom scheme") : theme.isLight ? (chinese ? "浅色" : "Light") : (chinese ? "深色" : "Dark")
        captionLabel.textColor = NSColor(Palette.muted)
        selectedLabel.textColor = NSColor(Palette.accent); selectedLabel.isHidden = true
        needsLayout = true
    }
    override func layout() {
        super.layout()
        promptLabel.frame = NSRect(x: 13, y: 14, width: max(0, bounds.width - 26), height: 16)
        commandLabel.frame = NSRect(x: 13, y: 34, width: max(0, bounds.width - 26), height: 15)
        nameLabel.frame = NSRect(x: 12, y: 97, width: max(0, bounds.width - 38), height: 17)
        captionLabel.frame = NSRect(x: 12, y: 116, width: max(0, bounds.width - 24), height: 15)
        selectedLabel.frame = NSRect(x: max(0, bounds.width - 26), y: 96, width: min(18, max(0, bounds.width)), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 2, bounds.height > 2 else { return }
        let inset = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10); path.addClip()
        NSColor(hex: theme.background).setFill(); inset.fill()
        let width = max(0, (bounds.width - 26 - 7 * 3) / 8)
        for index in 0..<16 where width > 0 {
            NSColor(hex: theme.previewANSI[index]).setFill()
            NSBezierPath(roundedRect: NSRect(x: 13 + CGFloat(index % 8) * (width + 3), y: index < 8 ? 57 : 69, width: width, height: 8), xRadius: 2, yRadius: 2).fill()
        }
        NSColor(selected || hovering || isHighlighted ? Palette.selected : Palette.sidebar).setFill()
        NSRect(x: 0, y: 88, width: bounds.width, height: max(0, bounds.height - 88)).fill()
        NSGraphicsContext.restoreGraphicsState()
        AxonSelectionDrawing.mark(in: NSRect(x: bounds.width - 26, y: 96, width: 14, height: 14), selected: selected, enabled: isEnabled)
        NSColor(Palette.border).setStroke(); path.lineWidth = 1; path.stroke(); drawFocus()
    }
}

/// Labels stay inside the native button without taking its mouse hit region,
/// keyboard focus, or accessibility identity away from the whole card.
private final class ThemeCardLabel: NSTextField {
    init(_ text: String, font: NSFont) {
        super.init(frame: .zero)
        stringValue = text; self.font = font
        isBordered = false; isBezeled = false; drawsBackground = false; isEditable = false; isSelectable = false
        lineBreakMode = .byTruncatingTail; maximumNumberOfLines = 1; focusRingType = .none
        cell?.wraps = false; cell?.usesSingleLineMode = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AxonChoiceCardNativeButton: PreferencesRectNativeButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(selected || hovering || isHighlighted ? Palette.selected : Palette.sidebar).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        AxonSelectionDrawing.mark(in: NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14), selected: selected, enabled: isEnabled)
        drawText(title, rect: NSRect(x: 34, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 44), height: 17), color: NSColor(Palette.text).withAlphaComponent(isEnabled ? 1 : 0.45), font: .systemFont(ofSize: 12))
        drawFocus()
    }
}
