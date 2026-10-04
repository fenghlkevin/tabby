import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

final class TransferPanelTests: XCTestCase {
    @MainActor func testCollapseAndReopenPreserveJobsAndEmptyQueueReturnsSpaceToFiles() async throws {
        let fixture = try await HostedFiles()
        defer { fixture.close() }
        let queue = fixture.model.queue
        let entry = FileEntry(name: "completed.txt", path: "/fixture/completed.txt", directory: false)
        let job = TransferJob(entry: entry, destination: "/fixture/destination.txt", source: LocalFiles(), target: LocalFiles(), direction: "download")
        job.state = "completed"
        queue.jobs = [job]
        try await fixture.settle()
        let expanded = try fixture.tableFrame()
        try fixture.capture("transfer-panel-expanded")

        try fixture.button("transfer-queue-collapse").performClick(nil)
        try await fixture.settle()
        XCTAssertFalse(queue.panelExpanded)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertTrue(queue.jobs[0] === job)
        XCTAssertFalse(job.cancelled)
        XCTAssertEqual(job.state, "completed")
        let collapsed = try fixture.tableFrame()
        XCTAssertEqual(collapsed.height - expanded.height, 114, accuracy: 1)
        try fixture.capture("transfer-panel-collapsed")

        try fixture.button("transfer-queue-expand").performClick(nil)
        try await fixture.settle()
        XCTAssertTrue(queue.panelExpanded)
        XCTAssertEqual(try fixture.tableFrame().height, expanded.height, accuracy: 1)

        // No file-pane update is involved in clearing the queue. Its observing
        // visibility boundary must still disappear immediately.
        queue.clearFinished()
        try await fixture.settle()
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(try fixture.tableFrame().height - expanded.height, 150, accuracy: 1)
        XCTAssertNil(fixture.findButton("transfer-queue-collapse"))
        XCTAssertNil(fixture.findButton("transfer-queue-expand"))
        try fixture.capture("transfer-panel-empty")
    }

    @MainActor func testNewTransferReopensHiddenPanelAndHidingDoesNotCancelRunningJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), target = root.appendingPathComponent("target.txt")
        try Data("copied while the panel was collapsed".utf8).write(to: source)
        let backend = LocalFiles(), queue = TransferQueue()
        let entry = try await backend.stat(source.path)
        let existing = TransferJob(entry: entry, destination: root.appendingPathComponent("old.txt").path, source: backend, target: backend, direction: "copy")
        existing.state = "running"
        queue.jobs = [existing]
        queue.collapsePanel()
        XCTAssertFalse(existing.cancelled)
        XCTAssertEqual(existing.state, "running")

        try queue.enqueue(entry, destination: target.path, source: backend, target: backend, direction: "copy")
        XCTAssertTrue(queue.panelExpanded)
        queue.collapsePanel()
        await queue.runner?.value
        XCTAssertFalse(queue.panelExpanded)
        XCTAssertFalse(queue.jobs[1].cancelled)
        XCTAssertEqual(queue.jobs[1].state, "completed")
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))

        // Invalid new jobs do not override the user's collapsed preference.
        XCTAssertThrowsError(try queue.enqueue(entry, destination: source.path, source: backend, target: backend, direction: "copy"))
        XCTAssertFalse(queue.panelExpanded)
    }

    @MainActor private final class HostedFiles {
        let root: URL
        let store: AppStore
        let model: FileManagerModel
        let hosting: NSHostingView<AnyView>
        let window: NSWindow

        init() async throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: root.appendingPathComponent("example.txt"))
            store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
            store.workspace.preferences.language = "zh-CN"
            model = FileManagerModel(session: TerminalSession(host: nil, store: store))
            model.local = FilePane(path: root.path, backend: LocalFiles())
            await model.local.navigate(root.path)
            await model.selectLocal(path: root.path)
            hosting = NSHostingView(rootView: AnyView(FilesView(model: model).environmentObject(store)))
            hosting.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
        }
        func close() { model.close(); window.close(); try? FileManager.default.removeItem(at: root) }
        func settle() async throws { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
        func findButton(_ identifier: String) -> HostCardNativeActionButton? { find(HostCardNativeActionButton.self, in: hosting).first { $0.identifier?.rawValue == identifier } }
        func button(_ identifier: String) throws -> HostCardNativeActionButton { try XCTUnwrap(findButton(identifier)) }
        func tableFrame() throws -> NSRect {
            let scroll = try XCTUnwrap(find(NSScrollView.self, in: hosting).first { $0.documentView is FileNativeTable })
            return scroll.convert(scroll.bounds, to: hosting)
        }
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
        }
    }
}
