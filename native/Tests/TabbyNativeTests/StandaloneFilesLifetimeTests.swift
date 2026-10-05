import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative
@MainActor final class StandaloneFilesLifetimeTests: XCTestCase {
    func testStandaloneFileViewSurvivesLogTabRoundTrip() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.section = "sftp"
        let hosting = NSHostingView(rootView: MainView().environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(tables(hosting).first)
        store.section = "logviewer"
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(tables(hosting).contains { $0 === original }, "Log navigation must keep the file workspace mounted")
        store.section = "sftp"
        try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(tables(hosting).contains { $0 === original }, "Returning must reuse the original file view")
    }
    private func tables(_ view: NSView) -> [FileNativeTable] { ((view as? FileNativeTable).map { [$0] } ?? []) + view.subviews.flatMap { tables($0) } }
}
