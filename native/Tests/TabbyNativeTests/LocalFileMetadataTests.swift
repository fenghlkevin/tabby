import Foundation
import Darwin
import XCTest
@testable import TabbyNative

final class LocalFileMetadataTests: XCTestCase {
    /// Listing a parent must not enter child directories, including names used
    /// by macOS protected folders. The fixture does not change real TCC grants.
    func testParentListingKeepsUnreadableChildrenWithoutEnteringThem() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Desktop", "Documents", "Downloads", "private folder"]
        for name in names {
            let child = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try Data("do not enumerate me".utf8).write(to: child.appendingPathComponent("hidden-in-child.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: child.path)
        }
        defer {
            for name in names { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(name).path) }
        }
        let listing = try await LocalFiles().list(root.path)
        XCTAssertEqual(Set(listing.map(\.name)), Set(names))
        XCTAssertTrue(listing.allSatisfy { $0.directory && !$0.symlink && $0.permissions == 0 })
        XCTAssertTrue(listing.allSatisfy { $0.path == root.appendingPathComponent($0.name).path })
        XCTAssertFalse(listing.contains { $0.name == "hidden-in-child.txt" })
    }

    func testListingAndStatNeverFollowSymbolicLinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let directoryLink = root.appendingPathComponent("directory link")
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: directory.path)
        let missingLink = root.appendingPathComponent("broken link")
        let missingTarget = root.appendingPathComponent("missing target").path
        try FileManager.default.createSymbolicLink(atPath: missingLink.path, withDestinationPath: missingTarget)
        let local = LocalFiles()
        let listing = try await local.list(root.path)
        for link in [directoryLink, missingLink] {
            let listed = try XCTUnwrap(listing.first { $0.path == link.path })
            let stated = try await local.stat(link.path)
            XCTAssertTrue(listed.symlink)
            XCTAssertFalse(listed.directory)
            XCTAssertEqual(listed.size, stated.size)
            XCTAssertEqual(listed.permissions, stated.permissions)
            XCTAssertEqual(listed.modified.timeIntervalSince1970, stated.modified.timeIntervalSince1970, accuracy: 0.001)
            let existingLink = try await fileIfExists(link.path, backend: local)
            XCTAssertNotNil(existingLink, "A broken link exists even though its target does not")
        }
        XCTAssertEqual(listing.first { $0.path == missingLink.path }?.size, UInt64(missingTarget.utf8.count))
    }

    func testMultipleBulkBatchesRetainUnicodeNamesSizesPermissionsAndDates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedDate = Date(timeIntervalSince1970: 1_720_000_000.125)
        let count = 800 // Long names exceed one 64 KiB metadata buffer.
        for index in 0..<count {
            let name = "文件 \(index) " + String(repeating: "z", count: 90) + ".txt"
            let child = root.appendingPathComponent(name)
            try Data(repeating: UInt8(index % 255), count: index % 31).write(to: child)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: expectedDate], ofItemAtPath: child.path)
        }
        let listing = try await LocalFiles().list(root.path)
        XCTAssertEqual(listing.count, count)
        XCTAssertEqual(Set(listing.map(\.path)).count, count)
        for entry in listing {
            let index = try XCTUnwrap(Int(entry.name.split(separator: " ")[1]))
            XCTAssertFalse(entry.directory || entry.symlink)
            XCTAssertEqual(entry.size, UInt64(index % 31))
            XCTAssertEqual(entry.permissions, 0o640)
            XCTAssertEqual(entry.modified.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testMissingAndNonDirectoryListingFailuresRemainErrors() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ordinary file")
        try Data().write(to: file)
        let local = LocalFiles()
        for (path, code) in [(root.appendingPathComponent("missing").path, ENOENT), (file.path, ENOTDIR)] {
            do { _ = try await local.list(path); XCTFail("A failed directory open cannot return an empty successful listing") }
            catch {
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(code))
            }
        }
    }

    func testInvalidPackedResponsesFailWithoutReadingOutsideTheRecord() throws {
        let malformed = [Data(), Data(repeating: 0, count: 3), Data(repeating: 0, count: 80)]
        for buffer in malformed {
            try buffer.withUnsafeBytes { bytes in
                XCTAssertThrowsError(try LocalFileMetadata.decode(bytes, count: 1, parent: "/fixture")) {
                    XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
                    XCTAssertEqual(($0 as NSError).code, Int(EIO))
                }
            }
        }
        try Data(repeating: 0, count: 80).withUnsafeBytes { bytes in
            XCTAssertThrowsError(try LocalFileMetadata.decode(bytes, count: -1, parent: "/fixture"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-local-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
