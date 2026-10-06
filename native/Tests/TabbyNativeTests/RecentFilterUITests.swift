import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class RecentFilterUITests: XCTestCase {
    func testFilterRendersAndToggles() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for width: CGFloat in [700, 1050] {
            let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
            try await Task.sleep(for: .milliseconds(200))
            store.workspace.preferences.language = "zh-CN"
            store.workspace.recentTargets = [RecentTarget(kind: .ssh, username: "root", address: "ssh.fixture.invalid", port: 22), RecentTarget(kind: .sftp, username: "root", address: "files.fixture.invalid", port: 22), RecentTarget(kind: .localTerminal)]
            let view = NSHostingView(rootView: LauncherView().environmentObject(store).background(Palette.background).preferredColorScheme(.light))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            defer { window.close() }
            for selected in [false, true, false] {
                try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
                let button = try XCTUnwrap(find(in: view).first { $0.identifier?.rawValue == "recent-files-filter" })
                XCTAssertEqual(button.prominent, selected)
                XCTAssertEqual(button.title, selected ? "✓ SFTP" : "SFTP")
                XCTAssertEqual(button.bounds.height, 28, accuracy: 1)
                let frame = button.convert(button.bounds, to: view)
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, width)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-recents-\(Int(width))-\(selected).png"))
                button.performClick(nil)
            }
        }
    }
    private func find(in view: NSView) -> [PreferencesRectNativeButton] {
        ((view as? PreferencesRectNativeButton).map { [$0] } ?? []) + view.subviews.flatMap { find(in: $0) }
    }
}
