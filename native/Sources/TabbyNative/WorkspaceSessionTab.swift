import SwiftUI
import AppKit

enum SessionTabAction: Int {
    case select, close, tools, duplicate, split, reconnect, moveLeft, moveRight, moveFirst, moveLast, closeOthers, separate
}

enum SessionTabPlacement: Equatable { case before, after, split }

enum WorkspaceSessionDrag {
    static let type = NSPasteboard.PasteboardType("com.axon.workspace-session")
    static func identifier(in pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }
}

/// Native pointer tracking keeps the label draggable while retaining separate close/tool hit areas.
/// SwiftUI Buttons inside an onDrag row capture mouse tracking before the row can start its drag.
struct NativeSessionTab: NSViewRepresentable {
    let id: UUID
    let title: String
    let selected: Bool
    let connected: Bool
    let dark: Bool
    let chinese: Bool
    let remote: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onAction: (SessionTabAction) -> Void
    let canDropSession: (UUID) -> Bool
    let onDropSession: (UUID, SessionTabPlacement) -> Void

    func makeNSView(context: Context) -> NativeSessionTabView { NativeSessionTabView() }
    func updateNSView(_ view: NativeSessionTabView, context: Context) {
        view.configure(id: id, title: title, selected: selected, connected: connected, dark: dark, chinese: chinese,
                       remote: remote, canMoveLeft: canMoveLeft, canMoveRight: canMoveRight)
        view.onAction = onAction
        view.canDropSession = canDropSession
        view.onDropSession = onDropSession
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeSessionTabView, context: Context) -> CGSize? {
        CGSize(width: selected ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive, height: 34)
    }
}

class NativeSessionTabView: NSView, NSDraggingSource {
    private(set) var sessionID = UUID()
    private(set) var title = ""
    private(set) var selected = false
    private var connected = false
    private var dark = false
    private var chinese = false
    private var remote = false
    private var windowWasMovable: Bool?
    private var canMoveLeft = false
    private var canMoveRight = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    private var downAction: SessionTabAction?
    private var dragStarted = false
    private(set) var dropPlacement: SessionTabPlacement?
    var onAction: ((SessionTabAction) -> Void)?
    var canDropSession: ((UUID) -> Bool)?
    var onDropSession: ((UUID, SessionTabPlacement) -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: selected ? WorkspaceTabDimensions.active : WorkspaceTabDimensions.inactive, height: 34)
    }
    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([WorkspaceSessionDrag.type])
        focusRingType = .none
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(id: UUID, title: String, selected: Bool, connected: Bool, dark: Bool, chinese: Bool,
                   remote: Bool, canMoveLeft: Bool, canMoveRight: Bool) {
        let sizeChanged = self.selected != selected
        sessionID = id; self.title = title; self.selected = selected; self.connected = connected
        self.dark = dark; self.chinese = chinese; self.remote = remote
        self.canMoveLeft = canMoveLeft; self.canMoveRight = canMoveRight
        toolTip = title + "\n" + text("Drag to reorder; right-click for tab actions", "拖动调整顺序；右键打开标签操作")
        setAccessibilityLabel(title)
        setAccessibilityValue(selected ? text("Selected", "已选择") : text("Tab", "标签"))
        setAccessibilityHelp(text("Drag to reorder; right-click for tab actions", "拖动调整顺序；右键打开标签操作"))
        var accessibilityActions = makeMenu().items.filter { !$0.isSeparatorItem && $0.isEnabled }.map { item in
            let action = SessionTabAction(rawValue: item.tag)
            return NSAccessibilityCustomAction(name: item.title) { [weak self] in
                guard let self, let action else { return false }
                return self.invokeAction(action)
            }
        }
        if selected {
            accessibilityActions.append(NSAccessibilityCustomAction(name: text("Terminal tools", "终端工具")) { [weak self] in self?.invokeAction(.tools) ?? false })
        }
        setAccessibilityCustomActions(accessibilityActions)
        if sizeChanged { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private func pointerAction(at point: NSPoint) -> SessionTabAction {
        if (hovering || selected), point.x >= 10, point.x < 30 { return .close }
        if selected, point.x >= bounds.width - 30, point.x < bounds.width - 10 { return .tools }
        return .select
    }
    override func mouseDown(with event: NSEvent) {
        windowWasMovable = window?.isMovable
        window?.isMovable = false
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point; downAction = pointerAction(at: point); dragStarted = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, downAction == .select, let downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        dragStarted = true
        beginTabDrag(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        // AppKit can deliver mouseUp before the native dragging session ends.
        // Keep the source window locked until draggingSession(endedAt:) completes.
        guard !dragStarted else { return }
        defer { resetPointer() }
        let point = convert(event.locationInWindow, from: nil)
        guard !dragStarted, bounds.contains(point), let downAction, pointerAction(at: point) == downAction else { return }
        onAction?(downAction)
    }
    private func resetPointer() { if let windowWasMovable { window?.isMovable = windowWasMovable }; windowWasMovable = nil; downPoint = nil; downAction = nil; dragStarted = false }

    func draggingPasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(sessionID.uuidString, forType: WorkspaceSessionDrag.type)
        return item
    }
    func beginTabDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: draggingPasteboardItem())
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap); image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishTabDrag()
    }
    func finishTabDrag() { resetPointer(); dropPlacement = nil; needsDisplay = true }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func droppedSession(_ sender: NSDraggingInfo) -> UUID? {
        guard sender.draggingSourceOperationMask.contains(.move), let id = WorkspaceSessionDrag.identifier(in: sender.draggingPasteboard),
              id != sessionID, canDropSession?(id) == true else { return nil }
        return id
    }
    private func placement(at x: CGFloat) -> SessionTabPlacement {
        if x < bounds.width * 0.25 { return .before }
        if x > bounds.width * 0.75 { return .after }
        return .split
    }
    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedSession(sender) != nil else { dropPlacement = nil; needsDisplay = true; return [] }
        let point = convert(sender.draggingLocation, from: nil)
        dropPlacement = placement(at: point.x)
        needsDisplay = true
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let event = NSApp.currentEvent { _ = autoscroll(with: event) }
        return updateDrop(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropPlacement = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { droppedSession(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropPlacement = nil; needsDisplay = true }
        guard let id = droppedSession(sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onDropSession?(id, placement(at: point.x))
        return true
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.minimumWidth = 240; menu.font = .systemFont(ofSize: 13); menu.autoenablesItems = false
        func add(_ action: SessionTabAction, _ title: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue; item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        add(.duplicate, text("Duplicate tab", "复制标签"))
        add(.separate, text("Separate tabs", "拆分为独立标签"))
        add(.split, text("Split terminal", "终端分屏"))
        if remote { add(.reconnect, text("Reconnect", "重新连接")) }
        menu.addItem(.separator())
        add(.moveLeft, text("Move tab left", "标签左移"), enabled: canMoveLeft)
        add(.moveRight, text("Move tab right", "标签右移"), enabled: canMoveRight)
        add(.moveFirst, text("Move tab to first", "移到最前"), enabled: canMoveLeft)
        add(.moveLast, text("Move tab to last", "移到最后"), enabled: canMoveRight)
        menu.addItem(.separator())
        add(.close, text("Close tab", "关闭标签"))
        add(.closeOthers, text("Close other tabs", "关闭其他标签"))
        return menu
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    @objc private func performMenuAction(_ item: NSMenuItem) {
        guard item.isEnabled, let action = SessionTabAction(rawValue: item.tag) else { return }
        _ = invokeAction(action)
    }
    @discardableResult private func invokeAction(_ action: SessionTabAction) -> Bool {
        if (action == .moveLeft || action == .moveFirst), !canMoveLeft { return false }
        if (action == .moveRight || action == .moveLast), !canMoveRight { return false }
        if action == .reconnect, !remote { return false }
        if action == .tools, !selected { return false }
        onAction?(action)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(Int(event.keyCode)) { onAction?(.select) }
        else if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift], event.keyCode == 123, canMoveLeft { onAction?(.moveLeft) }
        else if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift], event.keyCode == 124, canMoveRight { onAction?(.moveRight) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onAction?(.select); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        AxonMenuPopover.show(makeMenu(), from: self)
        return true
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: selected ? "#1B4540" : hovering ? "#45475F" : dark ? "#252738" : "#393C52").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let foreground = selected ? NSColor(hex: "#55C996") : NSColor(Palette.chromeText)
        drawSymbol(hovering || selected ? "xmark" : "terminal", in: NSRect(x: 12, y: 10, width: 16, height: 14), color: foreground)
        let rightReserve: CGFloat = selected ? 38 : 25
        let rect = NSRect(x: 38, y: 8, width: max(0, bounds.width - 38 - rightReserve), height: 18)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: foreground, .paragraphStyle: paragraph])
        if selected {
            drawSymbol("terminal.fill", in: NSRect(x: bounds.width - 28, y: 10, width: 16, height: 14), color: foreground)
        } else {
            (connected ? NSColor(Palette.accent) : NSColor(Palette.muted)).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 19, y: 14.5, width: 5, height: 5)).fill()
        }
        if dropPlacement == .split {
            NSColor(Palette.accent).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2; outline.stroke()
            drawSymbol("rectangle.split.2x1", in: NSRect(x: bounds.width - 28, y: 10, width: 16, height: 14), color: NSColor(Palette.accent))
        } else if let dropPlacement {
            NSColor(Palette.accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: dropPlacement == .before ? 1 : bounds.width - 4, y: 4, width: 3, height: bounds.height - 8), xRadius: 1.5, yRadius: 1.5).fill()
        } else if window?.firstResponder === self {
            NSColor(Palette.accent).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            outline.lineWidth = 1; outline.stroke()
        }
    }
    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [color]))
        (image.withSymbolConfiguration(configuration) ?? image).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
