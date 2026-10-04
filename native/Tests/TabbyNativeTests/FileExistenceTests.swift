import Foundation
import Darwin
import XCTest
@testable import TabbyNative

final class FileExistenceTests: XCTestCase {
    func testOnlyExplicitMissingResultsBecomeNil() async throws {
        let path = "/fixture/missing"
        let errors: [Error] = [FileMissing(path),
                               NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                               NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
                               NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)]
        for error in errors {
            let entry = try await fileIfExists(path, backend: ExistenceEndpoint(.failure(error)))
            XCTAssertNil(entry)
        }
        XCTAssertEqual(FileMissing(path).path, path)
        XCTAssertTrue(FileMissing(path).localizedDescription.contains(path))
    }

    func testPermissionAndUnclassifiedFailuresPropagateUnchanged() async throws {
        let failures = [NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                        NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
                        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
                        NSError(domain: "fixture.network", code: -1004),
                        NSError(domain: "fixture.remote", code: Int(ENOENT))]
        for failure in failures {
            do {
                _ = try await fileIfExists("/fixture/protected", backend: ExistenceEndpoint(.failure(failure)))
                XCTFail("Only an explicit missing path may produce nil")
            } catch {
                let propagated = error as NSError
                XCTAssertEqual(propagated.domain, failure.domain)
                XCTAssertEqual(propagated.code, failure.code)
            }
        }
    }

    func testTypedDisconnectedFailureAndExistingEntryRemainDistinct() async throws {
        do {
            _ = try await fileIfExists("/fixture/file", backend: ExistenceEndpoint(.failure(ExistenceFailure.disconnected)))
            XCTFail("A disconnected endpoint cannot report a missing file")
        } catch let failure as ExistenceFailure { XCTAssertEqual(failure, .disconnected) }
        catch { XCTFail("Disconnected error type must be preserved") }
        let original = FileEntry(name: "file", path: "/fixture/file", directory: false, size: 73, permissions: 0o640)
        let found = try await fileIfExists(original.path, backend: ExistenceEndpoint(.success(original)))
        XCTAssertEqual(found, original)
    }

    func testRealLocalMissingAndExistingPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = LocalFiles()
        let missing = try await fileIfExists(root.appendingPathComponent("missing").path, backend: backend)
        XCTAssertNil(missing)
        let file = root.appendingPathComponent("existing")
        try Data("fixture".utf8).write(to: file)
        let existing = try await fileIfExists(file.path, backend: backend)
        XCTAssertEqual(existing?.path, file.path)
        XCTAssertEqual(existing?.size, 7)
    }
}

private enum ExistenceFailure: Error, Equatable { case disconnected, unsupported }

private actor ExistenceEndpoint: FileEndpoint {
    let result: Result<FileEntry, Error>
    init(_ result: Result<FileEntry, Error>) { self.result = result }
    func stat(_ path: String) throws -> FileEntry { try result.get() }
    func list(_ path: String) throws -> [FileEntry] { throw ExistenceFailure.unsupported }
    func mkdir(_ path: String) throws { throw ExistenceFailure.unsupported }
    func rename(_ from: String, _ to: String) throws { throw ExistenceFailure.unsupported }
    func delete(_ entry: FileEntry) throws { throw ExistenceFailure.unsupported }
    func chmod(_ path: String, _ mode: UInt32) throws { throw ExistenceFailure.unsupported }
    func read(_ path: String, offset: UInt64, count: Int) throws -> Data { throw ExistenceFailure.unsupported }
    func write(_ path: String, offset: UInt64, bytes: Data) throws { throw ExistenceFailure.unsupported }
}
