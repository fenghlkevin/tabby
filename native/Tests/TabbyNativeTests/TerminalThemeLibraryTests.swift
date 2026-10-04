import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class TerminalThemeLibraryTests: XCTestCase {
    func testCompleteBuiltInLibraryAndSearchFilters() throws {
        let preferences = Preferences()
        XCTAssertEqual(TerminalTheme.all.count, 10)
        XCTAssertEqual(Set(TerminalTheme.all.map(\.id)).count, 10)
        for theme in TerminalTheme.all {
            XCTAssertEqual(theme.ansi.count, 16)
            XCTAssertTrue((theme.ansi + [theme.foreground, theme.background, theme.cursor]).allSatisfy(TerminalThemeLibrary.isHex))
            XCTAssertEqual(TerminalTheme.effectiveANSI(theme.applying(to: preferences)), theme.ansi)
        }
        XCTAssertEqual(TerminalThemeLibrary.filtered(preferences, search: "  CATPPUCCIN ", filter: .all).count, 4)
        XCTAssertEqual(Set(TerminalThemeLibrary.filtered(preferences, search: "", filter: .light).map(\.id)), ["light", "solarizedLight", "catppuccinLatte"])
        XCTAssertEqual(TerminalThemeLibrary.filtered(preferences, search: "", filter: .dark).count, 7)
        XCTAssertTrue(TerminalThemeLibrary.filtered(preferences, search: "", filter: .custom).isEmpty)
        XCTAssertTrue(TerminalThemeLibrary.filtered(preferences, search: "Nord", filter: .light).isEmpty)
    }

    func testLegacyPaletteCustomLifecycleAndExplicitPersistence() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data(##"{"terminalTheme":"draculaGreen","foreground":"#123456","background":"#234567","cursorColor":"#345678"}"##.utf8))
        XCTAssertNil(legacy.ansiColors); XCTAssertTrue(legacy.customTerminalThemes.isEmpty)
        XCTAssertEqual(TerminalTheme.effectiveANSI(legacy), Palette.ansi)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences = legacy
        var draft = legacy
        var ansi = TerminalTheme.effectiveANSI(draft); ansi[1] = "#102030"; ansi[9] = "#405060"; draft.ansiColors = ansi
        let id = try TerminalThemeLibrary.create(name: "  My palette  ", in: &draft, chinese: false)
        XCTAssertEqual(draft.terminalTheme, id); XCTAssertEqual(draft.customTerminalThemes[0].ansi, ansi)
        XCTAssertEqual(draft.customTerminalThemes[0].name, "My palette")
        XCTAssertEqual(store.workspace.preferences, legacy); XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try TerminalThemeLibrary.rename(id, name: "My edited palette", in: &draft, chinese: false)
        draft.cursorColor = "#6789ab"; try TerminalThemeLibrary.update(id, in: &draft, chinese: false)
        XCTAssertEqual(TerminalTheme.selected(draft).cursor, "#6789ab")
        XCTAssertTrue(TerminalTheme.selected(draft).matches(draft))
        try store.commitPreferences(draft)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences
        XCTAssertEqual(saved, draft)
        TerminalThemeLibrary.remove(id, in: &draft)
        XCTAssertTrue(draft.customTerminalThemes.isEmpty); XCTAssertEqual(draft.terminalTheme, "draculaGreen")
        XCTAssertEqual(TerminalTheme.effectiveANSI(draft), Palette.ansi)
        XCTAssertEqual(store.workspace.preferences, saved, "Delete stays in the draft until Save")
        draft = store.workspace.preferences
        XCTAssertEqual(TerminalTheme.selected(draft).id, id, "Reverting restores the entire custom scheme")
        XCTAssertEqual(TerminalTheme.effectiveANSI(draft), ansi)
    }

    func testInvalidCustomNamesIdsAndPalettesDoNotSave() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = store.workspace.preferences
        var draft = original
        let id = try TerminalThemeLibrary.create(name: "Fixture", in: &draft, chinese: false)
        for name in ["", "Nord", "fixture", "line\nbreak", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try TerminalThemeLibrary.create(name: name, in: &draft, chinese: false))
            XCTAssertEqual(draft.customTerminalThemes.count, 1)
        }
        var variants: [Preferences] = []
        var invalid = draft; invalid.ansiColors = ["#123456"]; variants.append(invalid)
        invalid = draft; invalid.ansiColors?[4] = "#１２３４５６"; variants.append(invalid)
        invalid = draft; invalid.customTerminalThemes.append(invalid.customTerminalThemes[0]); variants.append(invalid)
        invalid = draft; invalid.customTerminalThemes[0].name = "Nord"; variants.append(invalid)
        invalid = draft; invalid.customTerminalThemes = [TerminalTheme(id: id, name: "Fixture", foreground: "#ffffff", background: "#000000", cursor: "#999999", ansi: [])]; variants.append(invalid)
        for item in variants { XCTAssertThrowsError(try store.commitPreferences(item)); XCTAssertEqual(store.workspace.preferences, original); XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path)) }
    }

    func testSaveAppliesCustomAnsiToRealTerminalOSCQueries() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let capture = ThemeTerminalInputCapture(); view.terminalDelegate = capture
        session.terminal = view; store.sessions = [session]
        var draft = store.workspace.preferences
        draft.ansiColors = (0..<16).map { String(format: "#%02x%02x%02x", 16 + $0, 48 + $0, 80 + $0) }
        try TerminalThemeLibrary.create(name: "OSC palette", in: &draft, chinese: false)
        try store.commitPreferences(draft)
        for index in 0..<16 { view.feed(text: "\u{1b}]4;\(index);?\u{7}") }
        try await Task.sleep(for: .milliseconds(100))
        let replies = capture.received.map { String(decoding: $0, as: UTF8.self) }.joined()
        for index in 0..<16 {
            let color = String(format: "rgb:%04x/%04x/%04x", (16 + index) * 257, (48 + index) * 257, (80 + index) * 257)
            XCTAssertTrue(replies.contains("4;\(index);" + color), "The terminal engine must use saved ANSI index \(index): " + replies)
        }
        XCTAssertFalse(session.connected, "A palette update never opens a connection")
    }

    func testNavigationEntireRowsActivateIncludingTextBlankSpaceAndCorners() async throws {
        _ = NSApplication.shared
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        try await withWindow(PreferencesView().environmentObject(store).preferredColorScheme(.light), size: NSSize(width: 650, height: 700)) { hosting in
            let buttons = find(PreferencesNavigationNativeButton.self, in: hosting)
            XCTAssertEqual(buttons.count, PreferencesPage.allCases.count)
            for item in PreferencesPage.allCases {
                let target = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "axon-preferences-page-" + item.rawValue })
                XCTAssertEqual(target.bounds.width, 148, accuracy: 1); XCTAssertEqual(target.bounds.height, 42, accuracy: 1)
                for point in [NSPoint(x: 2, y: 2), NSPoint(x: 73, y: 21), NSPoint(x: 145, y: 21), NSPoint(x: 146, y: 40)] {
                    let other = buttons.first { $0 !== target }!
                    try activateAt(other, point: NSPoint(x: 70, y: 21)); try await settle(hosting)
                    try activateAt(target, point: point); try await settle(hosting)
                    XCTAssertTrue(target.selected, item.rawValue + " row point " + NSStringFromPoint(point))
                    XCTAssertEqual(buttons.filter(\.selected).count, 1)
                }
                if item == .shortcuts || item == .about { try capture(hosting, name: "preferences-separated-" + item.rawValue) }
            }
            XCTAssertEqual(PreferencesPage.appearance.title(chinese: true), "终端配色")
            XCTAssertEqual(PreferencesPage.about.title(chinese: false), "About")
            XCTAssertEqual(PreferencesPage.shortcuts.title(chinese: false), "Shortcuts")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testSchemeCardsFiltersAndFullColorEditorAtBothWidthsKeepDraftUnsaved() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [650, 1100] {
            let draft = ThemeDraftBox()
            let binding = Binding(get: { draft.value }, set: { draft.value = $0 })
            try await withWindow(ScrollViewReader { proxy in ScrollView { TerminalColorPreferencesView(draft: binding, chinese: true, scrollToSection: { proxy.scrollTo($0, anchor: .top) }).padding(24) } }.preferredColorScheme(.light), size: NSSize(width: width, height: 880)) { hosting in
                try capture(hosting, name: "preferences-theme-library-\(Int(width))")
                let cards = find(TerminalThemeCardNativeButton.self, in: hosting)
                XCTAssertGreaterThanOrEqual(cards.count, 2)
                let card = try XCTUnwrap(cards.first { $0.theme.id == "dracula" })
                let unchanged = draft.value
                card.isEnabled = false
                card.performClick(nil)
                XCTAssertEqual(draft.value, unchanged, "Disabled card activation must not change the palette")
                card.isEnabled = true
                for point in [NSPoint(x: 2, y: 2), NSPoint(x: 50, y: 105), NSPoint(x: card.bounds.width - 2, y: 137)] {
                    try activateAt(card, point: point); try await settle(hosting)
                    XCTAssertEqual(draft.value.terminalTheme, "dracula")
                    XCTAssertEqual(TerminalTheme.effectiveANSI(draft.value), card.theme.ansi)
                    XCTAssertEqual(draft.value.foreground, card.theme.foreground)
                }
                let light = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-filter-light" })
                try activateAt(light, point: NSPoint(x: light.bounds.width - 2, y: 2)); try await settle(hosting)
                try capture(hosting, name: "preferences-theme-light-filter-\(Int(width))")
                // LazyVGrid retains offscreen NSViewRepresentables. Only cards
                // visible in this window and owning their center hit region are
                // active results; the complete visible set must still be exact.
                let lightCards = visibleCards(in: hosting)
                XCTAssertEqual(lightCards.count, 3)
                XCTAssertEqual(Set(lightCards.map { $0.theme.id }), ["light", "solarizedLight", "catppuccinLatte"])
                let custom = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-filter-custom" })
                try activateAt(custom, point: NSPoint(x: 20, y: 15)); try await settle(hosting)
                XCTAssertTrue(find(TerminalThemeCardNativeButton.self, in: hosting).isEmpty)
                try capture(hosting, name: "preferences-theme-custom-empty-\(Int(width))")
                XCTAssertTrue(draft.value.customTerminalThemes.isEmpty)
                let edit = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-edit-colors" })
                try activateAt(edit, point: NSPoint(x: 50, y: 15)); try await settle(hosting)
                let baseFields = find(NSTextField.self, in: hosting).map(\.stringValue)
                for color in [draft.value.foreground, draft.value.background, draft.value.cursorColor] { XCTAssertTrue(baseFields.contains(color)) }
                try capture(hosting, name: "preferences-theme-color-editor-\(Int(width))")
                let ansiEdit = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-edit-ansi" })
                try activateAt(ansiEdit, point: NSPoint(x: 100, y: 15)); try await settle(hosting)
                let ansiFields = find(NSTextField.self, in: hosting).map(\.stringValue)
                for color in TerminalTheme.effectiveANSI(draft.value) { XCTAssertTrue(ansiFields.contains(color)) }
                XCTAssertGreaterThanOrEqual(ansiFields.filter { $0.hasPrefix("#") }.count, 16)
                try capture(hosting, name: "preferences-theme-ansi-editor-\(Int(width))")
            }
        }
    }

    func testIncompleteDecodedCustomPaletteRendersSafelyAndCannotBeSaved() async throws {
        _ = NSApplication.shared
        var preferences = Preferences()
        let id = "custom-" + UUID().uuidString
        preferences.terminalTheme = id
        preferences.customTerminalThemes = [TerminalTheme(id: id, name: "Damaged palette", foreground: "#ffffff", background: "#000000", cursor: "#ffffff", ansi: ["#ff0000"])]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(TerminalTheme.effectiveANSI(decoded).count, 16)
        XCTAssertThrowsError(try PreferencesValidation.validated(decoded, chinese: false))
        let draft = ThemeDraftBox(); draft.value = decoded
        try await withWindow(ScrollView { TerminalColorPreferencesView(draft: Binding(get: { draft.value }, set: { draft.value = $0 }), chinese: false).padding(24) }, size: NSSize(width: 650, height: 700)) { hosting in
            hosting.displayIfNeeded()
            XCTAssertEqual(TerminalTheme.selected(draft.value).name, "Damaged palette")
        }
    }
    private final class ThemeDraftBox { var value = Preferences() }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("axon-theme-library-" + UUID().uuidString) }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    /// Verify the complete window hit region first, then use the native button's
    /// activation. Synthetic tracking events cannot reproduce hardware mouse
    /// button state in a hidden XCTest window; CUA covers actual mouse clicks.
    private func visibleCards(in hosting: NSView) -> [TerminalThemeCardNativeButton] {
        guard let content = hosting.window?.contentView else { return [] }
        return find(TerminalThemeCardNativeButton.self, in: hosting).filter { card in
            guard card.window === hosting.window, !card.isHiddenOrHasHiddenAncestor, !card.visibleRect.isEmpty else { return false }
            let center = NSPoint(x: card.bounds.midX, y: card.bounds.midY)
            guard card.visibleRect.contains(center) else { return false }
            return content.hitTest(card.convert(center, to: content.superview)) === card
        }
    }
    private func activateAt(_ button: NSButton, point: NSPoint) throws {
        let window = try XCTUnwrap(button.window)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.hitTest(button.convert(point, to: button.superview)) === button)
        let content = try XCTUnwrap(window.contentView)
        let hit = try XCTUnwrap(content.hitTest(button.convert(point, to: content.superview)))
        XCTAssertTrue(hit === button, "Window hit region must resolve to the intended button")
        let target = try XCTUnwrap(hit as? NSButton)
        target.performClick(nil)
    }
    private func withWindow<Content: View>(_ content: Content, size: NSSize, action: (NSHostingView<Content>) async throws -> Void) async throws {
        let hosting = NSHostingView(rootView: content); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await settle(hosting); try await action(hosting)
    }
    private func settle(_ hosting: NSView) async throws { try await Task.sleep(for: .milliseconds(70)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded() }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
@MainActor private final class ThemeTerminalInputCapture: TerminalViewDelegate {
    var received: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}
