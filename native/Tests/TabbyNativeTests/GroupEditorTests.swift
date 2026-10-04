import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class GroupEditorTests: XCTestCase {
    @MainActor func testGroupCardEditOpensRightInspectorWithGroupCredentialLabel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.groups = ["公司服务器"]
        store.workspace.groupDefaults = [HostGroup(name: "公司服务器", port: 2222, username: "deploy")]
        try await withWindow(MainView().environmentObject(store), size: NSSize(width: 1300, height: 760)) { hosting in
            let button = try XCTUnwrap(find(HostCardNativeActionButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-group-edit-公司服务器" })
            button.performClick(nil)
            try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
            let credential = try XCTUnwrap(find(CredentialPickerButton.self, in: hosting).first)
            XCTAssertEqual(credential.title, "用于此分组")
            let frame = credential.convert(credential.bounds, to: hosting)
            XCTAssertGreaterThan(frame.minX, 950)
            XCTAssertFalse(store.workspace.hosts.contains { $0.address == "group-defaults.invalid" })
            try capture(hosting, name: "group-right-inspector")
        }
    }

    @MainActor func testInheritedHostShowsBaseAndCanOverrideOneSettingWithoutChangingOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.groups = ["公司服务器"]
        store.workspace.groupDefaults = [HostGroup(name: "公司服务器", port: 2222, username: "deploy")]
        var host = TabbyNative.Host(); host.name = "应用服务器"; host.address = "192.0.2.20"; host.group = "公司服务器"; host.groupInheritance = .all
        try await withWindow(HostEditor(host: host, isNew: true, done: {}).environmentObject(store).foregroundStyle(Palette.text).background(Palette.sidebar).preferredColorScheme(.light), size: NSSize(width: 340, height: 1100)) { hosting in
            let port = try XCTUnwrap(find(NSButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-group-inherit-port" })
            let username = try XCTUnwrap(find(NSButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-group-inherit-username" })
            let authentication = try XCTUnwrap(find(NSButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-group-inherit-authentication" })
            XCTAssertEqual(port.state, .on); XCTAssertEqual(username.state, .on); XCTAssertEqual(authentication.state, .on)
            let jump = try XCTUnwrap(find(NSButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-group-inherit-jump" })
            for toggle in [port, username, authentication, jump] {
                let rect = toggle.convert(toggle.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, 340)
                XCTAssertEqual(rect.width, 96, accuracy: 1); XCTAssertEqual(rect.height, 22, accuracy: 1)
                XCTAssertTrue(toggle.isEnabled)
            }
            try capture(hosting, name: "host-group-inheritance-before")
            XCTAssertTrue(find(CredentialPickerButton.self, in: hosting).isEmpty)
            port.performClick(nil)
            try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(port.state, .off)
            XCTAssertEqual(username.state, .on); XCTAssertEqual(authentication.state, .on)
            XCTAssertTrue(store.workspace.hosts.isEmpty)
            try capture(hosting, name: "host-group-inheritance")
        }
    }

    @MainActor func testTagsManagementHasNoGroupSectionOrGroupCredentialControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"; store.workspace.groups = ["Company"]; store.workspace.tags = ["production"]
        try await withWindow(TagsManagementView().environmentObject(store), size: NSSize(width: 570, height: 560)) { hosting in
            XCTAssertTrue(find(CredentialPickerButton.self, in: hosting).isEmpty)
            XCTAssertTrue(find(NSSegmentedControl.self, in: hosting).isEmpty)
            XCTAssertEqual(store.workspace.groups, ["Company"])
            try capture(hosting, name: "tags-management-only")
        }
    }

    @MainActor func testEmptyTerminalSelectionReturnsToHostLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.section = "terminal"
        try await withWindow(MainView().environmentObject(store), size: NSSize(width: 1200, height: 700)) { hosting in
            XCTAssertEqual(store.section, "hosts")
            XCTAssertNotNil(find(NSSegmentedControl.self, in: hosting).first { $0.identifier?.rawValue == "host-layout-picker" })
            try capture(hosting, name: "empty-sessions-host-library")
            let session = TerminalSession(host: nil, store: store)
            store.sessions = [session]; store.activeSession = session.id; store.section = "terminal"
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.section, "terminal")
            store.close(session.id)
            try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(store.section, "hosts")
            XCTAssertNil(store.activeSession)
        }
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
    @MainActor private func withWindow<Content: View>(_ content: Content, size: NSSize, action: (NSHostingView<Content>) async throws -> Void) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
        try await action(hosting)
    }
    @MainActor private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }
}
