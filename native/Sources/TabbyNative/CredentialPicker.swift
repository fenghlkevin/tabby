import SwiftUI
import AppKit

/// Draw the field in AppKit: a SwiftUI Menu can replace its custom label styling.
struct CredentialPicker: NSViewRepresentable {
    @Binding var selectedID: UUID?
    let credentials: [VaultCredential]
    let chinese: Bool
    let enabled: Bool
    let onNew: () -> Void
    var allowsCreation = true
    var independentTitle: String?
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CredentialPickerButton {
        let button = CredentialPickerButton()
        button.onSelect = { [weak coordinator = context.coordinator] id in
            guard let coordinator, coordinator.parent.enabled, coordinator.parent.environmentEnabled else { return }
            coordinator.parent.selectedID = id
        }
        button.onNew = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.parent.enabled, coordinator.parent.environmentEnabled else { return }
            coordinator.parent.onNew()
        }
        return button
    }
    func updateNSView(_ button: CredentialPickerButton, context: Context) {
        context.coordinator.parent = self
        button.configure(selectedID: selectedID, credentials: credentials, chinese: chinese,
                         enabled: enabled && environmentEnabled, allowsCreation: allowsCreation, independentTitle: independentTitle)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CredentialPickerButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: CredentialPickerButton.fieldHeight)
    }
    final class Coordinator {
        var parent: CredentialPicker
        init(_ parent: CredentialPicker) { self.parent = parent }
    }
}

final class CredentialPickerButton: NSButton {
    static let fieldHeight: CGFloat = 38
    private(set) var selectedID: UUID?
    private var credentials: [VaultCredential] = []
    private var chinese = false
    private var allowsCreation = true
    private var independentTitle: String?
    var onSelect: ((UUID?) -> Void)?
    var onNew: (() -> Void)?
    var symbolName: String { selectedID == nil ? "person.fill" : "key.fill" }
    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    private var currentTitle: String {
        guard let selectedID else { return independentTitle ?? text("Set up for this host", "仅用于此主机") }
        return credentials.first { $0.id == selectedID }?.name ?? text("Credential unavailable", "凭据已不存在")
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.fieldHeight) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(openMenu)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(selectedID: UUID?, credentials: [VaultCredential], chinese: Bool, enabled: Bool, allowsCreation: Bool = true, independentTitle: String? = nil) {
        self.selectedID = selectedID
        self.credentials = credentials
        self.chinese = chinese
        self.allowsCreation = allowsCreation
        self.independentTitle = independentTitle
        isEnabled = enabled
        updateTitle()
    }
    private func updateTitle() {
        title = currentTitle
        setAccessibilityLabel(text("Choose login credentials", "选择登录凭据"))
        setAccessibilityValue(title)
        needsDisplay = true
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = bounds.width
        let independent = NSMenuItem(title: independentTitle ?? text("Set up for this host", "仅用于此主机"), action: #selector(selectIndependent), keyEquivalent: "")
        independent.image = NSImage(systemSymbolName: "person", accessibilityDescription: nil)
        independent.target = self
        independent.state = selectedID == nil ? .on : .off
        independent.isEnabled = isEnabled
        menu.addItem(independent)
        for credential in credentials {
            let item = NSMenuItem(title: credential.name + " · " + credential.username, action: #selector(selectShared(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            item.target = self
            item.representedObject = credential.id
            item.state = selectedID == credential.id ? .on : .off
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        if allowsCreation {
            menu.addItem(.separator())
            let create = NSMenuItem(title: text("New shared credential…", "新建共享凭据…"), action: #selector(createShared), keyEquivalent: "")
            create.target = self
            create.isEnabled = isEnabled
            menu.addItem(create)
        }
        return menu
    }
    @objc private func openMenu() {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        AxonMenuPopover.show(makeMenu(), from: self)
    }
    @objc private func selectIndependent() { choose(nil) }
    @objc private func selectShared(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, credentials.contains(where: { $0.id == id }) else { return }
        choose(id)
    }
    private func choose(_ id: UUID?) {
        guard isEnabled else { return }
        selectedID = id
        updateTitle()
        onSelect?(id)
    }
    @objc private func createShared() {
        guard isEnabled else { return }
        onNew?()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if [36, 49, 76, 125].contains(Int(event.keyCode)) { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true; return result
    }
    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        let background = cell?.isHighlighted == true && isEnabled ? Palette.selected : Palette.field
        NSColor(background).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Palette.text).withAlphaComponent(opacity), .paragraphStyle: paragraph]
        let lineHeight = (title as NSString).size(withAttributes: attributes).height
        let rect = NSRect(x: 36, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - 68), height: lineHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (title as NSString).draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        drawSymbol(symbolName, in: NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14), opacity: opacity)
        drawSymbol("chevron.down", in: NSRect(x: max(0, bounds.width - 23), y: (bounds.height - 10) / 2, width: 10, height: 10), opacity: opacity)
        if window?.firstResponder === self && isEnabled {
            NSColor(Palette.accent).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            outline.lineWidth = 1.5; outline.stroke()
        }
    }
    private func drawSymbol(_ name: String, in rect: NSRect, opacity: CGFloat) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [NSColor(Palette.muted)]))
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
    }
}
