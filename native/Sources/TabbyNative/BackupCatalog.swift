import Foundation
import SwiftUI

struct BackupCatalogEntry: Identifiable, Equatable {
    var key: String
    var size: UInt64
    var modified: Date
    var id: String { key }
}

enum BackupNaming {
    static func filename(date: Date = Date(), id: UUID = UUID()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Axon-" + formatter.string(from: date) + "-" + id.uuidString.lowercased() + ".axonbackup"
    }
    static func key(from key: String, date: Date = Date(), id: UUID = UUID()) -> String {
        let prefix = key.lastIndex(of: "/").map { String(key[...$0]) } ?? ""
        return prefix + filename(date: date, id: id)
    }
    static func localEntries(_ folder: URL) throws -> [BackupCatalogEntry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]).compactMap { url in
            guard url.pathExtension.lowercased() == "axonbackup" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return BackupCatalogEntry(key: url.lastPathComponent, size: UInt64(max(0, values.fileSize ?? 0)), modified: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified == $1.modified ? $0.key < $1.key : $0.modified > $1.modified }
    }
}

/// Bounded ListObjectsV2 XML; external entities are never resolved.
final class S3BackupListParser: NSObject, XMLParserDelegate {
    var entries: [BackupCatalogEntry] = []
    var nextToken: String?
    var truncated = false
    private var field = "", value = "", key = "", size: UInt64?, date: Date?
    private var inContents = false, rootSeen = false, invalid = false
    static func parse(_ data: Data) throws -> S3BackupListParser {
        guard data.count <= 2 * 1024 * 1024 else { throw S3BackupError.responseTooLarge }
        let result = S3BackupListParser(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), result.rootSeen, !result.invalid, !result.truncated || result.nextToken?.isEmpty == false else { throw S3BackupError.invalidResponse }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        field = elementName; value = ""
        if elementName == "ListBucketResult" { rootSeen = true }
        if elementName == "Contents" { inContents = true; key = ""; size = nil; date = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string; if value.utf8.count > 16384 { invalid = true; parser.abortParsing() } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key" where inContents: key = value.removingPercentEncoding ?? value
        case "Size" where inContents: size = UInt64(text)
        case "LastModified" where inContents:
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        case "Contents":
            guard !key.isEmpty, key.utf8.count <= 1024, let size, let date else { invalid = true; parser.abortParsing(); return }
            if key.lowercased().hasSuffix(".axonbackup") { entries.append(BackupCatalogEntry(key: key, size: size, modified: date)) }
            inContents = false
        case "NextContinuationToken": nextToken = text
        case "IsTruncated": truncated = text == "true"
        default: break
        }
        value = ""
    }
}

struct BackupCatalogView: View {
    @EnvironmentObject var store: AppStore
    let entries: [BackupCatalogEntry]
    let source: String
    let restore: (BackupCatalogEntry) -> Void
    let cancel: () -> Void
    @State private var selected: String?
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text("Choose a backup to restore", "选择要恢复的备份")).font(.title2.bold())
            Text(source).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
            TextField(store.text("Search backup names", "搜索备份名称"), text: $search).appInput()
            List(selection: $selected) {
                ForEach(entries.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) }) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.key).lineLimit(2)
                        Text(entry.modified.formatted(date: .numeric, time: .standard) + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).font(.caption).foregroundStyle(Palette.muted)
                    }.tag(entry.key).padding(.vertical, 4)
                }
            }.frame(minHeight: 280)
            if entries.isEmpty { Text(store.text("No Axon backups found in this location.", "此位置没有 Axon 备份。")) }
            HStack {
                Spacer(); Button(store.text("Cancel", "取消"), action: cancel)
                Button(store.text("Restore selected backup…", "恢复所选备份…")) { if let entry = entries.first(where: { $0.key == selected }) { restore(entry) } }.disabled(selected == nil)
            }.buttonStyle(ChromeButtonStyle())
        }.padding(24).frame(width: 660, height: 460).background(Palette.background).foregroundStyle(Palette.text)
    }
}

extension S3BackupClient {
    func listBackups(prefix: String = "") async throws -> [BackupCatalogEntry] {
        var results: [BackupCatalogEntry] = [], token: String?, seen = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let request = try listRequest(prefix: prefix, token: token)
            let page = try S3BackupListParser.parse(await performList(request))
            results.append(contentsOf: page.entries)
            guard results.count <= 100000 else { throw S3BackupError.responseTooLarge }
            if !page.truncated { return Dictionary(results.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.modified == $1.modified ? $0.key < $1.key : $0.modified > $1.modified } }
            guard let next = page.nextToken, seen.insert(next).inserted else { throw S3BackupError.invalidResponse }; token = next
        }
        throw S3BackupError.responseTooLarge
    }
}
