import Foundation
import Darwin

/// An endpoint has positively identified a missing path.
struct FileMissing: Error, LocalizedError, Sendable {
    let path: String
    init(_ path: String) { self.path = path }
    var errorDescription: String? { "File not found: \(path)" }
}

/// Permission, connection, and unclassified stat errors must never authorize an overwrite.
func fileIfExists(_ path: String, backend: any FileEndpoint) async throws -> FileEntry? {
    do { return try await backend.stat(path) }
    catch is FileMissing { return nil }
    catch {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain,
           failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError { return nil }
        if failure.domain == NSPOSIXErrorDomain, failure.code == Int(ENOENT) { return nil }
        throw error
    }
}
