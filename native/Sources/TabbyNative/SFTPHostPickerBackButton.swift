import AppKit
import SwiftUI

/// The heading is also the return action, with one rectangular target around
/// its arrow, text and padding instead of a separate tiny arrow hit area.
struct SFTPHostPickerBackButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    var title: String
    var label: String
    var action: () -> Void
    func makeNSView(context: Context) -> SFTPHostPickerNativeBackButton { SFTPHostPickerNativeBackButton(frame: .zero) }
    func updateNSView(_ button: SFTPHostPickerNativeBackButton, context: Context) {
        button.title = title; button.isEnabled = enabled; button.invoke = action
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier("sftp-host-picker-back")
        button.setAccessibilityIdentifier("sftp-host-picker-back")
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SFTPHostPickerNativeBackButton, context: Context) -> CGSize? { CGSize(width: 150, height: 40) }
}

final class SFTPHostPickerNativeBackButton: NSButton {
    var invoke: () -> Void = {}
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 40) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryChange); isBordered = false
        font = .systemFont(ofSize: 16, weight: .semibold)
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { if isEnabled { invoke() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor(Palette.selected).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let textColor = NSColor(Palette.text).withAlphaComponent(isEnabled ? 1 : 0.4)
        let icon = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        let imageRect = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        icon.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4)
        textColor.setFill()
        let text = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: textColor])
        text.draw(in: NSRect(x: 38, y: (bounds.height - text.size().height) / 2, width: bounds.width - 46, height: text.size().height))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}
