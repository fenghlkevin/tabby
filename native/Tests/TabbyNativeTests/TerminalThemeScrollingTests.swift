import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class TerminalThemeScrollingTests: XCTestCase {
    func testVisibleThemeCardsSurviveRepeatedNestedScrollRedrawsFiltersAndResizing() async throws {
        _ = NSApplication.shared
        let draft = Draft()
        draft.value.customTerminalThemes = (0..<40).map { index in
            let base = TerminalTheme.all[index % TerminalTheme.all.count]
            return TerminalTheme(id: "custom-" + UUID().uuidString, name: String(format: "Scroll fixture %02d 中文", index),
                                 foreground: base.foreground, background: base.background, cursor: base.cursor, ansi: base.ansi)
        }
        let hosting = NSHostingView(rootView: Fixture(draft: draft).preferredColorScheme(.light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 1050, height: 940),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        // Previous card tests never ordered the window front. This exercises
        // the actual AppKit layer redraw that appears in the two crash reports.
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        for width: CGFloat in [1050, 700] {
            window.setContentSize(NSSize(width: width, height: 940)); try await settle(hosting)
            let scroll = try libraryScroll(in: hosting)
            for cycle in 0..<20 {
                for fraction: CGFloat in [0, 0.55, 1] {
                    let document = try XCTUnwrap(scroll.documentView)
                    let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    for card in find(TerminalThemeCardNativeButton.self, in: hosting) where !card.visibleRect.isEmpty {
                        card.hovering = cycle % 2 == 0; card.needsDisplay = true
                        for label in find(NSTextField.self, in: card) { label.needsDisplay = true }
                    }
                    try await settle(hosting)
                    XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 2)
                    for card in find(TerminalThemeCardNativeButton.self, in: hosting) where !card.visibleRect.isEmpty {
                        let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                        card.cacheDisplay(in: card.bounds, to: bitmap)
                        XCTAssertNotNil(bitmap.cgImage, "Visible card text and palette redraw without a CoreText exception")
                    }
                }
            }
            let lastID = try XCTUnwrap(draft.value.customTerminalThemes.last?.id)
            let last = try XCTUnwrap(find(TerminalThemeCardNativeButton.self, in: hosting).first { $0.theme.id == lastID })
            XCTAssertFalse(last.visibleRect.isEmpty, "The final card is reachable by scrolling")
            let label = try XCTUnwrap(find(NSTextField.self, in: last).first { $0.stringValue == last.theme.name })
            let content = try XCTUnwrap(window.contentView)
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: content.superview)
            XCTAssertTrue(content.hitTest(point) === last, "Card labels preserve the whole-card click region")
            XCTAssertTrue(last.accessibilityPerformPress()); try await settle(hosting)
            XCTAssertEqual(draft.value.terminalTheme, lastID)
            let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-library-preview" })
            XCTAssertEqual(preview.nativeBackgroundColor, NSColor(hex: draft.value.background))

            let light = try button("axon-theme-filter-light", in: hosting)
            light.performClick(nil); try await settle(hosting)
            let all = try button("axon-theme-filter-all", in: hosting)
            all.performClick(nil); try await settle(hosting)
            XCTAssertEqual(draft.value.customTerminalThemes.count, 40)
            XCTAssertEqual(draft.value.terminalTheme, lastID, "Browsing and filtering retain the selected draft")
        }
    }

    private final class Draft: ObservableObject { @Published var value = Preferences() }
    private struct Fixture: View {
        @ObservedObject var draft: Draft
        var body: some View {
            ScrollView { TerminalColorPreferencesView(draft: $draft.value, chinese: true).padding(24) }
        }
    }
    private func libraryScroll(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(find(NSScrollView.self, in: view).filter { scroll in
            guard let document = scroll.documentView else { return false }
            return !find(TerminalThemeCardNativeButton.self, in: document).isEmpty
                && document.bounds.height > scroll.contentView.bounds.height + 100
        }.min { $0.contentView.bounds.height < $1.contentView.bounds.height })
    }
    private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(find(NSButton.self, in: view).first { $0.identifier?.rawValue == identifier })
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
    }
}
