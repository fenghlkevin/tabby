import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

@MainActor final class SelectionPopoverTests: XCTestCase {
    func testActualPopoverKeyboardSelectionDisabledRowsAndEscape() async throws {
        _ = NSApplication.shared
        var selected = "one"
        let field = AxonChoiceField(selection: Binding(get: { selected }, set: { selected = $0 }), choices: [("one", "当前选项"), ("two", "生产环境-production-long-option"), ("three", "第三项")], placeholder: "选择", symbol: "server.rack", identifier: "axon-popover-test")
        let host = NSHostingView(rootView: field.frame(width: 300, height: 38).padding(20)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { AxonMenuPopover.active?.popover.close(); window.close() }
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(find(SelectionFieldButton.self, in: host).first)
        button.performClick(nil); try await Task.sleep(for: .milliseconds(200))
        let popup = try XCTUnwrap(AxonMenuPopover.active); XCTAssertTrue(popup.popover.isShown)
        try capture(try XCTUnwrap(popup.popover.contentViewController?.view.window?.contentView), name: "choice-menu")
        popup.menu.items[1].isEnabled = false
        XCTAssertTrue(popup.handleKey(125)); XCTAssertEqual(popup.highlighted, 2)
        XCTAssertTrue(popup.handleKey(36)); XCTAssertEqual(selected, "three")
        button.performClick(nil); try await Task.sleep(for: .milliseconds(180))
        let cancelled = try XCTUnwrap(AxonMenuPopover.active)
        XCTAssertTrue(cancelled.handleKey(53)); XCTAssertEqual(selected, "three")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(cancelled.popover.isShown, "Escape closes the actual popover")
        XCTAssertNil(AxonMenuPopover.active, "Escape releases the active presenter")
        let disabledHost = NSHostingView(rootView: field.disabled(true).frame(width: 300, height: 38).padding(20)); disabledHost.sizingOptions = []
        window.contentView = disabledHost
        try await Task.sleep(for: .milliseconds(150)); disabledHost.layoutSubtreeIfNeeded()
        let disabled = try XCTUnwrap(find(SelectionFieldButton.self, in: disabledHost).first)
        XCTAssertFalse(disabled.isEnabled); disabled.performClick(nil)
        XCTAssertNil(AxonMenuPopover.active)
    }
    func testReferenceChoiceAndActionPanelsRenderAtCompactAndWideSizes() async throws {
        _ = NSApplication.shared
        for width in [340.0, 420.0] {
            let host = NSHostingView(rootView: VStack(spacing: 18) {
                AuthenticationSelector(selection: .constant("password"), passwordTitle: "密码", keyTitle: "私钥")
                Toggle("同步输入到已选终端", isOn: .constant(true)).toggleStyle(AxonCheckboxStyle())
                Toggle("未选中的选项", isOn: .constant(false)).toggleStyle(AxonCheckboxStyle())
                Toggle("不可用选项", isOn: .constant(true)).toggleStyle(AxonCheckboxStyle()).disabled(true)
                JumpHostChooser(selection: nil, hosts: [], chinese: true) { _ in }.frame(maxWidth: .infinity)
            }.padding(16).background(Palette.sidebar).preferredColorScheme(.light)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 32, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded(); try capture(host, name: "selection-cards-\(Int(width))"); window.close()
        }
    }
    func testNativeFieldPopoversShareAppearanceInBothLanguages() async throws {
        _ = NSApplication.shared
        var credential = VaultCredential(); credential.name = "部署身份-production-deploy"; credential.username = "deploy"
        for chinese in [true, false] {
            let choices: [(String, AnyView)] = [
                ("group", AnyView(GroupPicker(selection: .constant("Production"), groups: ["Production", "Personal"], chinese: chinese))),
                ("font", AnyView(TerminalFontPicker(selection: .constant("Menlo"), chinese: chinese))),
                ("credential", AnyView(CredentialPicker(selectedID: .constant(credential.id), credentials: [credential], chinese: chinese, enabled: true, onNew: {})))
            ]
            for (name, content) in choices {
                let host = NSHostingView(rootView: content.frame(width: 340, height: 38).padding(20)); host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 380, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
                let button = try XCTUnwrap(find(NSButton.self, in: host).first { $0.accessibilityRole() == .popUpButton })
                button.performClick(nil); try await Task.sleep(for: .milliseconds(180))
                let popup = try XCTUnwrap(AxonMenuPopover.active)
                try capture(try XCTUnwrap(popup.popover.contentViewController?.view.window?.contentView), name: "popup-\(name)-\(chinese ? "zh" : "en")")
                popup.popover.close(); window.close()
            }
        }
    }
    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/ui-0.10.5")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
}
