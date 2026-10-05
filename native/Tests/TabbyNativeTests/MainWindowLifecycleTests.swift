import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

final class MainWindowLifecycleTests: XCTestCase {
    @MainActor func testWorkspaceCloseHidesAndDockReopenKeepsWindowViewDraftAndLiveShell() async throws {
        let application = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-main-window-test-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"
        store.workspace.preferences.localLoginShell = false
        store.connect()
        let session = try XCTUnwrap(store.sessions.first)
        let terminal = try XCTUnwrap(session.makeView() as? LocalProcessTerminalView)
        let delegate = ApplicationDelegate(); delegate.store = store
        let appearances = ViewAppearances()
        let hosting = NSHostingView(rootView: WindowDraftFixture(controller: delegate.mainWindowController, appearances: appearances))
        let window = show(hosting)
        let forwardingID = UUID()
        let forwarding = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        store.forwardTasks[forwardingID] = forwarding
        defer {
            forwarding.cancel(); store.forwardTasks.removeValue(forKey: forwardingID)
            session.disconnect(); window.delegate = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil { delegate.mainWindowController.window === window && appearances.appeared > 0 }
        let field = try XCTUnwrap(findTextField(hosting))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("unsaved window draft", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(80))
        let originalGeneration = session.generation
        let originalWindowNumber = window.windowNumber
        let appearCount = appearances.appeared
        XCTAssertTrue(window.isVisible); XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(field.stringValue, "unsaved window draft")

        window.performClose(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.mainWindowController.window === window)
        XCTAssertTrue(window.contentView === hosting)
        XCTAssertEqual(window.windowNumber, originalWindowNumber)
        XCTAssertEqual(session.generation, originalGeneration)
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertTrue(session.connected); XCTAssertTrue(terminal.process.running)
        XCTAssertFalse(forwarding.isCancelled)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        XCTAssertEqual(appearances.disappeared, 0)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false), "The existing window handles reopening")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(delegate.mainWindowController.window === window)
        XCTAssertTrue(window.contentView === hosting)
        XCTAssertEqual(window.windowNumber, originalWindowNumber)
        XCTAssertEqual(field.stringValue, "unsaved window draft")
        XCTAssertEqual(appearances.appeared, appearCount)
        XCTAssertEqual(appearances.disappeared, 0)
        XCTAssertEqual(session.generation, originalGeneration)
        XCTAssertFalse(forwarding.isCancelled)
        terminal.process.send(data: Array("printf 'WINDOW_REOPEN_%s\\n' 'SHELL_ALIVE'\n".utf8)[...])
        try await waitUntil {
            String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("WINDOW_REOPEN_SHELL_ALIVE")
        }
    }

    @MainActor func testProxyPreservesExistingWindowDelegateAndDoesNotInterceptAnotherWindow() throws {
        _ = NSApplication.shared
        let controller = MainWindowLifecycleController()
        let original = OriginalWindowDelegate()
        let main = show(NSView())
        let otherDelegate = OriginalWindowDelegate()
        let other = show(NSView())
        defer { main.delegate = nil; main.close(); other.delegate = nil; other.close() }
        main.delegate = original; other.delegate = otherDelegate
        controller.attach(to: main)
        XCTAssertTrue(main.delegate === controller)
        XCTAssertTrue(other.delegate === otherDelegate)
        let notification = Notification(name: NSWindow.didResizeNotification, object: main)
        main.delegate?.windowDidResize?(notification)
        XCTAssertEqual(original.resizeCalls, 1)
        main.performClose(nil)
        XCTAssertFalse(main.isVisible)
        XCTAssertEqual(original.closeCalls, 0, "The workspace's original close callback must not destroy its scene")
        XCTAssertEqual(original.willCloseCalls, 0)
        XCTAssertTrue(controller.windowShouldClose(other))
        other.performClose(nil)
        XCTAssertEqual(otherDelegate.closeCalls, 1)
        XCTAssertEqual(otherDelegate.willCloseCalls, 1)
        XCTAssertFalse(other.isVisible)
    }

    @MainActor func testDockReopenUsesDeminiaturizeBranchAndMissingWindowAllowsNormalReopen() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        XCTAssertTrue(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        // XCTest's host does not reliably admit Dock miniaturization. Control
        // only that OS state while keeping an actual NSWindow for visibility,
        // retained identity and the production reopen callback.
        let window = ControlledMiniaturizedWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)
        defer { window.delegate = nil; window.close() }
        delegate.mainWindowController.attach(to: window)
        let number = window.windowNumber
        window.orderOut(nil); window.simulatedMiniaturized = true
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertEqual(window.deminiaturizeCalls, 1)
        XCTAssertFalse(window.isMiniaturized); XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.windowNumber, number)
        XCTAssertTrue(delegate.mainWindowController.window === window)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertEqual(window.deminiaturizeCalls, 1, "An already restored window must not be deminiaturized again")
    }

    @MainActor func testExplicitApplicationTerminationStillDisconnectsShellAndCancelsForwarding() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-main-window-quit-test-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.localShell = "/bin/sh"
        store.workspace.preferences.localLoginShell = false
        store.connect()
        let session = try XCTUnwrap(store.sessions.first)
        let terminal = try XCTUnwrap(session.makeView() as? LocalProcessTerminalView)
        let forwarding = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let forwardingID = UUID(); store.forwardTasks[forwardingID] = forwarding
        let delegate = ApplicationDelegate(); delegate.store = store
        let window = show(NSView()); delegate.mainWindowController.attach(to: window)
        defer {
            forwarding.cancel(); session.disconnect(); window.delegate = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        // Interactive sh ignores SIGTERM by default. Install an observable
        // handler so this fixture exercises terminate(), not a held object's
        // later deinitializer and force-kill escalation.
        terminal.process.send(data: Array("trap 'exit 0' TERM; printf 'QUIT_TRAP_%s\\n' 'READY'\n".utf8)[...])
        try await waitUntil {
            String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("QUIT_TRAP_READY")
        }
        let pid = terminal.process.shellPid
        let childPID = try XCTUnwrap(pid > 0 ? pid : nil)
        let originalGeneration = session.generation
        window.performClose(nil)
        XCTAssertTrue(terminal.process.running); XCTAssertFalse(forwarding.isCancelled)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: NSApplication.shared))
        XCTAssertTrue(forwarding.isCancelled)
        XCTAssertFalse(session.connected)
        XCTAssertGreaterThan(session.generation, originalGeneration)
        try await waitUntil { !terminal.process.running }
        XCTAssertEqual(terminal.process.shellPid, 0)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Explicit termination must signal and reap the fixture child")
    }

    @MainActor private func show(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }
    @MainActor private func findTextField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let field = findTextField(child) { return field } }
        return nil
    }
    @MainActor private func waitUntil(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Main-window lifecycle transition timed out at caller \(line)")
    }
}

@MainActor private final class ViewAppearances {
    var appeared = 0
    var disappeared = 0
}

private struct WindowDraftFixture: View {
    let controller: MainWindowLifecycleController
    let appearances: ViewAppearances
    @State private var text = ""
    var body: some View {
        TextField("Draft", text: $text).padding(24)
            .background(MainWindowLifecycleProbe(controller: controller))
            .onAppear { appearances.appeared += 1 }
            .onDisappear { appearances.disappeared += 1 }
    }
}

@MainActor private final class OriginalWindowDelegate: NSObject, NSWindowDelegate {
    var resizeCalls = 0
    var closeCalls = 0
    var willCloseCalls = 0
    func windowDidResize(_ notification: Notification) { resizeCalls += 1 }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeCalls += 1; return true }
    func windowWillClose(_ notification: Notification) { willCloseCalls += 1 }
}

/// Only substitutes Dock miniaturization state, which the XCTest host cannot
/// reliably enter. Real release-app minimize/reopen needs separate UI checks.
private final class ControlledMiniaturizedWindow: NSWindow {
    var simulatedMiniaturized = false
    private(set) var deminiaturizeCalls = 0
    override var isMiniaturized: Bool { simulatedMiniaturized }
    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCalls += 1
        simulatedMiniaturized = false
    }
}
