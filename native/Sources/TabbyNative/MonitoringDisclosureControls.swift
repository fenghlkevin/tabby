import AppKit
import SwiftUI

/// A disclosure header has one native action region across its entire row.
/// Content stays conditional so collapsed cards are absent from the AX tree.
struct MonitoringDisclosureGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let identifier: String
    let expandedAccessibilityValue: String
    let collapsedAccessibilityValue: String
    let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, identifier: String,
         expandedAccessibilityValue: String = "Expanded", collapsedAccessibilityValue: String = "Collapsed",
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self._isExpanded = isExpanded; self.identifier = identifier
        self.expandedAccessibilityValue = expandedAccessibilityValue; self.collapsedAccessibilityValue = collapsedAccessibilityValue
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitoringDisclosureButton(title: title, expanded: isExpanded, identifier: identifier,
                                       accessibilityValue: isExpanded ? expandedAccessibilityValue : collapsedAccessibilityValue) {
                isExpanded.toggle()
            }
            .frame(maxWidth: .infinity)
            .frame(height: MonitoringDisclosureNativeButton.height)
            if isExpanded { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonitoringDisclosureButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let expanded: Bool
    let identifier: String
    let accessibilityValue: String
    let action: () -> Void

    func makeNSView(context: Context) -> MonitoringDisclosureNativeButton { MonitoringDisclosureNativeButton() }
    func updateNSView(_ button: MonitoringDisclosureNativeButton, context: Context) {
        button.title = title; button.expanded = expanded; button.isEnabled = isEnabled; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title); button.setAccessibilityValue(accessibilityValue); button.setAccessibilityExpanded(expanded)
        button.needsDisplay = true
    }
}

/// Like the other rectangular native controls, this remains one explicit
/// AXButton node; drawing the chevron and label adds no child hit regions.
final class MonitoringDisclosureNativeButton: PreferencesRectNativeButton {
    static let height: CGFloat = 32
    var expanded = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hovering || isHighlighted ? Palette.selected : Palette.field)
            .withAlphaComponent(isEnabled ? (isHighlighted ? 0.75 : 1) : 0.4).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: AxonButtonMetrics.radius, yRadius: AxonButtonMetrics.radius).fill()
        let foreground = NSColor(Palette.text).withAlphaComponent(isEnabled ? 1 : 0.45)
        if let image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            tinted.draw(in: NSRect(x: 10, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawText(title, rect: NSRect(x: 30, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 40), height: 17),
                 color: foreground, font: .systemFont(ofSize: 12))
        drawFocus()
    }
}
