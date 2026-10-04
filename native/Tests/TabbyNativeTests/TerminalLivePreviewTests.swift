import AppKit
import QuartzCore
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class TerminalLivePreviewTests: XCTestCase {
    func testUnfocusedPreviewRendersThreeDistinctCursorShapesAndNativeBlinkAnimation() async throws {
        _ = NSApplication.shared
        let box = PreviewDraft()
        box.value.cursorColor = "#FE007F"
        let hosting = NSHostingView(rootView: CursorFixture(box: box).preferredColorScheme(.light))
        let window = show(hosting, size: NSSize(width: 700, height: 930)); defer { window.close() }
        try await settle(hosting)
        let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first)
        let size = try XCTUnwrap(find(TerminalFontSizeNativeEditor.self, in: hosting).first)
        window.makeFirstResponder(size.field)
        let originalResponder = window.firstResponder
        XCTAssertFalse(preview.hasFocus)
        XCTAssertFalse(preview.caretViewTracksFocus)
        XCTAssertFalse(preview.canBecomeKeyView)
        XCTAssertNil(preview.terminalDelegate)
        XCTAssertNil(preview.hitTest(NSPoint(x: 10, y: 10)))
        var shapes: [String: PixelRegion] = [:]
        for shape in ["block", "bar", "underline"] {
            let button = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-terminal-cursor-" + shape })
            button.performClick(nil)
            try await settle(hosting)
            XCTAssertTrue(window.firstResponder === originalResponder, "Preview updates must leave the user's input focus untouched")
            XCTAssertEqual(preview.terminalStateSnapshot().cursorStyle.tagName, ["block": "steadyBlock", "bar": "steadyBar", "underline": "steadyUnderline"][shape])
            let caret = try actualCaret(in: preview)
            shapes[shape] = try cursorPixels(caret)
            XCTAssertGreaterThan(shapes[shape]!.count, 0, "The actual SwiftTerm caret layer must draw colored pixels")
            try capture(preview, name: "terminal-preview-cursor-" + shape)
        }
        let block = try XCTUnwrap(shapes["block"]), bar = try XCTUnwrap(shapes["bar"]), underline = try XCTUnwrap(shapes["underline"])
        XCTAssertGreaterThan(block.count, bar.count * 2)
        XCTAssertGreaterThan(block.count, underline.count * 2)
        XCTAssertLessThan(bar.width, bar.height)
        XCTAssertGreaterThan(underline.width, underline.height)
        XCTAssertGreaterThan(block.width, bar.width)
        XCTAssertGreaterThan(block.height, underline.height)

        let blink = try XCTUnwrap(find(TerminalCursorBlinkNativeButton.self, in: hosting).first)
        blink.performClick(nil); try await settle(hosting)
        let caret = try actualCaret(in: preview)
        XCTAssertEqual(preview.terminalStateSnapshot().cursorStyle.tagName, "blinkUnderline")
        let animation = try XCTUnwrap(caret.layer?.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(animation.fromValue as? Double, 1)
        XCTAssertEqual(animation.toValue as? Double, 0)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertTrue(animation.repeatCount.isInfinite)
        XCTAssertFalse(preview.hasFocus, "Blinking must work without faking first-responder focus")
        blink.performClick(nil); try await settle(hosting)
        XCTAssertEqual(preview.terminalStateSnapshot().cursorStyle.tagName, "steadyUnderline")
        XCTAssertNil(caret.layer?.animation(forKey: "opacity"))
        XCTAssertEqual(caret.layer?.opacity, 1)
        XCTAssertTrue(window.firstResponder === originalResponder)
    }

    func testThemeCardsUpdateVisibleRealPreviewAtCompactAndWideWidthsWithoutSaving() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [700, 1100] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-live-theme-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
            let box = PreviewDraft(); box.value = store.workspace.preferences
            let original = store.workspace.preferences
            let hosting = NSHostingView(rootView: ColorFixture(box: box).environmentObject(store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 760)); defer { window.close() }
            try await settle(hosting)
            let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-library-preview" })
            XCTAssertGreaterThan(preview.bounds.width, width * 0.8, "The preview spans the whole section rather than a right-side column")
            XCTAssertGreaterThanOrEqual(preview.bounds.height, 230)
            XCTAssertEqual(preview.font.pointSize, box.value.fontSize)
            let originalPixels = try bitmap(preview).tiffRepresentation
            let lightFilter = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-filter-light" })
            lightFilter.performClick(nil); try await settle(hosting)
            let card = try XCTUnwrap(find(TerminalThemeCardNativeButton.self, in: hosting).first { $0.theme.id == "light" })
            XCTAssertFalse(card.visibleRect.isEmpty)
            card.performClick(nil); try await settle(hosting)
            XCTAssertEqual(box.value.terminalTheme, "light")
            XCTAssertEqual(preview.nativeBackgroundColor, NSColor(hex: box.value.background))
            XCTAssertEqual(preview.nativeForegroundColor, NSColor(hex: box.value.foreground))
            XCTAssertEqual(preview.caretColor, NSColor(hex: box.value.cursorColor))
            XCTAssertNotEqual(try bitmap(preview).tiffRepresentation, originalPixels, "Selecting a scheme must visibly redraw the real terminal")
            let visible = preview.convert(preview.bounds, to: hosting)
            XCTAssertTrue(hosting.bounds.contains(visible), "Preview must remain entirely onscreen while selecting a scheme")
            XCTAssertFalse(preview.canBecomeKeyView)
            XCTAssertEqual(store.workspace.preferences, original)
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
            try capture(hosting, name: "terminal-theme-live-\(Int(width))")
        }
    }

    func testDraftColorEditsUpdateAllNineteenTerminalColors() async throws {
        _ = NSApplication.shared
        let box = PreviewDraft()
        let hosting = NSHostingView(rootView: PaletteFixture(box: box))
        let window = show(hosting, size: NSSize(width: 700, height: 180)); defer { window.close() }
        try await settle(hosting)
        let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first)
        let input = PreviewInputCapture(); preview.terminalDelegate = input
        box.value.foreground = "#CAFE11"; box.value.background = "#123456"; box.value.cursorColor = "#FE007F"
        box.value.ansiColors = (0..<16).map { String(format: "#%02x%02x%02x", 16 + $0, 48 + $0, 80 + $0) }
        try await settle(hosting)
        XCTAssertEqual(preview.nativeForegroundColor, NSColor(hex: "#CAFE11"))
        XCTAssertEqual(preview.nativeBackgroundColor, NSColor(hex: "#123456"))
        XCTAssertEqual(preview.caretColor, NSColor(hex: "#FE007F"))
        for index in 0..<16 { preview.feed(text: "\u{1b}]4;\(index);?\u{7}") }
        try await settle(hosting)
        let replies = input.received.map { String(decoding: $0, as: UTF8.self) }.joined()
        for index in 0..<16 {
            let rgb = String(format: "rgb:%04x/%04x/%04x", (16 + index) * 257, (48 + index) * 257, (80 + index) * 257)
            XCTAssertTrue(replies.contains("4;\(index);" + rgb), "The actual renderer must receive edited ANSI slot \(index)")
        }
        preview.terminalDelegate = nil
        try capture(hosting, name: "terminal-theme-live-edited-19-colors")
    }

    func testExpandedPaletteShowsRichOutputAndKeepsCursorVisibleWhenResizingAndChangingFonts() async throws {
        _ = NSApplication.shared
        let box = PreviewDraft()
        let hosting = NSHostingView(rootView: ExpandedPaletteFixture(box: box))
        let window = show(hosting, size: NSSize(width: 900, height: 290)); defer { window.close() }
        try await settle(hosting)
        let preview = try XCTUnwrap(find(TerminalPreferencesPreviewNativeView.self, in: hosting).first)
        let initial = preview.terminalStateSnapshot()
        let output = initial.visibleRows.map(\.text).joined(separator: "\n")
        for content in ["ls -lah", "README.md", "src/", "[INFO]", "[WARN]", "[ERROR]", "previous", "selected"] {
            XCTAssertTrue(output.contains(content), "The actual terminal should show the sample: " + content)
        }
        XCTAssertGreaterThan(initial.visibleRows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count, 6)
        for width: CGFloat in [380, 650, 1100] {
            window.setContentSize(NSSize(width: width, height: 290))
            for size: Double in [10, 19, 40] {
                box.value.fontSize = size; box.value.cursorShape = "bar"; box.value.cursorBlink = true
                try await settle(hosting)
                XCTAssertEqual(preview.font.pointSize, size)
                let snapshot = preview.terminalStateSnapshot()
                XCTAssertTrue(snapshot.visibleRows.allSatisfy { !$0.isWrapped }, "Sample lines fit the current font and viewport without wrapping away the cursor")
                XCTAssertLessThan(snapshot.cursor.col, snapshot.dimensions.cols)
                XCTAssertLessThan(snapshot.cursor.row, snapshot.dimensions.rows)
                let cursorRow = try XCTUnwrap(snapshot.visibleRows.first { $0.row == snapshot.cursor.row })
                XCTAssertTrue(cursorRow.text.trimmingCharacters(in: .whitespaces).hasSuffix("%") || cursorRow.text.trimmingCharacters(in: .whitespaces).hasSuffix("$"))
                XCTAssertEqual(snapshot.cursorStyle.tagName, "blinkBar")
                XCTAssertNil(preview.terminalDelegate)
                XCTAssertFalse(preview.hasFocus)
            }
        }
    }

    private final class PreviewDraft: ObservableObject {
        @Published var value = Preferences()
        @Published var sizeValid = true
        @Published var scrollbackValid = true
    }
    private struct CursorFixture: View {
        @ObservedObject var box: PreviewDraft
        var body: some View {
            TerminalPreferencesPane(draft: $box.value, scrollbackValid: $box.scrollbackValid, fontSizeValid: $box.sizeValid, chinese: true)
                .padding(24).foregroundStyle(Palette.text).background(Palette.background)
        }
    }
    private struct ColorFixture: View {
        @ObservedObject var box: PreviewDraft
        var body: some View {
            ScrollView { TerminalColorPreferencesView(draft: $box.value, chinese: true).padding(24) }
                .foregroundStyle(Palette.text).background(Palette.background)
        }
    }
    private struct ExpandedPaletteFixture: View {
        @ObservedObject var box: PreviewDraft
        var body: some View { TerminalColorPreview(preferences: box.value, style: .expanded).padding(12) }
    }
    private struct PaletteFixture: View {
        @ObservedObject var box: PreviewDraft
        var body: some View { TerminalColorPreview(preferences: box.value).padding(12) }
    }
    private struct PixelRegion { let count: Int; let width: Int; let height: Int }
    private func actualCaret(in preview: TerminalView) throws -> NSView {
        try XCTUnwrap(preview.subviews.first { String(describing: type(of: $0)) == "CaretView" })
    }
    /// Invoke the actual SwiftTerm CALayerDelegate, rather than the AppKit
    /// layer cache (which is not populated by cacheDisplay in an XCTest host).
    /// The delegate draws its real cursor shape with its actual render data.
    private func cursorPixels(_ caret: NSView) throws -> PixelRegion {
        let layer = try XCTUnwrap(caret.layer)
        let width = max(1, Int(ceil(layer.bounds.width))), height = max(1, Int(ceil(layer.bounds.height)))
        let context = try rgbaContext(width: width, height: height)
        let delegate = try XCTUnwrap(caret as? CALayerDelegate)
        delegate.draw?(layer, in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        var points: [(Int, Int)] = []
        for y in 0..<height { for x in 0..<width {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.6, color.greenComponent < 0.3,
               color.blueComponent > 0.2, color.alphaComponent > 0.4 { points.append((x, y)) }
        } }
        guard let minX = points.map(\.0).min(), let maxX = points.map(\.0).max(), let minY = points.map(\.1).min(), let maxY = points.map(\.1).max() else { return PixelRegion(count: 0, width: 0, height: 0) }
        return PixelRegion(count: points.count, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    private func rgbaContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    /// SwiftTerm's Core Graphics text pass intentionally clears default cells
    /// to transparent; the background and caret are separate Core Animation
    /// layers. Compose all three real drawing passes for deterministic PNGs.
    private func terminalImage(_ preview: TerminalPreferencesPreviewNativeView, scale: CGFloat) throws -> CGImage {
        let width = max(1, Int(ceil(preview.bounds.width * scale))), height = max(1, Int(ceil(preview.bounds.height * scale)))
        let textContext = try rgbaContext(width: width, height: height)
        textContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: textContext, flipped: false)
        preview.draw(preview.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let context = try rgbaContext(width: width, height: height)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(preview.nativeBackgroundColor.cgColor); context.fill(preview.bounds)
        context.draw(try XCTUnwrap(textContext.makeImage()), in: preview.bounds)
        let caret = try actualCaret(in: preview), layer = try XCTUnwrap(caret.layer)
        context.saveGState(); context.translateBy(x: caret.frame.minX, y: caret.frame.minY)
        try XCTUnwrap(caret as? CALayerDelegate).draw?(layer, in: context)
        context.restoreGState()
        return try XCTUnwrap(context.makeImage())
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(160)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.displayIfNeeded()
        if let preview = view as? TerminalPreferencesPreviewNativeView {
            return NSBitmapImageRep(cgImage: try terminalImage(preview, scale: 2))
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let context = try rgbaContext(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        context.scaleBy(x: scale, y: scale)
        context.draw(try XCTUnwrap(bitmap.cgImage), in: view.bounds)
        for preview in find(TerminalPreferencesPreviewNativeView.self, in: view) where !preview.visibleRect.isEmpty {
            var frame = preview.convert(preview.bounds, to: view)
            var clip = preview.convert(preview.visibleRect, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY; clip.origin.y = view.bounds.height - clip.maxY }
            context.saveGState(); context.clip(to: clip)
            context.draw(try terminalImage(preview, scale: scale), in: frame)
            context.restoreGState()
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(try bitmap(view).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor private final class PreviewInputCapture: TerminalViewDelegate {
    var received: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}
