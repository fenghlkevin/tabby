import XCTest
import AppKit
import SwiftTerm
@testable import TabbyNative

@MainActor final class TerminalFontSizeTests: XCTestCase {
    func testLastRemainingPaneRestoresDefaultOnlyWhenGroupBecomesSingle() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.workspace.preferences.fontSize = 19
        let sessions = (0..<4).map { _ in TerminalSession(host: nil, store: store) }
        store.sessions = sessions; store.activeSession = sessions[0].id
        store.terminalPaneGroups[sessions[0].id] = sessions.map(\.id)
        sessions[0].setFontSize(13)
        store.close(sessions[3].id); XCTAssertEqual(sessions[0].effectiveFontSize, 13)
        store.close(sessions[2].id); XCTAssertEqual(sessions[0].effectiveFontSize, 13)
        store.close(sessions[1].id); XCTAssertEqual(sessions[0].effectiveFontSize, 19)
        XCTAssertNil(sessions[0].fontSizeOverride)
        store.sessions.append(sessions[1]); store.pairSessions(sessions[1].id, with: sessions[0].id)
        sessions[0].setFontSize(12)
        store.separateSession(sessions[1].id)
        XCTAssertEqual(sessions[0].effectiveFontSize, 19)
        sessions[0].setFontSize(14)
        store.separateSession(sessions[0].id)
        XCTAssertEqual(sessions[0].effectiveFontSize, 14, "An already standalone terminal keeps its own size")
    }

    func testIndependentFontSizeBoundsResetAndPreferenceUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.fontSize = 19
        let sessions = (0..<4).map { _ in TerminalSession(host: nil, store: store) }
        store.sessions = sessions
        for session in sessions {
            session.terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            session.applyFontSize()
        }
        let session = sessions[2], terminal = try XCTUnwrap(session.terminal)
        let columns = terminal.terminalStateSnapshot().dimensions.cols
        session.setFontSize(13)
        XCTAssertEqual(terminal.font.pointSize, 13)
        XCTAssertGreaterThan(terminal.terminalStateSnapshot().dimensions.cols, columns)
        XCTAssertTrue(sessions.enumerated().allSatisfy { $0.offset == 2 || $0.element.terminal?.font.pointSize == 19 })
        var preferences = store.workspace.preferences; preferences.fontSize = 21
        try store.commitPreferences(preferences)
        XCTAssertEqual(terminal.font.pointSize, 13)
        XCTAssertEqual(sessions[0].terminal?.font.pointSize, 21)
        session.setFontSize(nil)
        XCTAssertEqual(terminal.font.pointSize, 21)
        session.setFontSize(100); XCTAssertEqual(terminal.font.pointSize, 40)
        session.setFontSize(-100); XCTAssertEqual(terminal.font.pointSize, 10)
        session.setFontSize(.nan); XCTAssertEqual(terminal.font.pointSize, 10)
        store.section = "terminal"; store.activeSession = session.id
        XCTAssertTrue(store.fontAdjustmentSession === session)
        store.section = "sftp"; XCTAssertNil(store.fontAdjustmentSession)
    }
}
