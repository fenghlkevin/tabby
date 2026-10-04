import AppKit
import SwiftUI

/// Every tab owns its entire 38-point rectangle. Drawing the icon and text
/// inside one native control keeps padding, labels and corners equally usable.
struct MonitoringModuleNavigation: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: MonitoringModule
    var body: some View {
        HStack(spacing: 5) {
            ForEach(MonitoringModule.allCases) { module in
                let title = module.title(store)
                MonitoringModuleButton(title: title, symbol: module.symbol, selected: selection == module,
                                       identifier: "monitoring-module-" + module.rawValue) { selection = module }
                    .frame(width: MonitoringModuleNativeButton.width(for: title), height: MonitoringModuleNativeButton.height)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MonitoringModuleButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let selected: Bool
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> MonitoringModuleNativeButton { MonitoringModuleNativeButton() }
    func updateNSView(_ button: MonitoringModuleNativeButton, context: Context) {
        button.title = title; button.symbol = symbol; button.selected = selected; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : "")
        button.needsDisplay = true
    }
}

final class MonitoringModuleNativeButton: PreferencesRectNativeButton {
    static let height: CGFloat = 38
    static func width(for title: String) -> CGFloat {
        max(72, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 52)
    }
    var symbol = ""
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            NSColor(selected ? Palette.card : Palette.field).withAlphaComponent(isHighlighted ? 0.75 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let foreground = NSColor(Palette.text)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            tinted.draw(in: NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawText(title, rect: NSRect(x: 38, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 48), height: 17),
                 color: foreground, font: .systemFont(ofSize: 12, weight: selected ? .semibold : .medium))
        drawFocus()
    }
}
