import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative
@MainActor final class FullscreenChromeTests: XCTestCase {
    func testFullscreenNotificationsRenderCompactChromeAndRestore() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let hosting = NSHostingView(rootView: MainView().environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        for (name, label) in [(NSWindow.didEnterFullScreenNotification, "fullscreen"), (NSWindow.didExitFullScreenNotification, "windowed")] {
            NotificationCenter.default.post(name: name, object: window)
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-chrome-" + label + ".png"))
        }
    }
}
