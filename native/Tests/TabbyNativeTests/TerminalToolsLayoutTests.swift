import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class TerminalToolsLayoutTests: XCTestCase {
    func testSwitchingAllFiveToolsKeepsFullHeightWidthAndHeaderPositions() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-tools-layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        let state = Selection()
        let hosting = NSHostingView(rootView: Fixture(state: state).environmentObject(store))
        let window = show(hosting, size: NSSize(width: 1050, height: 900)); defer { window.close() }
        try await settle(hosting)
        try diagnose(hosting, name: "initial-theme")
        for size in [NSSize(width: 1050, height: 900), NSSize(width: 1400, height: 550)] {
            window.setContentSize(size); try await settle(hosting)
            var original: NSRect?
            var headerFrames: [String: NSRect] = [:]
            for tool in ["theme", "status", "snippets", "history", "productivity", "theme"] {
                let tab = try button(tool, in: hosting)
                tab.performClick(nil); try await settle(hosting)
                if size.height == 900 { try diagnose(hosting, name: tool) }
                XCTAssertEqual(state.tool, tool)
                let panel = try surface(in: hosting)
                let screenBounds = window.convertToScreen(hosting.bounds)
                XCTAssertTrue(screenBounds.insetBy(dx: -1, dy: -1).contains(panel.frame), "The card must stay inside the available terminal area")
                if let original {
                    XCTAssertEqual(panel.frame.width, original.width, accuracy: 1)
                    XCTAssertEqual(panel.frame.minX, original.minX, accuracy: 1)
                    XCTAssertEqual(panel.frame.maxY, original.maxY, accuracy: 1, "Every page stays aligned with the terminal's top edge")
                } else { original = panel.frame }
                XCTAssertEqual(panel.frame.height, size.height, accuracy: 1, "Each tool fills the entire terminal height")
                let controls = ["productivity", "status", "snippets", "theme"]
                var firstSize: NSSize?
                for id in controls {
                    let control = try button(id, in: hosting)
                    let frame = window.convertToScreen(control.convert(control.bounds, to: nil))
                    XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(frame), "Header control must fit the card")
                    XCTAssertEqual(frame.height, 48, accuracy: 1, "Each navigation tab has a stable 48pt height")
                    if let firstSize {
                        XCTAssertEqual(frame.width, firstSize.width, accuracy: 1)
                        XCTAssertEqual(frame.height, firstSize.height, accuracy: 1)
                    } else { firstSize = frame.size }
                    if let previous = headerFrames[id] { XCTAssertEqual(frame, previous, "Switching content must not move header buttons") }
                    headerFrames[id] = frame
                }
                let close = try button("close", in: hosting)
                let closeFrame = window.convertToScreen(close.convert(close.bounds, to: nil))
                XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(closeFrame), "Close control must fit the card")
                XCTAssertEqual(closeFrame.width, 34, accuracy: 1)
                XCTAssertEqual(closeFrame.height, 34, accuracy: 1)
                if let previous = headerFrames["close"] { XCTAssertEqual(closeFrame, previous, "Switching content must not move the close button") }
                headerFrames["close"] = closeFrame
            }

        }
        try button("close", in: hosting).performClick(nil); try await settle(hosting)
        XCTAssertFalse(state.visible)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testLongSnippetListScrollsAndFilteringKeepsFullHeightSidebar() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-tools-scroll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        store.workspace.snippets = (0..<30).map { index in
            var snippet = CommandSnippet(); snippet.name = String(format: "Command %02d", index)
            snippet.group = "Fixture"; snippet.body = "printf 'layout fixture with a deliberately long command'\nprintf 'second line'"
            return snippet
        }
        let state = Selection(); state.tool = "snippets"
        let hosting = NSHostingView(rootView: Fixture(state: state).environmentObject(store))
        let window = show(hosting, size: NSSize(width: 1050, height: 550)); defer { window.close() }
        try await settle(hosting)
        let initial = try surface(in: hosting).frame
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 })
        XCTAssertLessThanOrEqual(scroll.frame.width, initial.width)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 2, "Long commands wrap inside the card")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView); try await settle(hosting)
        XCTAssertTrue(nodes(hosting).contains { $0.text.contains("Command 29") && $0.frame.intersects(window.convertToScreen(hosting.bounds)) }, "The final command remains reachable by scrolling")
        let close = try button("close", in: hosting)
        let closeFrame = window.convertToScreen(close.convert(close.bounds, to: nil))
        XCTAssertTrue(initial.contains(closeFrame), "Scrolling content must keep the tool header visible")
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        let search = try XCTUnwrap(find(NSTextField.self, in: hosting).first { $0.placeholderString == "Search snippets" })
        window.makeFirstResponder(search)
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("Command 29", replacementRange: editor.selectedRange())
        try await settle(hosting)
        let filtered = try surface(in: hosting).frame
        XCTAssertEqual(filtered.width, initial.width, accuracy: 1)
        XCTAssertEqual(filtered.maxY, initial.maxY, accuracy: 1)
        XCTAssertEqual(filtered.height, initial.height, accuracy: 1, "Filtering changes the content while the sidebar stays full height")
        XCTAssertLessThanOrEqual(document.bounds.height, scroll.contentView.bounds.height + 2, "Filtering removes the obsolete scroll range")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testRepeatedToggleInRealWorkspaceKeepsWindowFrameAndLiveShell() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-tools-window-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        store.workspace.preferences.localShell = "/bin/sh"
        store.workspace.preferences.localLoginShell = false
        store.connect()
        let session = try XCTUnwrap(store.sessions.first)
        // Keep the production hosting size policies; clearing sizingOptions
        // would conceal content minimum-size feedback into the outer window.
        let hosting = NSHostingView(rootView: MainView().environmentObject(store).frame(minWidth: 1050, minHeight: 680))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer {
            store.monitoring.stop()
            session.disconnect(); window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try await settle(hosting)
        let terminal = try XCTUnwrap(session.terminal as? LocalProcessTerminalView)
        terminal.process.send(data: Array("trap 'exit 0' TERM; printf 'SIDEBAR_%s\\n' 'READY'\n".utf8)[...])
        try await settle(hosting)
        let generation = session.generation
        let originalWindowNumber = window.windowNumber
        for size in [NSSize(width: 1400, height: 860), NSSize(width: 1050, height: 680)] {
            window.setContentSize(size); try await settle(hosting)
            let originalFrame = window.frame
            let originalMinimum = window.contentMinSize
            let fullTerminalWidth = terminal.frame.width
            let collapsedTerminalWidth = fullTerminalWidth - TerminalToolsPanel.width
            func sampleTransitionWidths() async throws -> [CGFloat] {
                var widths: [CGFloat] = []
                // Sample across the transition rather than depending on one
                // exact frame. These pauses yield the main actor to SwiftUI.
                for pause in [30, 40, 50] {
                    try await Task.sleep(for: .milliseconds(pause))
                    hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
                    widths.append(terminal.frame.width)
                    XCTAssertEqual(window.frame, originalFrame, "The window stays fixed throughout the sidebar animation")
                    XCTAssertEqual(window.contentMinSize, originalMinimum)
                }
                return widths
            }
            func assertIntermediateWidth(_ widths: [CGFloat], operation: String) {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                XCTAssertTrue(widths.contains { $0 > collapsedTerminalWidth + 2 && $0 < fullTerminalWidth - 2 },
                              "\(operation) must animate the actual terminal viewport through an intermediate width; sampled \(widths)")
            }
            for cycle in 0..<8 {
                try pressToolsToggle(in: hosting)
                if cycle == 0 {
                    let widths = try await sampleTransitionWidths()
                    assertIntermediateWidth(widths, operation: "Opening")
                }
                try await settle(hosting)
                XCTAssertEqual(window.frame, originalFrame, "Opening the sidebar must not resize or move the window (cycle \(cycle))")
                XCTAssertEqual(window.contentMinSize, originalMinimum, "Tools content must not change the window minimum size")
                let panel = try surface(in: hosting).frame
                let bounds = window.convertToScreen(hosting.bounds)
                XCTAssertEqual(panel.width, TerminalToolsPanel.width, accuracy: 1)
                XCTAssertEqual(panel.minY, bounds.minY, accuracy: 1, "The sidebar reaches the workspace bottom")
                XCTAssertEqual(panel.height, bounds.height - 53, accuracy: 1, "The sidebar fills the workspace below its 53pt title bar")
                XCTAssertEqual(terminal.frame.width, fullTerminalWidth - TerminalToolsPanel.width, accuracy: 2, "Only the terminal viewport shrinks")
                if cycle == 0 && size.width == 1400 { try diagnose(hosting, name: "real-workspace-open") }
                for tool in ["productivity", "status", "snippets", "theme"] {
                    try button(tool, in: hosting).performClick(nil); try await settle(hosting)
                    XCTAssertEqual(window.frame, originalFrame, "Changing tools must not resize the outer window")
                    XCTAssertEqual(try surface(in: hosting).frame, panel)
                    if cycle == 0 && size.width == 1400 && tool == "snippets" { try diagnose(hosting, name: "real-workspace-snippets") }
                }
                if cycle.isMultiple(of: 2) {
                    try button("close", in: hosting).performClick(nil)
                } else {
                    try pressToolsToggle(in: hosting)
                }
                if cycle == 0 {
                    let widths = try await sampleTransitionWidths()
                    assertIntermediateWidth(widths, operation: "Closing")
                }
                try await settle(hosting)
                XCTAssertEqual(window.frame, originalFrame, "Closing the sidebar must not resize the outer window")
                XCTAssertEqual(terminal.frame.width, fullTerminalWidth, accuracy: 2)
                XCTAssertFalse(nodes(hosting).contains { $0.identifier == "axon-terminal-tools-panel" })
                if cycle == 0 && size.width == 1400 { try diagnose(hosting, name: "real-workspace-closed") }
                XCTAssertTrue(session.terminal === terminal)
                XCTAssertTrue(terminal.process.running)
                XCTAssertEqual(session.generation, generation)
                XCTAssertEqual(window.windowNumber, originalWindowNumber)
            }

            // Reverse before the preceding animation can finish, as happens
            // when repeatedly clicking the native title-bar control.
            for reversal in 0..<5 {
                try pressToolsToggle(in: hosting)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(35))
                XCTAssertEqual(window.frame, originalFrame, "Rapid reversal must not resize the outer window (reversal \(reversal))")
                XCTAssertEqual(window.contentMinSize, originalMinimum)
                XCTAssertTrue(session.terminal === terminal)
                XCTAssertTrue(terminal.process.running)
                XCTAssertEqual(session.generation, generation)
            }
            try await settle(hosting)
            let reversedPanel = try surface(in: hosting).frame
            let bounds = window.convertToScreen(hosting.bounds)
            XCTAssertEqual(reversedPanel.width, TerminalToolsPanel.width, accuracy: 1)
            XCTAssertEqual(reversedPanel.minY, bounds.minY, accuracy: 1)
            XCTAssertEqual(reversedPanel.height, bounds.height - 53, accuracy: 1)
            XCTAssertEqual(terminal.frame.width, fullTerminalWidth - TerminalToolsPanel.width, accuracy: 2, "The final click opens one sidebar after rapid reversal")

            // Exercise both entry points while a close/open transition is in
            // flight. The last X must determine the final collapsed state.
            try button("close", in: hosting).performClick(nil)
            try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(window.frame, originalFrame)
            try pressToolsToggle(in: hosting)
            try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(window.frame, originalFrame)
            try button("close", in: hosting).performClick(nil)
            try await settle(hosting)
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertEqual(window.contentMinSize, originalMinimum)
            XCTAssertEqual(terminal.frame.width, fullTerminalWidth, accuracy: 2)
            XCTAssertFalse(nodes(hosting).contains { $0.identifier == "axon-terminal-tools-panel" }, "The final X removes the sidebar after rapid reversal")
            XCTAssertTrue(session.terminal === terminal)
            XCTAssertTrue(terminal.process.running)
            XCTAssertEqual(session.generation, generation)
            XCTAssertEqual(window.windowNumber, originalWindowNumber)
        }
        terminal.process.send(data: Array("printf 'SIDEBAR_%s\\n' 'ALIVE'\n".utf8)[...])
        try await settle(hosting)
        XCTAssertTrue(String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("SIDEBAR_ALIVE"))
    }

    private func pressToolsToggle(in view: NSView) throws {
        if let button = find(NSButton.self, in: view).first(where: { $0.identifier?.rawValue == "axon-terminal-tools-toggle" }) {
            button.performClick(nil); return
        }
        let node = try XCTUnwrap(nodes(view).first { $0.role == "AXButton" && $0.text == "Terminal tools" })
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.object.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(node.object.method(for: selector), to: Press.self)(node.object, selector))
    }

    private final class Selection: ObservableObject {
        @Published var tool = "theme"
        @Published var visible = true
    }
    private struct Fixture: View {
        @ObservedObject var state: Selection
        var body: some View {
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 0) {
                    Color(hex: "#1e1f29").frame(maxWidth: .infinity, maxHeight: .infinity)
                    if state.visible {
                        TerminalToolsPanel(selection: $state.tool, isVisible: $state.visible, availableHeight: geometry.size.height)
                    }
                }
            }.background(Color(hex: "#1e1f29"))
        }
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(350)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    private func button(_ tool: String, in view: NSView) throws -> NSButton {
        let id = tool == "close" ? "axon-terminal-tools-close" : "axon-terminal-tool-" + tool
        return try XCTUnwrap(find(NSButton.self, in: view).first { $0.identifier?.rawValue == id })
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
    private func surface(in view: NSView) throws -> Node { try XCTUnwrap(nodes(view).first { $0.identifier == "axon-terminal-tools-panel" && $0.frame.width > 250 && $0.frame.height > 40 }) }
    private func diagnose(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records = nodes(view).filter { $0.identifier.hasPrefix("axon-terminal-tools") }.map { ["id": $0.identifier, "class": String(describing: type(of: $0.object)), "frame": NSStringFromRect($0.frame), "text": String($0.text.prefix(100))] }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("tools-" + name + ".json"))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("tools-" + name + ".png"))
    }
    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var identifier: String { read("accessibilityIdentifier") as? String ?? "" }
        var role: String { read("accessibilityRole") as? String ?? "" }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var text: String { ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityPlaceholderValue"].compactMap { read($0) as? String }.joined(separator: " ") }
        func setValue(_ value: String) -> Bool {
            let setter = NSSelectorFromString("setAccessibilityValue:")
            guard object.responds(to: setter) else { return false }
            object.perform(setter, with: value)
            return true
        }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 50, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0); if let window = root.window { visit(window, depth: 0) }
        return result
    }
    private func enableAccessibility() -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(attribute) else { return {} }
        let old = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        return { NSApp.accessibilitySetValue(old ?? false, forAttribute: attribute) }
    }
}
