import Foundation
import Darwin

/// The file browser reads only the directory the person chose. Foundation's
/// per-item resource discovery can inspect protected child folders while merely
/// displaying Home; bulk attributes keep discovery on the open parent directory.
enum LocalFileMetadata {
    static func list(_ path: String) throws -> [FileEntry] {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw failure(errno, path: path) }
        defer { Darwin.close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_ACCESSMASK)
        attributes.fileattr = UInt32(ATTR_FILE_DATALENGTH)
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var entries: [FileEntry] = []
        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(descriptor, &attributes, buffer, bufferSize, 0)
            if count < 0 {
                let code = errno
                if code == ENOTSUP || code == ENOSYS { return try portableList(path) }
                throw failure(code, path: path)
            }
            if count == 0 { return entries }
            entries += try decode(UnsafeRawBufferPointer(start: buffer, count: bufferSize), count: Int(count), parent: path)
        }
    }

    static func stat(_ path: String) throws -> FileEntry {
        var attributes = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0 else { throw failure(errno, path: path) }
        return entry(path, attributes: attributes)
    }

    /// getattrlistbulk packs attributes to four-byte boundaries even on arm64.
    /// Validate lengths and use unaligned loads rather than relying on Swift
    /// struct padding, so a filesystem response cannot read outside its record.
    static func decode(_ buffer: UnsafeRawBufferPointer, count: Int, parent: String) throws -> [FileEntry] {
        guard count >= 0, count <= buffer.count / 24 else { throw invalidResponse(parent) }
        var result: [FileEntry] = []
        var offset = 0
        for _ in 0..<count {
            guard offset <= buffer.count - 4 else { throw invalidResponse(parent) }
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= 24, length <= buffer.count - offset else { throw invalidResponse(parent) }
            let record = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)])
            let returned = record.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            var cursor = 24
            if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
                guard length >= cursor + 4 else { throw invalidResponse(parent) }
                let error = record.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                cursor += 4
                if error != 0 {
                    if error == UInt32(ENOENT) { offset += length; continue } // Removed during enumeration.
                    guard error <= UInt32(Int32.max) else { throw invalidResponse(parent) }
                    throw failure(Int32(error), path: parent)
                }
            }
            let required = UInt32(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_ACCESSMASK)
            guard returned.commonattr & required == required else { throw invalidResponse(parent) }
            let hasFileLength = returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0
            let fixedLength = cursor + 8 + 4 + 16 + 4 + (hasFileLength ? 8 : 0)
            guard length >= fixedLength else { throw invalidResponse(parent) }
            let nameReference = record.loadUnaligned(fromByteOffset: cursor, as: attrreference_t.self)
            let nameStart = cursor + Int(nameReference.attr_dataoffset)
            cursor += 8
            let nameLength = Int(nameReference.attr_length)
            guard nameStart >= fixedLength, nameLength > 0, nameStart <= length - nameLength,
                  record[nameStart + nameLength - 1] == 0 else { throw invalidResponse(parent) }
            let nameBytes = record[nameStart..<(nameStart + nameLength - 1)]
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw invalidResponse(parent) }
            if name == "." || name == ".." { offset += length; continue }
            let type = record.loadUnaligned(fromByteOffset: cursor, as: fsobj_type_t.self)
            cursor += 4
            let modified = record.loadUnaligned(fromByteOffset: cursor, as: timespec.self)
            cursor += 16
            let permissions = record.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
            let size = hasFileLength ? record.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) : 0
            let isDirectory = type == fsobj_type_t(VDIR.rawValue)
            let child = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name, isDirectory: isDirectory).path
            result.append(FileEntry(name: name, path: child, directory: isDirectory, symlink: type == fsobj_type_t(VLNK.rawValue), size: size,
                                    permissions: permissions & 0o7777,
                                    modified: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000)))
            offset += length
        }
        return result
    }

    // Some third-party filesystems do not implement bulk attributes. Their
    // fallback reads directory entries and lstat metadata only; it never opens
    // child directories or resolves a symlink target.
    private static func portableList(_ path: String) throws -> [FileEntry] {
        guard let directory = path.withCString({ Darwin.opendir($0) }) else { throw failure(errno, path: path) }
        defer { Darwin.closedir(directory) }
        var result: [FileEntry] = []
        while true {
            errno = 0
            guard let next = Darwin.readdir(directory) else {
                if errno != 0 { throw failure(errno, path: path) }
                return result
            }
            let name = withUnsafePointer(to: &next.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(next.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let child = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name).path
            do { result.append(try stat(child)) }
            catch {
                if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == Int(ENOENT) { continue }
                throw error
            }
        }
    }

    private static func entry(_ path: String, attributes: Darwin.stat) -> FileEntry {
        let mode = UInt32(attributes.st_mode)
        return FileEntry(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                         directory: mode & UInt32(S_IFMT) == UInt32(S_IFDIR), symlink: mode & UInt32(S_IFMT) == UInt32(S_IFLNK),
                         size: UInt64(max(0, attributes.st_size)), permissions: mode & 0o7777,
                         modified: Date(timeIntervalSince1970: Double(attributes.st_mtimespec.tv_sec) + Double(attributes.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    private static func failure(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
    private static func invalidResponse(_ path: String) -> NSError { failure(EIO, path: path) }
}
