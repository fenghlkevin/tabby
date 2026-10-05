import AppKit
import XCTest
@testable import TabbyNative

@MainActor final class HostDeletionConfirmationTests: XCTestCase {
    private func host(name: String = "moi-10.224.250.6", address: String = "10.224.250.6", port: Int = 22) -> TabbyNative.Host {
        var host = TabbyNative.Host()
        host.name = name; host.address = address; host.port = port; host.username = "root"
        return host
    }

    func testOnlyExplicitDeleteConfirmsAndReleasesModalWindow() throws {
        _ = NSApplication.shared
        let parent = visibleParent()
        defer { parent.close() }
        let controller = HostDeletionConfirmationWindowController(host: host(), chinese: true)
        let result = try runModal(controller) { _, _, root in
            try self.button("axon-host-delete-confirm", in: root).performClick(nil)
        }
        XCTAssertTrue(result)
        XCTAssertNil(controller.window)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(parent.isVisible, "Confirming must leave the workspace window open")
    }

    func testCancelCloseReturnAndEscapeNeverConfirmOrStopAnotherModal() throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let parent = visibleParent()
        defer { parent.close() }
        for action in ["cancel", "window", "close", "return", "escape"] {
            let controller = HostDeletionConfirmationWindowController(host: host(), chinese: false)
            let inactive = HostDeletionConfirmationWindowController(host: host(name: "other-host"), chinese: true)
            let inactiveWindow = inactive.prepareWindow()
            defer { inactiveWindow.delegate = nil; inactiveWindow.close() }
            let result = try runModal(controller) { _, window, root in
                inactive.cancel(); inactive.confirm()
                XCTAssertTrue(NSApp.modalWindow === window, "An inactive controller must not finish another host's confirmation")
                switch action {
                case "cancel": try self.button("axon-host-delete-cancel", in: root).performClick(nil)
                case "window": window.performClose(nil)
                case "close": try self.pressClose(in: root)
                case "return":
                    let cancel = try self.button("axon-host-delete-cancel", in: root)
                    let confirm = try self.button("axon-host-delete-confirm", in: root)
                    XCTAssertTrue(window.defaultButtonCell === cancel.cell)
                    XCTAssertEqual(cancel.keyEquivalent, "\r")
                    XCTAssertNotEqual(confirm.keyEquivalent, "\r")
                    window.sendEvent(try self.keyEvent("\r", code: 36, window: window))
                default: window.sendEvent(try self.keyEvent("\u{1b}", code: 53, window: window))
                }
            }
            XCTAssertFalse(result, "\(action) must cancel deletion")
            XCTAssertNil(controller.window)
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertTrue(parent.isVisible, "\(action) must leave the workspace window open")
        }
    }

    func testLocalizedHostSummariesAndControlsRenderWithinPanelBounds() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let fixtures: [(String, Bool, TabbyNative.Host)] = [
            ("zh", true, host()),
            ("en", false, host(name: "Production database")),
            ("long", true, host(name: String(repeating: "生产数据库主机名称很长", count: 8))),
            ("empty-name", false, host(name: "", address: "unnamed-host.example.invalid")),
            ("ipv6", false, host(name: "IPv6 fixture", address: "2001:db8::42", port: 2222)),
        ]
        for (name, chinese, host) in fixtures {
            let controller = HostDeletionConfirmationWindowController(host: host, chinese: chinese)
            let window = controller.prepareWindow()
            defer { window.delegate = nil; window.close() }
            window.center(); window.makeKeyAndOrderFront(nil)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            XCTAssertTrue(window is NSPanel)
            XCTAssertEqual(window.backgroundColor, NSColor(Palette.card))
            let cancel = try button("axon-host-delete-cancel", in: root)
            let confirm = try button("axon-host-delete-confirm", in: root)
            XCTAssertEqual(cancel.title, chinese ? "取消" : "Cancel")
            XCTAssertTrue(confirm.title.contains(chinese ? "删除" : "Delete"))
            let objects = accessibilityObjects(root)
            let exposedText = objects.flatMap { object in
                [read(object, "accessibilityLabel") as? String, read(object, "accessibilityValue") as? String].compactMap { $0 }
            }.joined(separator: "\n")
            XCTAssertTrue(exposedText.contains(host.name.isEmpty ? host.address : host.name), "\(name): the actual host must be identifiable")
            XCTAssertTrue(exposedText.contains(host.address), "\(name): the address must be available to assistive technology")
            XCTAssertTrue(exposedText.contains(":" + String(host.port)), "\(name): the endpoint must include the port")
            XCTAssertNotNil(objects.first { read($0, "accessibilityIdentifier") as? String == "axon-host-delete-close" })
            try auditAndCapture(root, window: window, name: name)
        }
    }

    private func visibleParent() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func runModal(_ controller: HostDeletionConfirmationWindowController,
                          action: @escaping (HostDeletionConfirmationWindowController, NSWindow, NSView) throws -> Void) throws -> Bool {
        XCTAssertNil(NSApp.modalWindow)
        var dispatched = false
        let readyAt = Date().addingTimeInterval(0.12)
        let dispatch = Timer(timeInterval: 0.03, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard Date() >= readyAt, let window = controller.window, NSApp.modalWindow === window,
                      let root = window.contentView else { return }
                dispatched = true; timer.invalidate()
                root.layoutSubtreeIfNeeded()
                do { try action(controller, window, root) }
                catch { XCTFail("Could not operate the actual host confirmation: \(error)"); controller.cancel() }
            }
        }
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTFail("Host confirmation did not finish after the requested action")
                controller.cancel()
                if NSApp.modalWindow === controller.window { NSApp.stopModal(withCode: .abort) }
            }
        }
        RunLoop.main.add(dispatch, forMode: .modalPanel)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { dispatch.invalidate(); watchdog.invalidate() }
        let result = controller.present()
        XCTAssertTrue(dispatched, "The test must reach the actual modal window")
        return result
    }

    private func keyEvent(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
    private func button(_ identifier: String, in root: NSView) throws -> PreferencesRectNativeButton {
        try XCTUnwrap(find(PreferencesRectNativeButton.self, in: root).first { $0.identifier?.rawValue == identifier })
    }
    private func read(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }
    private func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in read(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }
    private func pressClose(in root: NSView) throws {
        let close = try XCTUnwrap(accessibilityObjects(root).first {
            read($0, "accessibilityIdentifier") as? String == "axon-host-delete-close"
                && read($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue
        })
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(close.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(close.method(for: selector), to: Press.self)(close, selector))
    }
    private func auditAndCapture(_ root: NSView, window: NSWindow, name: String) throws {
        let card = NSRect(x: root.bounds.midX - 220, y: root.bounds.midY - 152, width: 440, height: 304)
        XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(card))
        let cancel = try button("axon-host-delete-cancel", in: root)
        let confirm = try button("axon-host-delete-confirm", in: root)
        let frames = [cancel, confirm].map { $0.convert($0.bounds, to: root) }
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.width, 80)
            XCTAssertGreaterThanOrEqual(frame.height, 30)
            XCTAssertTrue(card.contains(frame), "\(name): action button exceeds the panel")
            let bottomInset = root.isFlipped ? card.maxY - frame.maxY : frame.minY - card.minY
            XCTAssertGreaterThanOrEqual(bottomInset, 12, "\(name): footer button loses its bottom padding")
        }
        XCTAssertFalse(frames[0].intersects(frames[1]), "\(name): Cancel and Delete overlap")
        let screenCard = window.convertToScreen(root.convert(card, to: nil))
        var audit = ["window=\(window.frame)", "root.bounds=\(root.bounds)", "card=\(card)",
                     "native:cancel=\(frames[0])", "native:confirm=\(frames[1])"]
        var auditedLeaves = 0
        for object in accessibilityObjects(root) {
            guard let role = read(object, "accessibilityRole") as? String,
                  [NSAccessibility.Role.staticText.rawValue, NSAccessibility.Role.button.rawValue].contains(role),
                  let value = read(object, "accessibilityFrame") as? NSValue else { continue }
            let frame = value.rectValue
            guard frame.width > 0, frame.height > 0 else { continue }
            let label = read(object, "accessibilityLabel") as? String ?? read(object, "accessibilityValue") as? String ?? ""
            XCTAssertTrue(screenCard.insetBy(dx: -1, dy: -1).contains(frame), "\(name): \(label) exceeds the panel")
            audit.append("\(role)\t\(frame)\t\(label)")
            auditedLeaves += 1
        }
        XCTAssertGreaterThanOrEqual(auditedLeaves, 5, "The audit must include the real labels and controls")
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: card))
        root.cacheDisplay(in: card, to: bitmap)
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)).count, 8,
                             "\(name): the render must contain the dialog's actual text and controls")
        if let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("host-delete-\(name).png"))
            try audit.joined(separator: "\n").write(to: directory.appendingPathComponent("host-delete-\(name)-layout.txt"), atomically: true, encoding: .utf8)
        }
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key)
        NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
}
