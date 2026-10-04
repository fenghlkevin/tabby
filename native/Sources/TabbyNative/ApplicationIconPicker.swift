import AppKit
import SwiftUI

/// The app icon is a settings draft until the user saves. Each native button
/// owns the complete card, so its image, text and corners activate equally.
struct ApplicationIconPicker: View {
    @Binding var selection: String
    let chinese: Bool

    var body: some View {
        HStack(spacing: 12) {
            ForEach(["black", "white"], id: \.self) { style in
                ApplicationIconChoiceButton(style: style, selected: selection == style, chinese: chinese) {
                    selection = style
                }
                .frame(maxWidth: .infinity)
                .frame(height: ApplicationIconChoiceNativeButton.cardHeight)
            }
        }
    }
}

struct ApplicationIconChoiceButton: NSViewRepresentable {
    let style: String
    let selected: Bool
    let chinese: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> ApplicationIconChoiceNativeButton {
        ApplicationIconChoiceNativeButton()
    }

    func updateNSView(_ button: ApplicationIconChoiceNativeButton, context: Context) {
        button.iconStyle = style
        button.iconImage = ApplicationIconAppearance.image(for: style)
        button.title = style == "white" ? (chinese ? "白底黑标" : "White background") : (chinese ? "黑底白标" : "Black background")
        button.selected = selected
        button.state = selected ? .on : .off
        button.isEnabled = enabled
        button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier("axon-application-icon-" + style)
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilityLabel(button.title + (chinese ? "，黄色节点" : ", yellow node"))
        button.setAccessibilityValue(selected ? 1 : 0)
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ApplicationIconChoiceNativeButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: ApplicationIconChoiceNativeButton.cardHeight)
    }
}

final class ApplicationIconChoiceNativeButton: PreferencesRectNativeButton {
    static let cardHeight: CGFloat = 112
    var iconStyle = "black"
    var iconImage: NSImage?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if [36, 49, 76].contains(Int(event.keyCode)) { performClick(nil) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(selected || hovering || isHighlighted ? Palette.selected : Palette.field)
            .withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        path.fill()
        let imageSize: CGFloat = 64
        iconImage?.draw(in: NSRect(x: (bounds.width - imageSize) / 2, y: 10, width: imageSize, height: imageSize),
                        from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
        drawText(title, rect: NSRect(x: 8, y: 84, width: max(0, bounds.width - 16), height: 17),
                 color: NSColor(Palette.text).withAlphaComponent(isEnabled ? 1 : 0.45),
                 font: .systemFont(ofSize: 12, weight: selected ? .semibold : .regular), centered: true)
        if selected {
            drawText("✓", rect: NSRect(x: bounds.width - 26, y: 9, width: 18, height: 18),
                     color: NSColor(Palette.accent), font: .systemFont(ofSize: 14, weight: .bold), centered: true)
        }
        NSColor(selected ? Palette.accent : Palette.border).setStroke()
        path.lineWidth = selected ? 2 : 1; path.stroke()
        drawFocus()
    }
}
