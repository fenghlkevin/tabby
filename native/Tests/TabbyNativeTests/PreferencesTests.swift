import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

final class PreferencesTests: XCTestCase {
    func testLegacyPreferencesKeepSavedValuesAndSupplyNewDefaults() throws {
        let legacy = Data(##"{"language":"zh-CN","fontName":"Menlo","fontSize":21,"scrollback":4000,"copyOnSelect":false,"rightClickPaste":false,"trimPaste":false,"analytics":false,"globalHotkey":false,"restoreTabs":false,"autoOpen":false,"foreground":"#aabbcc","background":"#112233"}"##.utf8)
        let value = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertEqual(value.language, "zh-CN"); XCTAssertEqual(value.fontSize, 21); XCTAssertEqual(value.scrollback, 4000)
        XCTAssertFalse(value.copyOnSelect); XCTAssertFalse(value.rightClickPaste); XCTAssertFalse(value.trimPaste)
        XCTAssertEqual(value.foreground, "#aabbcc"); XCTAssertEqual(value.background, "#112233")
        XCTAssertEqual(value.cursorShape, "block"); XCTAssertFalse(value.cursorBlink); XCTAssertFalse(value.optionAsMeta)
        XCTAssertFalse(value.backspaceControlH); XCTAssertTrue(value.mouseReporting); XCTAssertEqual(value.bellStyle, "none")
        XCTAssertFalse(value.confirmMultilinePaste); XCTAssertTrue(value.middleClickPaste)
        XCTAssertEqual(value.localShell, ""); XCTAssertEqual(value.localDirectory, ""); XCTAssertTrue(value.localLoginShell)
        XCTAssertEqual(value.sshConnectTimeout, 30)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(#"{"preferences":{"language":"en-US"}}"#.utf8)).preferences.language, "en-US")
    }

    @MainActor func testValidationRejectsInvalidPathsColorsFontsAndNumbersBeforeSaving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = store.workspace.preferences
        var cases: [Preferences] = []
        var value = original; value.localShell = root.path; cases.append(value)
        value = original; value.localDirectory = root.path; cases.append(value)
        value = original; value.localShell = "/bin/zsh\n"; cases.append(value)
        value = original; value.fontName = "axon-font-that-does-not-exist"; cases.append(value)
        value = original; value.foreground = "#12Ｇ456"; cases.append(value)
        value = original; value.background = "123456"; cases.append(value)
        value = original; value.cursorColor = "#12345"; cases.append(value)
        value = original; value.fontSize = .infinity; cases.append(value)
        value = original; value.scrollback = 1_000_001; cases.append(value)
        value = original; value.sshConnectTimeout = 0; cases.append(value)
        value = original; value.cursorShape = "unknown"; cases.append(value)
        for invalid in cases {
            XCTAssertThrowsError(try store.commitPreferences(invalid))
            XCTAssertEqual(store.workspace.preferences, original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
        value = original; value.localShell = "/bin/zsh"; value.localDirectory = "~"; value.fontName = " Menlo "
        let valid = try PreferencesValidation.validated(value, chinese: true)
        XCTAssertEqual(valid.localShell, "/bin/zsh"); XCTAssertEqual(valid.localDirectory, NSHomeDirectory()); XCTAssertEqual(valid.fontName, "Menlo")
    }

    @MainActor func testFailedSaveRollsBackPreferencesAndDoesNotApplyToLiveTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let terminal = RemoteTerminal(frame: .zero, options: .default)
        session.terminal = terminal; store.sessions = [session]
        TerminalAppearance.apply(store.workspace.preferences, to: terminal)
        var draft = store.workspace.preferences; draft.optionAsMeta = true; draft.cursorShape = "bar"; draft.fontSize = 24
        XCTAssertThrowsError(try store.commitPreferences(draft))
        XCTAssertFalse(store.workspace.preferences.optionAsMeta); XCTAssertFalse(terminal.optionAsMetaKey)
        XCTAssertEqual(terminal.font.pointSize, 19)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "fixture")
    }

    @MainActor func testSavingActuallyUpdatesExistingTerminalAndRoundTripsSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let view = RemoteTerminal(frame: .zero, options: .init(cols: 80, rows: 10, scrollback: 240))
        session.terminal = view; store.sessions = [session]
        view.feed(text: (0..<200).map { String(format: "history-%03d\r\n", $0) }.joined())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self).contains("history-000"))
        var draft = TerminalTheme.all.first { $0.id == "light" }!.applying(to: store.workspace.preferences)
        draft.optionAsMeta = true; draft.backspaceControlH = true; draft.mouseReporting = false
        draft.fontSize = 23; draft.scrollback = 120; draft.cursorShape = "bar"; draft.cursorBlink = true; draft.bellStyle = "visual"
        try store.commitPreferences(draft)
        XCTAssertTrue(view.optionAsMetaKey); XCTAssertTrue(view.backspaceSendsControlH); XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.font.pointSize, 23); XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "blinkBar")
        let history = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertFalse(history.contains("history-000")); XCTAssertTrue(history.contains("history-199"))
        XCTAssertEqual(view.bellStyle.tagName, "visual"); XCTAssertEqual(TerminalAppearance.cursorStyle(draft).tagName, "blinkBar")
        XCTAssertEqual(view.nativeBackgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL)).preferences, draft)
        XCTAssertFalse(session.connected, "Changing display settings must not start a connection")
    }

    @MainActor func testMultilinePastePreviewCancellationNeverSendsAndConfirmedTextRespectsTrim() {
        var preferences = Preferences(); preferences.confirmMultilinePaste = true
        var confirmations: [String] = [], sent: [String] = []
        TerminalPaste.perform("  first\nsecond  ", preferences: preferences, confirm: { confirmations.append($0); return false }, send: { sent.append($0) })
        XCTAssertEqual(confirmations, ["first\nsecond"]); XCTAssertTrue(sent.isEmpty)
        TerminalPaste.perform("  first\r\nsecond  ", preferences: preferences, confirm: { _ in true }, send: { sent.append($0) })
        XCTAssertEqual(sent, ["first\r\nsecond"])
        preferences.trimPaste = false; preferences.confirmMultilinePaste = false
        TerminalPaste.perform("  first\nsecond  ", preferences: preferences, confirm: { _ in XCTFail("Confirmation disabled"); return false }, send: { sent.append($0) })
        XCTAssertEqual(sent.last, "  first\nsecond  ")
        preferences.confirmMultilinePaste = true
        TerminalPaste.perform("single command", preferences: preferences, confirm: { _ in XCTFail("Single line needs no confirmation"); return false }, send: { sent.append($0) })
        XCTAssertEqual(sent.last, "single command")
        XCTAssertTrue(TerminalPaste.needsConfirmation("line\rreturn", preferences: preferences))
    }

    func testLocalLaunchUsesConfiguredShellDirectoryAndLoginModeWithoutCommandParsing() {
        let defaults = LocalTerminalLaunch(preferences: Preferences(), environment: ["SHELL": "/bin/bash"], home: "/fixture/home")
        XCTAssertEqual(defaults.executable, "/bin/bash"); XCTAssertEqual(defaults.arguments, ["-l"]); XCTAssertEqual(defaults.directory, "/fixture/home")
        var value = Preferences(); value.localShell = "/fixture/My Shell"; value.localDirectory = "/fixture/My Directory"; value.localLoginShell = false
        let custom = LocalTerminalLaunch(preferences: value, environment: [:], home: "/other")
        XCTAssertEqual(custom.executable, "/fixture/My Shell"); XCTAssertEqual(custom.arguments, []); XCTAssertEqual(custom.directory, "/fixture/My Directory")
        for theme in TerminalTheme.all { XCTAssertEqual(theme.ansi.count, 16); XCTAssertEqual(Set(theme.ansi).isEmpty, false) }
    }

    @MainActor func testSSHSettingsUseConfiguredTCPTimeoutWithoutCreatingAConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.sshConnectTimeout = 17
        var host = TabbyNative.Host(); host.address = "example.invalid"; host.username = "root"
        let session = TerminalSession(host: host, store: store)
        let settings = try session.settings(for: host) { source in
            var draft = source; draft.secret = "fixture-password"; draft.remember = false
            return try draft.validatedResult(workspace: store.workspace, chinese: false)
        }
        XCTAssertEqual(settings.connectTimeout.nanoseconds, 17_000_000_000)
        XCTAssertFalse(session.connected); XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor func testEverySettingsCategoryRendersAtMinimumWidthWithoutSavingWorkspace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        for page in PreferencesPage.allCases {
            if page == .appearance { store.workspace.preferences.foreground = "#123456"; store.workspace.preferences.background = "#345678"; store.workspace.preferences.cursorColor = "#456789" }
            let hosting = NSHostingView(rootView: PreferencesView(page: page).environmentObject(store).preferredColorScheme(.light)); hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            try await Task.sleep(for: .milliseconds(180)); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.width, 650, accuracy: 1)
            if page == .appearance {
                let edit = try XCTUnwrap(find(PreferencesRectNativeButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-theme-edit-colors" })
                edit.performClick(nil)
                try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
                let reset = try XCTUnwrap(find(PreferencesThemeResetNativeButton.self, in: hosting).first)
                XCTAssertEqual(reset.identifier?.rawValue, "axon-preferences-restore-theme")
                reset.performClick(nil)
                try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
                let fields = find(NSTextField.self, in: hosting).map(\.stringValue)
                XCTAssertTrue(fields.contains(Palette.terminalForeground))
                XCTAssertTrue(fields.contains(Palette.terminalBackground))
                XCTAssertTrue(fields.contains("#bbbbbb"))
                XCTAssertFalse(fields.contains("#123456"))
                XCTAssertEqual(store.workspace.preferences.foreground, "#123456", "Restore only resets the draft; Save is still required")
                XCTAssertEqual(store.workspace.preferences.background, "#345678")
            }
            if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preferences-" + page.rawValue + ".png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Opening or browsing settings never saves a draft")
    }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
}
