import AppKit
import XCTest
@testable import TabbyNative

@MainActor final class TerminalColorPersistenceTests: XCTestCase {
    func testColorSavePersistsImmediatelyWithoutSavingOtherSettingsDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store)
        let terminal = RemoteTerminal(frame: .zero, options: .default)
        session.terminal = terminal; store.sessions = [session]
        let original = store.workspace.preferences
        var draft = original
        draft.fontSize = 500; draft.language = "en-US"; draft.localShell = "/unavailable/draft"
        draft.background = "#123456"; draft.foreground = "#ABCDEF"
        let id = try TerminalThemeLibrary.create(name: "Saved from popup", in: &draft, chinese: true)

        try store.commitTerminalColors(draft)

        let saved = AppStore(fileURL: store.fileURL).workspace.preferences
        XCTAssertEqual(saved.terminalTheme, id)
        XCTAssertEqual(saved.customTerminalThemes.count, 1)
        XCTAssertEqual(saved.background, "#123456")
        XCTAssertEqual(saved.fontSize, original.fontSize)
        XCTAssertEqual(saved.language, original.language)
        XCTAssertEqual(saved.localShell, original.localShell)
        XCTAssertEqual(terminal.font.pointSize, original.fontSize)
        XCTAssertEqual(terminal.nativeBackgroundColor.usingColorSpace(.deviceRGB)?.redComponent ?? 0, 0x12 / 255.0, accuracy: 0.001)
        let mergedDraft = draft.replacingTerminalColors(from: saved)
        XCTAssertEqual(mergedDraft.fontSize, 500)
        XCTAssertEqual(mergedDraft.localShell, "/unavailable/draft")
        XCTAssertEqual(mergedDraft.terminalTheme, id)
        XCTAssertFalse(session.connected)
    }

    func testFailedColorSaveRollsBackAndDoesNotChangeLiveTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data("original".utf8).write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        let original = store.workspace.preferences
        let session = TerminalSession(host: nil, store: store)
        let terminal = RemoteTerminal(frame: .zero, options: .default)
        session.terminal = terminal; store.sessions = [session]
        TerminalAppearance.apply(original, to: terminal)
        let previousBackground = terminal.nativeBackgroundColor
        var draft = original; draft.background = "#123456"
        try TerminalThemeLibrary.create(name: "Failed popup save", in: &draft, chinese: true)
        XCTAssertThrowsError(try store.commitTerminalColors(draft))
        XCTAssertEqual(store.workspace.preferences, original)
        XCTAssertEqual(terminal.nativeBackgroundColor, previousBackground)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("original".utf8))
    }
}
