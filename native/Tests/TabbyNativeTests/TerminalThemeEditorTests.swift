import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class TerminalThemeEditorTests: XCTestCase {
    func testBuiltInEditorSavesAllNineteenColorsAsNewWithoutChangingBuiltInOrUnrelatedSettings() throws {
        let source = Preferences()
        let originalBuiltIns = TerminalTheme.all
        var editor = TerminalThemeEditorDraft(preferences: source, saveAsNew: false, chinese: true)
        XCTAssertFalse(editor.canUpdate); XCTAssertEqual(editor.mode, .create)
        editor.name = "我的配色"
        editor.palette.foreground = "#123456"; editor.palette.background = "#234567"; editor.palette.cursorColor = "#345678"
        editor.palette.ansiColors = (0..<16).map { String(format: "#%06x", $0 + 100) }
        var target = source; target.fontSize = 23; target.sshConnectTimeout = 42
        let result = try editor.saving(to: target, chinese: true)
        XCTAssertEqual(source, Preferences(), "Editing does not mutate its source")
        XCTAssertEqual(TerminalTheme.all, originalBuiltIns)
        XCTAssertEqual(result.customTerminalThemes.count, 1)
        let saved = try XCTUnwrap(result.customTerminalThemes.first)
        XCTAssertEqual(saved.name, "我的配色"); XCTAssertEqual(result.terminalTheme, saved.id)
        XCTAssertTrue(saved.matches(result)); XCTAssertEqual(saved.ansi, editor.palette.ansiColors)
        XCTAssertEqual(result.fontSize, 23); XCTAssertEqual(result.sshConnectTimeout, 42)
    }

    func testCustomEditorUpdatesSameSchemeOrSavesIndependentCopyAndSuggestsUnusedNames() throws {
        var source = Preferences()
        let id = try TerminalThemeLibrary.create(name: "Personal", in: &source, chinese: false)
        var editor = TerminalThemeEditorDraft(preferences: source, saveAsNew: false, chinese: false)
        XCTAssertTrue(editor.canUpdate); XCTAssertEqual(editor.mode, .update)
        editor.name = "Renamed personal"; editor.palette.foreground = "#102030"
        let updated = try editor.saving(to: source, chinese: false)
        XCTAssertEqual(updated.customTerminalThemes.count, 1); XCTAssertEqual(updated.terminalTheme, id)
        XCTAssertEqual(updated.customTerminalThemes[0].name, "Renamed personal")
        XCTAssertEqual(updated.customTerminalThemes[0].foreground, "#102030")
        XCTAssertEqual(source.customTerminalThemes[0].name, "Personal", "The editor works on a local value until saving succeeds")
        editor.choose(.create)
        XCTAssertEqual(editor.name, "Personal Copy")
        let copied = try editor.saving(to: updated, chinese: false)
        XCTAssertEqual(copied.customTerminalThemes.count, 2)
        XCTAssertNotEqual(copied.terminalTheme, id)
        XCTAssertEqual(copied.customTerminalThemes[0], updated.customTerminalThemes[0])
        let another = TerminalThemeEditorDraft(preferences: source, saveAsNew: true, chinese: false)
        var withCopy = source; try TerminalThemeLibrary.create(name: another.name, in: &withCopy, chinese: false)
        withCopy.terminalTheme = id
        let next = TerminalThemeEditorDraft(preferences: withCopy, saveAsNew: true, chinese: false)
        XCTAssertEqual(next.name, "Personal Copy 2")
    }

    func testInvalidEditorSaveIsAtomicForDuplicateNamesInvalidColorsAndBuiltInUpdates() throws {
        var settings = Preferences()
        try TerminalThemeLibrary.create(name: "Custom fixture", in: &settings, chinese: false)
        var editor = TerminalThemeEditorDraft(preferences: settings, saveAsNew: false, chinese: false)
        let original = settings
        for invalid in ["", "Nord", "\n", String(repeating: "a", count: 49)] {
            editor.name = invalid
            XCTAssertThrowsError(try editor.saving(to: settings, chinese: false))
            XCTAssertEqual(settings, original)
        }
        editor.name = "Valid rename"; editor.palette.ansiColors?[4] = "#invalid"
        XCTAssertThrowsError(try editor.saving(to: settings, chinese: false))
        XCTAssertEqual(settings, original)
        var builtIn = TerminalThemeEditorDraft(preferences: Preferences(), saveAsNew: false, chinese: false)
        builtIn.mode = .update
        XCTAssertThrowsError(try builtIn.saving(to: Preferences(), chinese: false))
    }

    func testEditorShowsNineteenReachableFieldsFixedFooterAndCommitFailureDoesNotDismissOrMutate() async throws {
        _ = NSApplication.shared
        let original = Preferences()
        let request = TerminalThemeEditorRequest(preferences: original, saveAsNew: true, chinese: true, visibleSize: NSSize(width: 1440, height: 900))
        var attempts = 0
        var value = original
        let editor = TerminalThemeEditor(request: request, chinese: true, persistsImmediately: true) { edited in
            let candidate = try edited.saving(to: value, chinese: true)
            attempts += 1
            // A failed persistence operation must not assign the candidate.
            XCTAssertEqual(candidate.customTerminalThemes.count, 1)
            throw AppFailure.message("Fixture write failure")
        }
        let hosting = NSHostingView(rootView: editor.preferredColorScheme(.light)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: request.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        let save = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-editor-save" })
        let cancel = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-editor-cancel" })
        XCTAssertEqual(save.title, "保存并应用"); XCTAssertEqual(save.keyEquivalent, "\r")
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
        XCTAssertTrue(hosting.bounds.contains(save.convert(save.bounds, to: hosting)))
        let fields = find(NSTextField.self, in: hosting).filter { $0.stringValue.hasPrefix("#") }
        XCTAssertEqual(fields.count, 19)
        XCTAssertGreaterThan(hosting.bounds.width, 1000, "The normal desktop editor has space for preview and full palette")
        XCTAssertTrue(fields.allSatisfy { $0.visibleRect.contains($0.bounds) }, "All 19 color inputs are visible together on a normal desktop")
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting).first { $0.documentView != nil })
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView); try await settle(hosting)
        XCTAssertTrue(fields.filter { !$0.visibleRect.isEmpty }.contains { $0.stringValue == "#ffffff" }, "The last ANSI row is reachable")
        XCTAssertTrue(hosting.bounds.contains(save.convert(save.bounds, to: hosting)), "Scrolling colors keeps Save visible")
        save.performClick(nil); try await settle(hosting)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(value, original)
        XCTAssertTrue(window.isVisible, "A failed save keeps the editor open")
        // The error is rendered by SwiftUI, while Save remains available for retry.
        XCTAssertTrue(save.isEnabled)
        if let capturePath = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: capturePath); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preferences-theme-editor-save-error.png"))
        }
        // Keep this variable mutable in the fixture to mirror a real settings binding.
        value = original
    }

    func testEditorSizingFitsCompactScreensAndProvidesAllNineteenReachableFieldsWithFixedFooter() async throws {
        _ = NSApplication.shared
        let visibleSize = NSSize(width: 1024, height: 700)
        let request = TerminalThemeEditorRequest(preferences: Preferences(), saveAsNew: true, chinese: true, visibleSize: visibleSize)
        XCTAssertLessThanOrEqual(request.size.width, visibleSize.width - 64)
        XCTAssertLessThanOrEqual(request.size.height, visibleSize.height - 64)
        let desktop = TerminalThemeEditorRequest(preferences: Preferences(), saveAsNew: true, chinese: true, visibleSize: NSSize(width: 1440, height: 900))
        XCTAssertGreaterThan(desktop.size.width, 1000)
        XCTAssertGreaterThan(desktop.size.height, 700)
        let hosting = NSHostingView(rootView: TerminalThemeEditor(request: request, chinese: true, persistsImmediately: true) { _ in XCTFail("Scrolling the editor must not save") }.preferredColorScheme(.light)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: request.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        XCTAssertEqual(hosting.bounds.size, request.size, "The editor uses the compact screen size without overflowing its window")
        let fields = find(NSTextField.self, in: hosting).filter { $0.stringValue.hasPrefix("#") }
        XCTAssertEqual(fields.count, 19)
        let scrolls = find(NSScrollView.self, in: hosting)
        XCTAssertEqual(scrolls.count, 1, "The preview and palette scroll together on a compact screen")
        let scroll = try XCTUnwrap(scrolls.first), document = try XCTUnwrap(scroll.documentView)
        let save = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-editor-save" })
        let footerFrame = save.convert(save.bounds, to: hosting)
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        var reached = Set<ObjectIdentifier>()
        for fraction: CGFloat in [0, 0.5, 1] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom * fraction)); scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(hosting)
            for field in fields where field.visibleRect.contains(field.bounds) {
                reached.insert(ObjectIdentifier(field))
                XCTAssertTrue(hosting.bounds.contains(field.convert(field.bounds, to: hosting)))
                XCTAssertGreaterThan(field.bounds.width, 80, "Hex inputs remain readable on the compact screen")
            }
            XCTAssertEqual(save.convert(save.bounds, to: hosting), footerFrame, "Scrolling leaves the Save footer fixed")
            XCTAssertTrue(hosting.bounds.contains(footerFrame))
        }
        XCTAssertEqual(reached.count, 19, "Every base and ANSI color input can be reached on a compact screen")
        try capture(hosting, name: "preferences-theme-editor-compact-screen")
    }

    func testActualPopupExpandsOnNormalDesktopWithoutResizingParentOrChangingSessions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-editor-size-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let session = TerminalSession(host: nil, store: store); store.sessions = [session]
        let original = store.workspace.preferences
        let generation = session.generation
        let hosting = NSHostingView(rootView: PreferencesView(page: .appearance).environmentObject(store).preferredColorScheme(.light)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 650, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        let originalFrame = window.frame
        let visibleSize = window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let edit = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-edit-colors" })
        edit.performClick(nil)
        for _ in 0..<20 {
            try await settle(hosting)
            if window.attachedSheet != nil { break }
        }
        let sheet = try XCTUnwrap(window.attachedSheet), editor = try XCTUnwrap(sheet.contentView)
        try await settle(editor)
        if visibleSize.width >= 1100 { XCTAssertGreaterThan(sheet.contentLayoutRect.width, 1000, "The real popup uses desktop space even with a compact parent window") }
        XCTAssertLessThanOrEqual(sheet.frame.width, visibleSize.width)
        XCTAssertLessThanOrEqual(sheet.frame.height, visibleSize.height)
        // AppKit may temporarily reposition a compact parent to fit its attached
        // sheet on screen. Its dimensions stay fixed, and dismissal restores the
        // complete frame (asserted below).
        XCTAssertEqual(window.frame.size, originalFrame.size, "Opening a color editor does not resize the terminal window")
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertEqual(session.generation, generation)
        XCTAssertFalse(session.connected); XCTAssertFalse(session.connectionInProgress); XCTAssertNil(session.task)
        let save = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: editor).first { $0.identifier?.rawValue == "axon-theme-editor-save" })
        XCTAssertTrue(editor.bounds.contains(save.convert(save.bounds, to: editor)))
        try capture(editor, name: "preferences-theme-editor-expanded-popup")
        let cancel = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: editor).first { $0.identifier?.rawValue == "axon-theme-editor-cancel" })
        cancel.performClick(nil)
        for _ in 0..<20 {
            try await settle(hosting)
            if window.attachedSheet == nil { break }
        }
        XCTAssertNil(window.attachedSheet); XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(store.workspace.preferences, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.sessions.map(\.id), [session.id]); XCTAssertEqual(session.generation, generation)
    }

    func testPopupCommitFailureLeavesDraftUnchangedAndCancelClosesWithoutSaving() async throws {
        _ = NSApplication.shared
        let draft = DraftBox()
        let original = draft.value
        var attempts = 0
        let view = TerminalColorPreferencesView(draft: Binding(get: { draft.value }, set: { draft.value = $0 }), chinese: true, commit: { _ in
            attempts += 1; throw AppFailure.message("Fixture persistence failure")
        })
        let hosting = NSHostingView(rootView: ScrollView { view.padding(24) }.preferredColorScheme(.light)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(hosting)
        let create = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-create" })
        create.performClick(nil)
        for _ in 0..<20 {
            try await settle(hosting)
            if window.attachedSheet != nil { break }
        }
        let sheet = try XCTUnwrap(window.attachedSheet), editor = try XCTUnwrap(sheet.contentView)
        try await settle(editor)
        let save = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: editor).first { $0.identifier?.rawValue == "axon-theme-editor-save" })
        save.performClick(nil); try await settle(editor)
        XCTAssertEqual(attempts, 1); XCTAssertEqual(draft.value, original)
        XCTAssertTrue(window.attachedSheet === sheet, "Persistence errors keep the popup open for retry")
        let cancel = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: editor).first { $0.identifier?.rawValue == "axon-theme-editor-cancel" })
        cancel.performClick(nil)
        for _ in 0..<20 {
            try await settle(hosting)
            if window.attachedSheet == nil { break }
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(draft.value, original); XCTAssertEqual(attempts, 1, "Cancel does not retry persistence")
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let capturePath = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: capturePath); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private final class DraftBox { var value = Preferences() }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(160)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
}
