import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

final class FileErrorPresentationTests: XCTestCase {
    @MainActor func testErrorNotificationKeepsFileTableFrameWhenShownRepeatedAndDismissed() async throws {
        let fixture = try HostedFilePane()
        defer { fixture.close() }
        let message = "Could not copy /Users/Test User/Documents/archived projects/quarterly reports/a very long filename.txt into /Users/Test User/Downloads/another folder: permission denied."

        for width in [CGFloat(650), CGFloat(300)] {
            let before = try await fixture.tableFrame(width: width)
            try fixture.capture(named: "file-pane-\(Int(width))-before")
            fixture.pane.error = message
            let shown = try await fixture.tableFrame(width: width)
            assertSameFrame(shown, before)
            XCTAssertEqual(fixture.pane.error, message)
            try fixture.capture(named: "file-pane-\(Int(width))-error")

            fixture.pane.error = message
            let repeated = try await fixture.tableFrame(width: width)
            assertSameFrame(repeated, before)

            fixture.pane.error = nil
            let dismissed = try await fixture.tableFrame(width: width)
            assertSameFrame(dismissed, before)
        }
        try await fixture.captureTransferQueueIfRequested()
    }

    @MainActor func testRepeatedErrorRemainsVisiblePastOldDeadlineThenAutomaticallyDismisses() async throws {
        let fixture = try HostedFilePane()
        defer { fixture.close() }
        let message = "Cannot copy an item onto itself"
        fixture.pane.error = message
        let firstNotification = fixture.pane.errorID
        try await fixture.settle()
        try await Task.sleep(for: .seconds(1.5))

        fixture.pane.error = message
        XCTAssertNotEqual(fixture.pane.errorID, firstNotification)
        try await fixture.settle()
        // Cross the first notification's deadline while the repeated error
        // still has more than a second remaining in its own display period.
        try await Task.sleep(for: .seconds(4.9))
        XCTAssertEqual(fixture.pane.error, message)

        let deadline = Date().addingTimeInterval(3)
        while fixture.pane.error != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(fixture.pane.error)
    }

    @MainActor func testToolbarSelfCopyFailureIsShownOnTargetPaneWithoutPersistentStatus() async throws {
        let fixture = try HostedFilePane()
        defer { fixture.close() }
        await fixture.pane.navigate(fixture.root.path)
        await fixture.model.selectLocal(path: fixture.root.path)
        let target = try XCTUnwrap(fixture.model.remote)
        XCTAssertTrue(fixture.model.canTransfer)
        fixture.pane.selected = [fixture.file.path]

        fixture.model.transfer(true)

        XCTAssertEqual(target.error, "Cannot copy an item onto itself")
        XCTAssertNil(fixture.pane.error)
        XCTAssertTrue(fixture.model.status.isEmpty)
        XCTAssertTrue(fixture.model.queue.jobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("kept".utf8))

        target.error = nil
        target.selected = [fixture.file.path]
        fixture.model.transfer(false)

        XCTAssertEqual(fixture.pane.error, "Cannot copy an item onto itself")
        XCTAssertNil(target.error)
        XCTAssertTrue(fixture.model.status.isEmpty)
        XCTAssertTrue(fixture.model.queue.jobs.isEmpty)
    }

    private func assertSameFrame(_ actual: NSRect, _ expected: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }

    @MainActor private final class HostedFilePane {
        let root: URL
        let file: URL
        let store: AppStore
        let model: FileManagerModel
        let pane: FilePane
        let hosting: NSHostingView<AnyView>
        let window: NSWindow

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("fixture.txt")
            try Data("kept".utf8).write(to: file)
            store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
            store.workspace.preferences.language = "zh-CN"
            model = FileManagerModel(session: TerminalSession(host: nil, store: store))
            pane = FilePane(path: root.path, backend: LocalFiles())
            pane.entries = [FileEntry(name: file.lastPathComponent, path: file.path, directory: false)]
            model.local = pane
            hosting = NSHostingView(rootView: AnyView(FilePaneView(pane: pane, model: model, remote: false).environmentObject(store)))
            hosting.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
        }

        func close() {
            model.close()
            window.close()
            try? FileManager.default.removeItem(at: root)
        }

        func settle() async throws {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
        }

        func tableFrame(width: CGFloat) async throws -> NSRect {
            window.setContentSize(NSSize(width: width, height: 420))
            try await settle()
            let scroll = try XCTUnwrap(tables(in: hosting).first)
            let frame = scroll.convert(scroll.bounds, to: hosting)
            XCTAssertEqual(frame.width, width, accuracy: 1)
            XCTAssertGreaterThan(frame.height, 0)
            return frame
        }

        func capture(named name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: destination.appendingPathComponent(name + ".png"))
        }

        func captureTransferQueueIfRequested() async throws {
            guard ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] != nil else { return }
            let queue = TransferQueue()
            let endpoint = LocalFiles()
            for (name, state, direction) in [
                ("archive-backup.zip", "running", "upload"),
                ("quarterly-report.csv", "failed", "copy"),
                ("af-console-metrics.log.2026-07-28", "completed", "download"),
            ] {
                let entry = FileEntry(name: name, path: root.appendingPathComponent(name).path, directory: false)
                let job = TransferJob(entry: entry, destination: "/fixture/" + name, source: endpoint, target: endpoint, direction: direction)
                job.state = state
                job.total = 1_048_576
                job.completed = state == "completed" ? job.total : 350_000
                job.speed = 131_072
                if state == "failed" { job.error = "目标目录没有写入权限，请检查权限后重试。" }
                queue.jobs.append(job)
            }
            hosting.rootView = AnyView(TransferQueueView(queue: queue).environmentObject(store))
            for width in [CGFloat(650), CGFloat(300)] {
                window.setContentSize(NSSize(width: width, height: 400))
                try await settle()
                try capture(named: "transfer-queue-\(Int(width))-states")
            }
        }

        private func tables(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).flatMap { $0.documentView is FileNativeTable ? $0 : nil }.map { [$0] } ?? []
            return own + view.subviews.flatMap { tables(in: $0) }
        }
    }
}
