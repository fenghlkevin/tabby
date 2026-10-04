import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

final class HostCardActionTests: XCTestCase {
    func testExplicitQuickPortRequiresDecimalDigitsAndKeepsIPv6AddressIntact() {
        XCTAssertEqual(parseQuickHost("ssh fixture@::1 -p 2200")?.address, "::1")
        XCTAssertEqual(parseQuickHost("ssh fixture@::1 -p 2200")?.port, 2200)
        XCTAssertEqual(parseQuickHost("fixture@example.invalid")?.port, 22)
        for port in ["+22", "-22", "0", "65536", "22x", "2.2", "99999999999999999999999999"] {
            XCTAssertNil(parseQuickHost("ssh fixture@example.invalid -p " + port), port)
        }
        for address in ["host/path", "host;command", "https://example.invalid", "-example.invalid"] {
            XCTAssertNil(parseQuickHost("fixture@" + address), address)
        }
    }

    @MainActor func testGridAndListActionsHaveSeparateSquareHitAreasAndDoNotConnect() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host()
        host.name = "A long fixture host name that must leave room for actions"
        host.address = "fixture.invalid"
        for width in [CGFloat(290), CGFloat(760)] {
            let calls = HostCardCalls()
            let card = HostCard(host: host, selected: false, compact: width < 500,
                                select: { calls.select += 1 }, connect: { calls.connect += 1 },
                                edit: { calls.edit += 1 }, favorite: { calls.favorite += 1 }, delete: { calls.delete += 1 })
            let hosting = NSHostingView(rootView: card.frame(width: width, height: 60).environmentObject(store))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            let buttons = try await buttons(in: hosting)
            XCTAssertEqual(buttons.count, 2)
            let favorite = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "axon-host-favorite-" + host.id.uuidString })
            let edit = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "axon-host-edit-" + host.id.uuidString })
            let favoriteFrame = favorite.convert(favorite.bounds, to: hosting)
            let editFrame = edit.convert(edit.bounds, to: hosting)
            XCTAssertLessThanOrEqual(favoriteFrame.maxX + 4, editFrame.minX + 0.5)
            for button in [favorite, edit] {
                let frame = button.convert(button.bounds, to: hosting)
                XCTAssertEqual(frame.width, 32, accuracy: 0.5)
                XCTAssertEqual(frame.height, 32, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, 60)
                // Even the empty corners around the 12pt symbol hit the native button.
                for x in [CGFloat(1), button.bounds.width - 1] {
                    for y in [CGFloat(1), button.bounds.height - 1] {
                        let point = button.convert(NSPoint(x: x, y: y), to: button.superview)
                        XCTAssertTrue(button.hitTest(point) === button)
                    }
                }
                XCTAssertEqual(button.alphaValue, 1)
            }
            favorite.performClick(nil)
            edit.performClick(nil)
            XCTAssertEqual(calls.favorite, 1)
            XCTAssertEqual(calls.edit, 1)
            XCTAssertEqual(calls.connect, 0)
            XCTAssertEqual(calls.select, 0)
            XCTAssertEqual(calls.delete, 0)
        }
    }

    @MainActor func testRerenderUpdatesFavoriteStateAndActionsWithoutStaleHandlers() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "Fixture"; host.address = "fixture.invalid"
        let original = HostCardCalls(), updated = HostCardCalls()
        func card(_ host: TabbyNative.Host, calls: HostCardCalls, enabled: Bool = true) -> some View {
            HostCard(host: host, selected: true, compact: true,
                     select: { calls.select += 1 }, connect: { calls.connect += 1 }, edit: { calls.edit += 1 },
                     favorite: { calls.favorite += 1 }, delete: { calls.delete += 1 })
                .disabled(!enabled).frame(width: 290, height: 60).environmentObject(store)
        }
        let hosting = NSHostingView(rootView: card(host, calls: original))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        _ = try await buttons(in: hosting)
        host.favorite = true
        hosting.rootView = card(host, calls: updated)
        try await Task.sleep(for: .milliseconds(30))
        let current = try await buttons(in: hosting)
        let favorite = try XCTUnwrap(current.first { $0.identifier?.rawValue == "axon-host-favorite-" + host.id.uuidString })
        let edit = try XCTUnwrap(current.first { $0.identifier?.rawValue == "axon-host-edit-" + host.id.uuidString })
        XCTAssertEqual(favorite.toolTip, store.text("Remove favorite", "取消收藏"))
        XCTAssertEqual(favorite.contentTintColor, NSColor(hex: "#EFB143"))
        favorite.performClick(nil)
        edit.performClick(nil)
        XCTAssertEqual(original.favorite + original.edit + original.connect, 0)
        XCTAssertEqual(updated.favorite, 1)
        XCTAssertEqual(updated.edit, 1)
        XCTAssertEqual(updated.connect, 0)
        hosting.rootView = card(host, calls: updated, enabled: false)
        try await Task.sleep(for: .milliseconds(30))
        for button in try await buttons(in: hosting) {
            XCTAssertFalse(button.isEnabled)
            button.performClick(nil)
        }
        XCTAssertEqual(updated.favorite, 1)
        XCTAssertEqual(updated.edit, 1)
    }

    @MainActor private func buttons(in hosting: NSView) async throws -> [HostCardNativeActionButton] {
        func collect(_ view: NSView) -> [HostCardNativeActionButton] {
            let own = (view as? HostCardNativeActionButton).map { [$0] } ?? []
            return own + view.subviews.flatMap { collect($0) }
        }
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if collect(hosting).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        let result = collect(hosting)
        XCTAssertEqual(result.count, 2)
        return result
    }
}

@MainActor private final class HostCardCalls {
    var select = 0
    var connect = 0
    var edit = 0
    var favorite = 0
    var delete = 0
}
