import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class TerminalThemeScrollingTests: XCTestCase {
    func testSinglePageScrollReachesEveryCustomSchemeAndSurvivesRepeatedRedrawsFiltersAndResizing() async throws {
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
            let scroll = try pageScroll(in: hosting)
            XCTAssertEqual(find(NSScrollView.self, in: hosting).count, 1, "The scheme library shares the page scroll; there is no inner scroll area")
            let reached = try await reachAllCardTitles(using: scroll, in: hosting)
            XCTAssertTrue(Set(draft.value.customTerminalThemes.map(\.id)).isSubset(of: reached), "Every custom scheme is reachable through the one page scroll")
            for cycle in 0..<20 {
                for fraction: CGFloat in [0, 0.55, 1] {
                    let document = try XCTUnwrap(scroll.documentView)
                    let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    for card in find(TerminalThemeCardNativeButton.self, in: hosting) where !card.isHiddenOrHasHiddenAncestor && card.window === hosting.window && !card.visibleRect.isEmpty {
                        card.hovering = cycle % 2 == 0; card.needsDisplay = true
                        for label in find(NSTextField.self, in: card) { label.needsDisplay = true }
                    }
                    try await settle(hosting)
                    XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 2)
                    for card in find(TerminalThemeCardNativeButton.self, in: hosting) where !card.isHiddenOrHasHiddenAncestor && card.window === hosting.window && !card.visibleRect.isEmpty {
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
            XCTAssertTrue(last.visibleRect.contains(label.convert(label.bounds, to: last)), "The single page scroll makes the last title fully visible before testing its hit region")
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: content.superview)
            XCTAssertTrue(content.hitTest(point) === last, "Card labels preserve the whole-card click region")
            XCTAssertTrue(last.accessibilityPerformPress()); try await settle(hosting)
            XCTAssertEqual(draft.value.terminalTheme, lastID)
            let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-library-preview" })
            XCTAssertEqual(preview.nativeBackgroundColor, NSColor(hex: draft.value.background))

            let light = try button("axon-theme-filter-light", in: hosting)
            light.performClick(nil); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); try await settle(hosting)
            XCTAssertEqual(find(NSScrollView.self, in: hosting).count, 1)
            let custom = try button("axon-theme-filter-custom", in: hosting)
            custom.performClick(nil); try await settle(hosting)
            let customReached = try await reachAllCardTitles(using: scroll, in: hosting)
            XCTAssertEqual(customReached, Set(draft.value.customTerminalThemes.map(\.id)), "The custom filter keeps all 40 schemes in the same page scroll")
            let all = try button("axon-theme-filter-all", in: hosting)
            all.performClick(nil); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); try await settle(hosting)
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
    private func pageScroll(in view: NSView) throws -> NSScrollView {
        let candidates = find(NSScrollView.self, in: view).filter { scroll in
            guard let document = scroll.documentView else { return false }
            return !find(TerminalThemeCardNativeButton.self, in: document).isEmpty
        }
        XCTAssertEqual(candidates.count, 1, "Exactly one scroll view contains the scheme cards")
        let scroll = try XCTUnwrap(candidates.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertFalse(find(TerminalPreferencesPreviewNativeView.self, in: document).isEmpty, "The preview and library belong to the same page scroll")
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height + 100)
        return scroll
    }
    private func reachAllCardTitles(using scroll: NSScrollView, in hosting: NSView) async throws -> Set<String> {
        let document = try XCTUnwrap(scroll.documentView)
        let content = try XCTUnwrap(hosting.window?.contentView)
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let step = max(100, scroll.contentView.bounds.height / 2)
        let stops = Array(stride(from: CGFloat.zero, through: bottom, by: step)) + [bottom]
        var reached = Set<String>()
        for y in stops {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(hosting)
            for card in find(TerminalThemeCardNativeButton.self, in: hosting) where !card.isHiddenOrHasHiddenAncestor && card.window === hosting.window && !card.visibleRect.isEmpty {
                guard let label = find(NSTextField.self, in: card).first(where: { $0.stringValue == card.theme.name }),
                      card.visibleRect.contains(label.convert(label.bounds, to: card)) else { continue }
                let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: content.superview)
                XCTAssertTrue(content.hitTest(point) === card, "Every visible card title belongs to the native card's click region")
                reached.insert(card.theme.id)
            }
        }
        return reached
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
