import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

final class LogViewerTests: XCTestCase {
    @MainActor func testLogWorkspaceRendersWideLinesFromTopLeft() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data("2026-06-12 17:06:24 INFO /file/download|1|0|1|0|27|0|0|1\nERROR failed: 中文日志\n".utf8).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce(); model.search = "failed"
        let store = AppStore(fileURL: fixture.root.appendingPathComponent("workspace.json"))
        let view = NSHostingView(rootView: LogViewerWorkspace(model: model).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.width, 1100, accuracy: 1)
        XCTAssertEqual(model.visibleLines.count, 2)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/axon-0.8.4-log-layout.png"))
        }
    }

    @MainActor func testInitialTailAndIncrementalUTF8AcrossReads() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data((0..<300).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce()
        XCTAssertEqual(model.lines.count, 200)
        XCTAssertEqual(model.lines.first?.text, "line 100")
        let chinese = Data("中文\nerror: broken\n".utf8)
        try fixture.append(Data(chinese.prefix(2)))
        await model.pollOnce()
        try fixture.append(Data(chinese.dropFirst(2)))
        await model.pollOnce()
        XCTAssertEqual(model.lines.suffix(2).map(\.text), ["中文", "error: broken"])
        XCTAssertTrue(model.lines.last?.isError == true)
        model.filter = "中文"
        XCTAssertEqual(model.visibleLines.map(\.text), ["中文"])
        model.search = "中文"
        XCTAssertEqual(model.searchMatches.count, 1)
        XCTAssertTrue(model.exportedText.contains("error: broken"))
    }

    @MainActor func testTruncationAndMissingFileKeepLoadedContent() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data("original log\n".utf8).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce()
        try FileManager.default.removeItem(at: fixture.file)
        await model.pollOnce()
        XCTAssertEqual(model.status, "missing")
        XCTAssertEqual(model.lines.first?.text, "original log")
        try Data("new\n".utf8).write(to: fixture.file)
        await model.pollOnce()
        XCTAssertEqual(model.status, "rotated")
        XCTAssertTrue(model.lines.contains { $0.text.contains("truncated or replaced") })
        XCTAssertEqual(model.lines.last?.text, "new")
    }

    @MainActor func testSameSizeReplacementIsDetectedFromReadBoundary() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data("first\n".utf8).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce()
        try Data("other\n".utf8).write(to: fixture.file, options: .atomic)
        await model.pollOnce()
        XCTAssertEqual(model.status, "rotated")
        XCTAssertEqual(model.lines.last?.text, "other")
    }

    @MainActor func testBufferBoundsAndReaderLease() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data().write(to: fixture.file)
        let model = try await fixture.model()
        XCTAssertEqual(model.pane.readerCount, 1)
        await model.pollOnce()
        let line = String(repeating: "x", count: 1000) + "\n"
        try fixture.append(Data(String(repeating: line, count: 4000).utf8))
        for _ in 0..<5 { await model.pollOnce() }
        XCTAssertLessThanOrEqual(model.lines.count, LogViewerModel.maximumLines)
        XCTAssertLessThanOrEqual(model.lines.reduce(0) { $0 + $1.text.utf8.count }, LogViewerModel.maximumBufferedBytes)
        XCTAssertGreaterThan(model.droppedLines, 0)
        model.close(); model.close()
        XCTAssertEqual(model.pane.readerCount, 0)
    }

    @MainActor func testBinaryInputReportsError() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data([0, 1, 2, 3]).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce()
        XCTAssertEqual(model.status, "error")
        XCTAssertTrue(model.error.contains("Binary"))
        XCTAssertTrue(model.lines.isEmpty)
    }
    @MainActor func testLongChineseLineRemainsValidWhenNewlineArrives() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data(String(repeating: "中文", count: 30_000).utf8).write(to: fixture.file)
        let model = try await fixture.model(); defer { model.close() }
        await model.pollOnce()
        try fixture.append(Data("末尾\n".utf8))
        await model.pollOnce()
        XCTAssertTrue(model.error.isEmpty, model.error)
        XCTAssertTrue(model.lines.last?.text.hasSuffix("末尾") == true)
        try fixture.append(Data(String(repeating: "中文", count: 30_000).utf8))
        await model.pollOnce()
        try fixture.append(Data("又一行\n".utf8))
        await model.pollOnce()
        XCTAssertTrue(model.error.isEmpty, model.error)
        XCTAssertTrue(model.lines.last?.text.hasSuffix("又一行") == true)
    }
    @MainActor func testLatestWhileCancelledReadSettlesStillLoadsInPausedMode() async throws {
        let fixture = try LogFixture(); defer { fixture.remove() }
        try Data("latest line\n".utf8).write(to: fixture.file)
        let backend = LogDelayedEndpoint()
        let entry = try await backend.stat(fixture.file.path)
        let model = LogViewerModel(pane: FilePane(path: fixture.root.path, backend: backend), entry: entry, title: "log")
        defer { model.close() }
        model.activate()
        for _ in 0..<100 {
            if await backend.readStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.setFollowing(false)
        model.jumpToLatest()
        for _ in 0..<100 where model.lines.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.following)
        XCTAssertEqual(model.lines.last?.text, "latest line")
        XCTAssertEqual(model.status, "paused")
    }
}

private actor LogDelayedEndpoint: FileEndpoint {
    let base = LocalFiles()
    private(set) var readStarted = false
    func list(_ path: String) async throws -> [FileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> FileEntry { try await base.stat(path) }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { try await base.rename(from, to) }
    func delete(_ entry: FileEntry) async throws { try await base.delete(entry) }
    func chmod(_ path: String, _ mode: UInt32) async throws { try await base.chmod(path, mode) }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data {
        if !readStarted {
            readStarted = true
            try await Task.sleep(for: .seconds(5))
        }
        return try await base.read(path, offset: offset, count: count)
    }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws { try await base.write(path, offset: offset, bytes: bytes) }
}

private struct LogFixture {
    let root: URL
    var file: URL { root.appendingPathComponent("server.log") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-log-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    @MainActor func model() async throws -> LogViewerModel {
        let backend = LocalFiles(), entry = try await backend.stat(file.path)
        return LogViewerModel(pane: FilePane(path: root.path, backend: backend), entry: entry, title: "server.log")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
