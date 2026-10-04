import SwiftUI
import AppKit

/// Native buttons retain their entire rectangular hit area, including around the title.
struct AuthenticationSelector: View {
    @Binding var selection: String
    let passwordTitle: String
    let keyTitle: String
    var enabled = true

    var body: some View {
        BinaryChoiceControl(selection: $selection, firstValue: "password", firstTitle: passwordTitle,
                            secondValue: "key", secondTitle: keyTitle, enabled: enabled)
            .frame(height: BinaryChoiceView.controlHeight)
    }
}

/// Also suitable for the private-key text/file choice without changing its stored values.
struct BinaryChoiceControl: NSViewRepresentable {
    @Binding var selection: String
    let firstValue: String
    let firstTitle: String
    let secondValue: String
    let secondTitle: String
    var enabled = true
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> BinaryChoiceView {
        let view = BinaryChoiceView()
        view.onSelect = { [weak coordinator = context.coordinator] value in
            guard let coordinator, coordinator.parent.enabled, coordinator.parent.environmentEnabled else { return }
            coordinator.parent.selection = value
        }
        return view
    }
    func updateNSView(_ view: BinaryChoiceView, context: Context) {
        context.coordinator.parent = self
        view.configure(selection: selection, firstValue: firstValue, firstTitle: firstTitle,
                       secondValue: secondValue, secondTitle: secondTitle, enabled: enabled && environmentEnabled)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BinaryChoiceView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: BinaryChoiceView.controlHeight)
    }
    final class Coordinator {
        var parent: BinaryChoiceControl
        init(_ parent: BinaryChoiceControl) { self.parent = parent }
    }
}

final class BinaryChoiceView: NSView {
    static let controlHeight: CGFloat = 40
    let firstButton = BinaryChoiceButton()
    let secondButton = BinaryChoiceButton()
    var onSelect: ((String) -> Void)?
    private var values = ["password", "key"]
    private(set) var selection = "password"

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.controlHeight) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        for (index, button) in [firstButton, secondButton].enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
            button.moveSelection = { [weak self] direction in self?.moveSelection(direction) }
            addSubview(button)
        }
        firstButton.nextKeyView = secondButton
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(selection: String, firstValue: String, firstTitle: String,
                   secondValue: String, secondTitle: String, enabled: Bool) {
        values = [firstValue, secondValue]
        self.selection = selection
        setAccessibilityLabel(firstTitle + " / " + secondTitle)
        for (button, title, value) in [(firstButton, firstTitle, firstValue), (secondButton, secondTitle, secondValue)] {
            button.title = title
            button.selected = selection == value
            button.isEnabled = enabled
            button.setAccessibilityLabel(title)
            button.setAccessibilityValue(button.selected ? 1 : 0)
            button.needsDisplay = true
        }
        needsDisplay = true
        needsLayout = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let inset: CGFloat = 2
        let gap: CGFloat = 4
        let width = max(0, (bounds.width - inset * 2 - gap) / 2)
        firstButton.frame = NSRect(x: inset, y: inset, width: width, height: max(0, bounds.height - inset * 2))
        secondButton.frame = NSRect(x: inset + width + gap, y: inset, width: width, height: max(0, bounds.height - inset * 2))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Palette.field).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    @objc private func choose(_ button: NSButton) {
        guard button.isEnabled, values.indices.contains(button.tag) else { return }
        selection = values[button.tag]
        firstButton.selected = button.tag == 0
        secondButton.selected = button.tag == 1
        for segment in [firstButton, secondButton] {
            segment.setAccessibilityValue(segment.selected ? 1 : 0)
            segment.needsDisplay = true
        }
        onSelect?(selection)
    }
    private func moveSelection(_ direction: Int) {
        let button = direction < 0 ? firstButton : secondButton
        guard button.isEnabled else { return }
        window?.makeFirstResponder(button)
        button.performClick(nil)
    }
}

final class BinaryChoiceButton: NSButton {
    var selected = false
    var moveSelection: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        setAccessibilityRole(.radioButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 123, 126: moveSelection?(-1)
        case 124, 125: moveSelection?(1)
        case 36, 49, 76: performClick(nil)
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = selected ? NSColor(Palette.accent) : NSColor(Palette.field)
        background.withAlphaComponent(isEnabled ? (cell?.isHighlighted == true ? 0.7 : 1) : 0.45).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let foreground = selected ? NSColor.white : NSColor(Palette.text)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
            .foregroundColor: foreground.withAlphaComponent(isEnabled ? 1 : 0.45)
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: max(0, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self && isEnabled {
            NSColor(Palette.accent).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            outline.lineWidth = 2
            outline.stroke()
            if selected {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
                inner.lineWidth = 1
                inner.stroke()
            }
        }
    }
}
