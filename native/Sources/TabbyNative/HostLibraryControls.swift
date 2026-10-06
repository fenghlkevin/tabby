import AppKit
import SwiftUI

/// Both choices are always visible; the highlighted symbol describes the
/// current layout, so it does not look like a reversed single-action button.
struct HostLibraryLayoutPicker: NSViewRepresentable {
    @Binding var grid: Bool
    var chinese: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2; control.trackingMode = .selectOne; control.segmentStyle = .rounded
        control.target = context.coordinator; control.action = #selector(Coordinator.selectLayout(_:))
        control.identifier = NSUserInterfaceItemIdentifier("host-layout-picker")
        control.setAccessibilityIdentifier("host-layout-picker")
        for segment in 0..<2 {
            control.setImage(NSImage(systemSymbolName: segment == 0 ? "square.grid.2x2" : "list.bullet", accessibilityDescription: nil), forSegment: segment)
            control.setWidth(32, forSegment: segment)
        }
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = { grid = $0 }
        control.selectedSegment = grid ? 0 : 1
        control.setToolTip(chinese ? "网格视图" : "Grid view", forSegment: 0)
        control.setToolTip(chinese ? "列表视图" : "List view", forSegment: 1)
        control.setAccessibilityLabel(chinese ? "主机显示方式" : "Host layout")
        control.setAccessibilityValue(grid ? (chinese ? "网格视图" : "Grid view") : (chinese ? "列表视图" : "List view"))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { CGSize(width: 70, height: 32) }
    @MainActor final class Coordinator: NSObject {
        var choose: (Bool) -> Void = { _ in }
        @objc func selectLayout(_ sender: NSSegmentedControl) { choose(sender.selectedSegment == 0) }
    }
}

struct GroupSettingToggle: NSViewRepresentable {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    var title: String
    var label: String
    var identifier: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = AxonCheckboxNativeButton()
        button.target = context.coordinator; button.action = #selector(Coordinator.toggle(_:)); button.title = title
        button.font = NSFont.systemFont(ofSize: 11); button.setButtonType(.switch); button.isBordered = false
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.choose = { isOn = $0 }
        button.title = title; button.state = isOn ? .on : .off
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 96, height: 22) }
    @MainActor final class Coordinator: NSObject {
        var choose: (Bool) -> Void = { _ in }
        @objc func toggle(_ sender: NSButton) { choose(sender.state == .on) }
    }
}

final class AxonCheckboxNativeButton: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(state == .on ? Palette.selected : Palette.sidebar).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        AxonSelectionDrawing.mark(in: NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14), selected: state == .on, enabled: isEnabled)
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(Palette.text).withAlphaComponent(isEnabled ? 1 : 0.45)]
        text.draw(at: NSPoint(x: 28, y: (bounds.height - text.size(withAttributes: attributes).height) / 2), withAttributes: attributes)
    }
}
