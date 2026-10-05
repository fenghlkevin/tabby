import XCTest
@testable import TabbyNative

final class DirectoryComparisonTests: XCTestCase {
    @MainActor func testExactComparisonIgnoresTimestampDifferencesAndFindsSameSizeChanges() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("identical.txt", "same", source: true)
        try fixture.write("identical.txt", "same", source: false)
        try fixture.write("changed.txt", "aaaa", source: true)
        try fixture.write("changed.txt", "bbbb", source: false)
        try fixture.write("nested/new.txt", "new", source: true)
        try fixture.write("target-only.txt", "keep", source: false)
        try fixture.write(".git/ignored", "ignored", source: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.target.appendingPathComponent("identical.txt").path)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ".git"))
        XCTAssertEqual(rows.first { $0.id == "identical.txt" }?.difference, .same)
        XCTAssertEqual(rows.first { $0.id == "changed.txt" }?.difference, .changed)
        XCTAssertEqual(rows.first { $0.id == "nested/new.txt" }?.difference, .added)
        XCTAssertEqual(rows.first { $0.id == "target-only.txt" }?.difference, .targetOnly)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix(".git") })
        XCTAssertNotNil(rows.first { $0.id == "changed.txt" }?.targetDigest)
    }

    @MainActor func testApprovedPlanDetectsTargetContentChangeEvenWithUnchangedMetadata() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("file.txt", "new!", source: true)
        try fixture.write("file.txt", "old!", source: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: fixture.target.appendingPathComponent("file.txt").path)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
        let row = try XCTUnwrap(rows.first), source = try XCTUnwrap(row.source), original = try XCTUnwrap(row.target)
        let expectation = DirectoryTransferExpectation(sourceEntry: source, sourceDigest: row.sourceDigest,
                            targetEntry: original, targetDigest: row.targetDigest, targetRoot: fixture.target.path)
        let destination = fixture.target.appendingPathComponent("file.txt")
        try Data("edit".utf8).write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: original.modified], ofItemAtPath: destination.path)
        do {
            try await expectation.validateTarget(destination.path, backend: LocalFiles())
            XCTFail("A target with changed contents must not be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("content changed")) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "edit")
    }

    @MainActor func testFixedPlanDirectoryDoesNotUploadUnapprovedChildren() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("folder/unapproved.txt", "do not upload", source: true)
        let backend = LocalFiles()
        let entry = try await backend.stat(fixture.source.appendingPathComponent("folder").path)
        let destination = fixture.target.appendingPathComponent("folder").path
        let expectation = DirectoryTransferExpectation(sourceEntry: entry, sourceDigest: nil, targetEntry: nil, targetDigest: nil, targetRoot: fixture.target.path)
        let job = TransferJob(entry: entry, destination: destination, source: backend, target: backend, direction: "copy", expectation: expectation)
        try await TransferQueue().transfer(entry, to: destination, job: job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + "/unapproved.txt"))
    }

    @MainActor func testApprovedTransferOverwritesOnceAndPreservesTargetOnlyFiles() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("file.txt", "replacement", source: true)
        try fixture.write("file.txt", "original", source: false)
        try fixture.write("keep.txt", "keep", source: false)
        let model = fixture.model(); defer { model.close() }
        model.start()
        for _ in 0..<500 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.complete, model.error)
        XCTAssertEqual(model.overwriteCount, 1)
        try model.submit()
        await model.queue.runner?.value
        XCTAssertEqual(model.queue.jobs.count, 1)
        XCTAssertEqual(model.queue.jobs.first?.state, "completed", model.queue.jobs.first?.error ?? "")
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("file.txt"), encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
    }

    @MainActor func testListedEmptyAndNestedDirectoriesTransferDespiteStatStorageSize() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fixture.write("nested/file.txt", "approved", source: true)
        let backend = LocalFiles()
        let listed = try await backend.list(fixture.source.path)
        let listedEmpty = try XCTUnwrap(listed.first { $0.name == "empty" })
        let statEmpty = try await backend.stat(listedEmpty.path)
        var directoryWithDifferentStorageSize = listedEmpty
        directoryWithDifferentStorageSize.size = statEmpty.size &+ 1
        XCTAssertTrue(FileContentDigest.sameMetadata(directoryWithDifferentStorageSize, statEmpty))
        let model = fixture.model(); defer { model.close() }
        model.start()
        for _ in 0..<500 where model.scanning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.complete, model.error)
        XCTAssertEqual(model.rows.first { $0.id == "empty" }?.difference, .added)
        XCTAssertEqual(model.rows.first { $0.id == "nested" }?.difference, .added)
        try model.submit()
        await model.queue.runner?.value
        XCTAssertEqual(model.queue.jobs.count, 3)
        XCTAssertTrue(model.queue.jobs.allSatisfy { $0.state == "completed" }, model.queue.jobs.map(\.error).joined(separator: "\n"))
        let empty = try await backend.stat(fixture.target.appendingPathComponent("empty").path)
        XCTAssertTrue(empty.directory)
        let emptyContents = try await backend.list(empty.path)
        XCTAssertTrue(emptyContents.isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.target.appendingPathComponent("nested/file.txt"), encoding: .utf8), "approved")
    }

    @MainActor func testNewTargetAfterPreviewBlocksCreation() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("file.txt", "new", source: true)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
        let row = try XCTUnwrap(rows.first)
        let source = try XCTUnwrap(row.source)
        let expectation = DirectoryTransferExpectation(sourceEntry: source, sourceDigest: row.sourceDigest, targetEntry: nil, targetDigest: nil, targetRoot: fixture.target.path)
        try fixture.write("file.txt", "appeared", source: false)
        do {
            try await expectation.prepare(source: LocalFiles(), target: LocalFiles(), destination: fixture.target.appendingPathComponent("file.txt").path)
            XCTFail("Newly appeared targets require a fresh comparison")
        } catch { XCTAssertTrue(error.localizedDescription.contains("appeared")) }
    }

    func testIgnorePatternsMatchComponentsWithoutShellExecution() {
        let rules = DirectoryIgnoreRules(includeHidden: true, text: ".git, *.tmp, cache/*")
        XCTAssertTrue(rules.excludes("nested/.git/config"))
        XCTAssertTrue(rules.excludes("a/file.tmp"))
        XCTAssertTrue(rules.excludes("cache/file.bin"))
        XCTAssertFalse(rules.excludes("nested/file.txt"))
        XCTAssertTrue(DirectoryIgnoreRules(includeHidden: false, text: "").excludes("nested/.hidden"))
    }
    @MainActor func testConflictingDirectoryBlocksAllItsChildren() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("folder/child.txt", "child", source: true)
        try fixture.write("folder", "target is a file", source: false)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
        XCTAssertEqual(rows.first { $0.id == "folder" }?.difference, .conflict)
        XCTAssertEqual(rows.first { $0.id == "folder/child.txt" }?.difference, .conflict)
        XCTAssertFalse(rows.first { $0.id == "folder/child.txt" }?.difference.transferable == true)
    }
    @MainActor func testSourceAncestorBecomingSymlinkInvalidatesThePlan() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("folder/file.txt", "source", source: true)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
        let row = try XCTUnwrap(rows.first { $0.id == "folder/file.txt" })
        let expectation = DirectoryTransferExpectation(sourceEntry: try XCTUnwrap(row.source), sourceDigest: row.sourceDigest,
                            targetEntry: nil, targetDigest: nil, targetRoot: fixture.target.path, sourceRoot: fixture.source.path)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("folder"), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("folder"), withDestinationURL: outside)
        do {
            try await expectation.prepare(source: LocalFiles(), target: LocalFiles(), destination: fixture.target.appendingPathComponent("folder/file.txt").path)
            XCTFail("Source ancestors must remain ordinary directories")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source directory changed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("folder").path))
    }
    @MainActor func testTargetAncestorBecomingSymlinkInvalidatesCommit() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("folder/file.txt", "new", source: true)
        try fixture.write("folder/file.txt", "old", source: false)
        let model = fixture.model(); defer { model.close() }
        let rows = try await model.compare(rules: DirectoryIgnoreRules(includeHidden: true, text: ""))
        let row = try XCTUnwrap(rows.first { $0.id == "folder/file.txt" })
        let expectation = DirectoryTransferExpectation(sourceEntry: try XCTUnwrap(row.source), sourceDigest: row.sourceDigest,
                            targetEntry: row.target, targetDigest: row.targetDigest, targetRoot: fixture.target.path, sourceRoot: fixture.source.path)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: fixture.target.appendingPathComponent("folder"), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.target.appendingPathComponent("folder"), withDestinationURL: outside)
        do {
            try await expectation.validateTarget(fixture.target.appendingPathComponent("folder/file.txt").path, backend: LocalFiles())
            XCTFail("Target ancestors must remain ordinary directories")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Target directory changed")) }
    }
    @MainActor func testCancelStopsHashingAndNeverPublishesAPartialPlan() async throws {
        let fixture = try ComparisonFixture(); defer { fixture.remove() }
        try fixture.write("file.txt", "contents", source: true)
        let delayed = ComparisonDelayedEndpoint()
        let model = DirectoryComparisonModel(source: FilePane(path: fixture.source.path, backend: delayed),
                    target: FilePane(path: fixture.target.path, backend: LocalFiles()), queue: TransferQueue(), direction: "copy")
        defer { model.close() }
        model.start()
        for _ in 0..<100 {
            if await delayed.readStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let readStarted = await delayed.readStarted
        XCTAssertTrue(readStarted)
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(model.scanning)
        XCTAssertFalse(model.complete)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.queue.jobs.isEmpty)
    }
}

private actor ComparisonDelayedEndpoint: FileEndpoint {
    let base = LocalFiles()
    private(set) var readStarted = false
    func list(_ path: String) async throws -> [FileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> FileEntry { try await base.stat(path) }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func rename(_ from: String, _ to: String) async throws { try await base.rename(from, to) }
    func delete(_ entry: FileEntry) async throws { try await base.delete(entry) }
    func chmod(_ path: String, _ mode: UInt32) async throws { try await base.chmod(path, mode) }
    func read(_ path: String, offset: UInt64, count: Int) async throws -> Data {
        readStarted = true
        try await Task.sleep(for: .seconds(5))
        return try await base.read(path, offset: offset, count: count)
    }
    func write(_ path: String, offset: UInt64, bytes: Data) async throws { try await base.write(path, offset: offset, bytes: bytes) }
}

private struct ComparisonFixture {
    let root: URL
    let source: URL
    let target: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-compare-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
    func write(_ path: String, _ contents: String, source isSource: Bool) throws {
        let url = (isSource ? source : target).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    @MainActor func model() -> DirectoryComparisonModel {
        DirectoryComparisonModel(source: FilePane(path: source.path, backend: LocalFiles()), target: FilePane(path: target.path, backend: LocalFiles()), queue: TransferQueue(), direction: "copy")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
