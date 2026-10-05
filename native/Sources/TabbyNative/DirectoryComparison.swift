import Foundation
import CryptoKit
import SwiftUI

enum DirectoryDifference: String {
    case added, changed, same, targetOnly, conflict, unreadable
    var transferable: Bool { self == .added || self == .changed }
    func title(chinese: Bool) -> String {
        switch self {
        case .added: return chinese ? "新增" : "New"
        case .changed: return chinese ? "内容不同" : "Different content"
        case .same: return chinese ? "相同" : "Identical"
        case .targetOnly: return chinese ? "仅目标存在" : "Target only"
        case .conflict: return chinese ? "类型或名称冲突" : "Type or name conflict"
        case .unreadable: return chinese ? "无法读取" : "Unreadable"
        }
    }
}

struct DirectoryComparisonRow: Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let source: FileEntry?
    let target: FileEntry?
    var difference: DirectoryDifference
    var sourceDigest: String?
    var targetDigest: String?
    var detail = ""
}

enum FileContentDigest {
    static func sameMetadata(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        // Directory listings need not report a directory's storage size (the
        // local bulk reader reports zero, while lstat reports st_size). It is
        // not the byte length of a payload approved by the fixed transfer plan.
        lhs.directory == rhs.directory && lhs.symlink == rhs.symlink
            && (lhs.directory || lhs.size == rhs.size) && lhs.modified == rhs.modified
    }

    @MainActor static func sha256(_ entry: FileEntry, backend: any FileEndpoint,
                                check: () throws -> Void = {}, progress: (UInt64) -> Void = { _ in }) async throws -> String {
        guard !entry.directory, !entry.symlink else { throw AppFailure.message("Choose a regular file: \(entry.path)") }
        let before = try await backend.stat(entry.path)
        guard sameMetadata(entry, before) else { throw AppFailure.message("File changed during comparison: \(entry.path)") }
        var digest = SHA256(), offset: UInt64 = 0
        while offset < entry.size {
            try Task.checkCancellation(); try check()
            let requested = Int(min(256 * 1024, entry.size - offset))
            let bytes = try await backend.read(entry.path, offset: offset, count: requested)
            try Task.checkCancellation(); try check()
            guard !bytes.isEmpty, bytes.count <= requested else { throw AppFailure.message("File changed during comparison: \(entry.path)") }
            digest.update(data: bytes); offset += UInt64(bytes.count); progress(UInt64(bytes.count))
        }
        try Task.checkCancellation(); try check()
        let after = try await backend.stat(entry.path)
        guard sameMetadata(before, after) else { throw AppFailure.message("File changed during comparison: \(entry.path)") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The approved plan captures both contents, including the fact that a target
/// did not exist. Ordinary uploads continue to use the existing overwrite UI.
struct DirectoryTransferExpectation {
    let sourceEntry: FileEntry
    let sourceDigest: String?
    let targetEntry: FileEntry?
    let targetDigest: String?
    let targetRoot: String
    var sourceRoot: String? = nil

    @MainActor func prepare(source: any FileEndpoint, target: any FileEndpoint, destination: String,
                            check: () throws -> Void = {}) async throws {
        try check(); try Task.checkCancellation()
        try await validateSourceParents(backend: source, check: check)
        let current = try await source.stat(sourceEntry.path)
        guard FileContentDigest.sameMetadata(sourceEntry, current) else {
            throw AppFailure.message("Source changed. Compare the directories again: \(sourceEntry.path)")
        }
        try await validateTarget(destination, backend: target, check: check)
        let normalizedRoot = (targetRoot as NSString).standardizingPath
        let parent = (destination as NSString).deletingLastPathComponent
        let rootPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        guard parent == normalizedRoot || parent.hasPrefix(rootPrefix) else { throw AppFailure.message("Destination escaped the comparison root") }
        let root = try await target.stat(normalizedRoot)
        guard root.directory, !root.symlink else { throw AppFailure.message("The target root changed. Compare the directories again.") }
        let suffix = parent == normalizedRoot ? "" : String(parent.dropFirst(rootPrefix.count))
        var path = normalizedRoot
        for component in suffix.split(separator: "/") {
            try check(); try Task.checkCancellation()
            path = try remoteJoin(path, String(component))
            if let existing = try await fileIfExists(path, backend: target) {
                guard existing.directory, !existing.symlink else { throw AppFailure.message("Parent is not a regular directory: \(path)") }
            } else { try await target.mkdir(path) }
        }
    }

    @MainActor private func validateSourceParents(backend: any FileEndpoint, check: () throws -> Void) async throws {
        guard let sourceRoot else { return }
        let root = (sourceRoot as NSString).standardizingPath
        let parent = (sourceEntry.path as NSString).deletingLastPathComponent
        let prefix = root == "/" ? "/" : root + "/"
        guard parent == root || parent.hasPrefix(prefix) else { throw AppFailure.message("Source escaped the comparison root") }
        var paths = [root], path = root
        if parent != root {
            for component in String(parent.dropFirst(prefix.count)).split(separator: "/") {
                path = try remoteJoin(path, String(component)); paths.append(path)
            }
        }
        for path in paths {
            try check(); try Task.checkCancellation()
            let directory = try await backend.stat(path)
            guard directory.directory, !directory.symlink else { throw AppFailure.message("Source directory changed. Compare again: \(path)") }
        }
    }

    @MainActor func validateTarget(_ destination: String, backend: any FileEndpoint,
                                   check: () throws -> Void = {}) async throws {
        try check(); try Task.checkCancellation()
        try await validateTargetParents(destination, backend: backend, check: check)
        let current = try await fileIfExists(destination, backend: backend)
        guard let expected = targetEntry else {
            guard current == nil else { throw AppFailure.message("Target appeared after comparison. Compare again: \(destination)") }
            return
        }
        guard let current, FileContentDigest.sameMetadata(expected, current) else {
            throw AppFailure.message("Target changed after comparison. Compare again: \(destination)")
        }
        if let targetDigest {
            let actual = try await FileContentDigest.sha256(current, backend: backend, check: check)
            guard actual == targetDigest else { throw AppFailure.message("Target content changed after comparison. Compare again: \(destination)") }
        }
    }

    @MainActor private func validateTargetParents(_ destination: String, backend: any FileEndpoint, check: () throws -> Void) async throws {
        let root = (targetRoot as NSString).standardizingPath
        let parent = (destination as NSString).deletingLastPathComponent
        let prefix = root == "/" ? "/" : root + "/"
        guard parent == root || parent.hasPrefix(prefix) else { throw AppFailure.message("Destination escaped the comparison root") }
        var paths = [root], path = root
        if parent != root {
            for component in String(parent.dropFirst(prefix.count)).split(separator: "/") {
                path = try remoteJoin(path, String(component)); paths.append(path)
            }
        }
        for path in paths {
            try check(); try Task.checkCancellation()
            guard let directory = try await fileIfExists(path, backend: backend) else {
                if path == root { throw AppFailure.message("The target root changed. Compare again.") }
                break
            }
            guard directory.directory, !directory.symlink else { throw AppFailure.message("Target directory changed. Compare again: \(path)") }
        }
    }

    @MainActor func validateCopiedFile(_ temp: String, source: any FileEndpoint, target: any FileEndpoint,
                                       check: () throws -> Void = {}) async throws {
        try check(); try Task.checkCancellation()
        try await validateSourceParents(backend: source, check: check)
        let current = try await source.stat(sourceEntry.path)
        guard FileContentDigest.sameMetadata(sourceEntry, current) else { throw AppFailure.message("Source changed while copying: \(sourceEntry.path)") }
        if let sourceDigest {
            let copied = try await target.stat(temp)
            let digest = try await FileContentDigest.sha256(copied, backend: target, check: check)
            guard digest == sourceDigest else { throw AppFailure.message("Source content changed while copying. Compare again: \(sourceEntry.path)") }
        }
    }
}

struct DirectoryIgnoreRules {
    var includeHidden: Bool
    var patterns: [String]
    init(includeHidden: Bool, text: String) {
        self.includeHidden = includeHidden
        patterns = text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func excludes(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        if !includeHidden && components.contains(where: { $0.hasPrefix(".") }) { return true }
        return patterns.contains { pattern in
            let trimmed = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidates = trimmed.contains("/") ? [relativePath] : components
            // Wildcards are matched as text; rules never become shell commands.
            let regex = "^" + NSRegularExpression.escapedPattern(for: trimmed)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            return candidates.contains { $0.range(of: regex, options: .regularExpression) != nil }
        }
    }
}

@MainActor final class DirectoryComparisonModel: ObservableObject, Identifiable {
    let id = UUID()
    let sourcePane: FilePane
    let targetPane: FilePane
    let sourceRoot: String
    let targetRoot: String
    let queue: TransferQueue
    let direction: String
    @Published var includeHidden: Bool
    @Published var ignoreText = ".git\n.DS_Store"
    @Published private(set) var rows: [DirectoryComparisonRow] = []
    @Published var selected = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var complete = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var bytesRead: UInt64 = 0
    @Published private(set) var currentPath = ""
    @Published var error = ""
    @Published private(set) var submitted = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    static let maximumEntries = 50_000

    init(source: FilePane, target: FilePane, queue: TransferQueue, direction: String) {
        sourcePane = source; targetPane = target; sourceRoot = source.path; targetRoot = target.path
        self.queue = queue; self.direction = direction; includeHidden = source.showHidden
        source.readerCount += 1; target.readerCount += 1
    }
    var selectedRows: [DirectoryComparisonRow] { rows.filter { selected.contains($0.id) && $0.difference.transferable } }
    var uploadBytes: UInt64 { selectedRows.reduce(0) { $0 + ($1.source?.directory == false ? $1.source?.size ?? 0 : 0) } }
    var overwriteCount: Int { selectedRows.filter { $0.difference == .changed }.count }

    func start() {
        cancel(); generation = UUID(); let token = generation
        rows = []; selected = []; error = ""; scannedCount = 0; bytesRead = 0; complete = false; scanning = true; submitted = false
        let rules = DirectoryIgnoreRules(includeHidden: includeHidden, text: ignoreText)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await compare(rules: rules)
                guard !Task.isCancelled, token == generation else { return }
                rows = result; selected = Set(result.filter { $0.difference.transferable }.map(\.id)); complete = true
            } catch is CancellationError {
            } catch { if token == generation { self.error = error.localizedDescription } }
            if token == generation { scanning = false; task = nil }
        }
    }
    func cancel() { task?.cancel(); task = nil; generation = UUID(); scanning = false }
    func invalidateResults() { complete = false; selected = [] }
    func close() {
        guard !closed else { return }; closed = true; cancel()
        sourcePane.readerCount -= 1; targetPane.readerCount -= 1
    }

    func compare(rules: DirectoryIgnoreRules) async throws -> [DirectoryComparisonRow] {
        let source = try await manifest(root: sourceRoot, backend: sourcePane.backend, rules: rules)
        let target = try await manifest(root: targetRoot, backend: targetPane.backend, rules: rules)
        var conflicts = Set<String>()
        if targetPane.backend is LocalFiles {
            let paths = Set(source.keys).union(target.keys)
            let grouped = Dictionary(grouping: paths) { $0.precomposedStringWithCanonicalMapping.lowercased() }
            for values in grouped.values where values.count > 1 { conflicts.formUnion(values) }
        }
        for path in Set(source.keys).intersection(target.keys) {
            if source[path]?.directory != target[path]?.directory || source[path]?.symlink == true || target[path]?.symlink == true {
                conflicts.insert(path)
            }
        }
        // A conflicting parent makes every descendant unsafe to place, even
        // when those files have distinct leaf names on a case-sensitive source.
        let conflictRoots = conflicts
        for path in Set(source.keys).union(target.keys) {
            var ancestor = (path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty {
                if conflictRoots.contains(ancestor) { conflicts.insert(path); break }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        var result: [DirectoryComparisonRow] = []
        for path in Set(source.keys).union(target.keys).sorted() {
            try Task.checkCancellation(); currentPath = path
            let lhs = source[path], rhs = target[path]
            var row = DirectoryComparisonRow(relativePath: path, source: lhs, target: rhs, difference: .same)
            if conflicts.contains(path) || lhs?.symlink == true || rhs?.symlink == true { row.difference = .conflict }
            else if let lhs, let rhs, lhs.directory != rhs.directory { row.difference = .conflict }
            else if lhs == nil { row.difference = .targetOnly }
            else if lhs?.directory == true { row.difference = rhs == nil ? .added : .same }
            else if let lhs {
                do {
                    row.sourceDigest = try await FileContentDigest.sha256(lhs, backend: sourcePane.backend, progress: { self.bytesRead += $0 })
                    if let rhs {
                        row.targetDigest = try await FileContentDigest.sha256(rhs, backend: targetPane.backend, progress: { self.bytesRead += $0 })
                        row.difference = row.sourceDigest == row.targetDigest ? .same : .changed
                    } else { row.difference = .added }
                } catch is CancellationError { throw CancellationError() }
                catch { row.difference = .unreadable; row.detail = error.localizedDescription }
            }
            result.append(row)
        }
        return result
    }

    private func manifest(root: String, backend: any FileEndpoint, rules: DirectoryIgnoreRules) async throws -> [String: FileEntry] {
        let rootEntry = try await backend.stat(root)
        guard rootEntry.directory, !rootEntry.symlink else { throw AppFailure.message("Choose a regular directory: \(root)") }
        var values: [String: FileEntry] = [:]
        var pending: [(String, String, Int)] = [(root, "", 0)]
        while let (directory, relative, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard depth < 100 else { throw AppFailure.message("The directory tree is too deep. Choose a smaller directory.") }
            currentPath = directory
            let current = try await backend.stat(directory)
            guard current.directory, !current.symlink else { throw AppFailure.message("Directory changed during comparison: \(directory)") }
            for entry in try await backend.list(directory) {
                try Task.checkCancellation()
                let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
                guard !rules.excludes(path) else { continue }
                guard values.count < Self.maximumEntries else { throw AppFailure.message("Comparison is limited to 50,000 entries. Choose a smaller directory.") }
                // Validate the name before retaining an absolute destination plan.
                _ = try remoteJoin(directory, entry.name)
                values[path] = entry; scannedCount += 1
                if entry.directory && !entry.symlink { pending.append((entry.path, path, depth + 1)) }
            }
        }
        return values
    }

    func submit() throws {
        guard complete, !scanning, !submitted, !closed else { throw AppFailure.message("Complete the comparison first") }
        let approved = selectedRows.sorted {
            if $0.source?.directory != $1.source?.directory { return $0.source?.directory == true }
            return $0.relativePath < $1.relativePath
        }
        let plan = try approved.compactMap { row -> (FileEntry, String, DirectoryTransferExpectation)? in
            guard let source = row.source else { return nil }
            var destination = targetRoot
            for component in row.relativePath.split(separator: "/") { destination = try remoteJoin(destination, String(component)) }
            try validateLocalTransfer(source, to: destination, source: sourcePane.backend, target: targetPane.backend)
            return (source, destination, DirectoryTransferExpectation(sourceEntry: source, sourceDigest: row.sourceDigest,
                        targetEntry: row.target, targetDigest: row.targetDigest, targetRoot: targetRoot, sourceRoot: sourceRoot))
        }
        for (entry, destination, expectation) in plan {
            try queue.enqueue(entry, destination: destination, source: sourcePane.backend, target: targetPane.backend, direction: direction, expectation: expectation)
        }
        submitted = true
    }
}

struct DirectoryComparisonSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DirectoryComparisonModel
    @State private var showIdentical = false
    @State private var confirming = false
    var shown: [DirectoryComparisonRow] { model.rows.filter { showIdentical || $0.difference != .same } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("Compare directories", "比较目录")).font(.system(size: 20, weight: .semibold))
            Text(model.sourceRoot + "  →  " + model.targetRoot).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            HStack(alignment: .top) {
                Toggle(store.text("Include hidden files", "包含隐藏文件"), isOn: $model.includeHidden).disabled(model.scanning)
                TextField(store.text("Ignore patterns, separated by commas or lines", "忽略规则，用逗号或换行分隔"), text: $model.ignoreText, axis: .vertical)
                    .appInput().lineLimit(2...3).disabled(model.scanning)
            }
            Text(store.text("Exact comparison reads file contents. Target-only files are kept. Symbolic links are skipped.", "精确比较会读取文件内容。保留仅目标存在的文件，不跟随符号链接。"))
                .font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Button(store.text("Compare", "开始比较")) { model.start() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(model.scanning)
                if model.scanning { Button(store.text("Cancel comparison", "取消比较")) { model.cancel() }.buttonStyle(ChromeButtonStyle()); ProgressView().controlSize(.small) }
                Spacer()
                Toggle(store.text("Show identical", "显示相同项"), isOn: $showIdentical)
                Button(store.text("Select differences", "选择差异")) { model.selected = Set(model.rows.filter { $0.difference.transferable }.map(\.id)) }.disabled(!model.complete)
            }
            if model.scanning {
                Text("\(model.scannedCount) " + store.text("entries", "项") + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: model.bytesRead), countStyle: .file) + " · " + model.currentPath)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(shown) { row in
                        HStack(spacing: 9) {
                            Button { if !model.selected.insert(row.id).inserted { model.selected.remove(row.id) } } label: {
                                Image(systemName: model.selected.contains(row.id) ? "checkmark.square.fill" : "square")
                            }.buttonStyle(.plain).disabled(!row.difference.transferable)
                            Image(systemName: row.source?.directory == true || row.target?.directory == true ? "folder" : "doc")
                            Text(row.relativePath).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(row.difference.title(chinese: store.chinese)).font(.caption)
                                .foregroundStyle(row.difference.transferable ? Palette.blue : Palette.muted)
                        }.padding(8).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 5)).help(row.detail)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.field)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("\(model.selectedRows.count) " + store.text("selected", "项已选") + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: model.uploadBytes), countStyle: .file)).font(.caption)
                Spacer()
                Button(store.text("Close", "关闭")) { model.close(); dismiss() }.buttonStyle(ChromeButtonStyle())
                Button(model.direction == "copy" ? store.text("Copy selected", "复制所选") : store.text("Upload selected", "上传所选")) { confirming = true }
                    .buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!model.complete || model.selectedRows.isEmpty || model.submitted)
            }
        }.padding(22).frame(width: 860, height: 640).foregroundStyle(Palette.text).background(Palette.sidebar)
            .onDisappear { model.close() }
            .onChange(of: model.includeHidden) { _, _ in model.invalidateResults() }
            .onChange(of: model.ignoreText) { _, _ in model.invalidateResults() }
            .appAlert(store.text("Apply this transfer plan?", "执行此传输计划？"), isPresented: $confirming) {
                Button(store.text("Cancel", "取消"), role: .cancel) {}
                Button(store.text("Start transfer", "开始传输")) {
                    do { try model.submit(); model.close(); dismiss() } catch { model.error = error.localizedDescription }
                }
            } message: {
                Text(store.text("Transfer \(model.selectedRows.count) entries and replace \(model.overwriteCount) existing files. Completed files remain if you cancel. Files that change after comparison will fail without being replaced.", "传输 \(model.selectedRows.count) 项，覆盖 \(model.overwriteCount) 个已有文件。取消时保留已完成的文件；比较后发生变化的文件会失败并保留原文件。"))
            }
    }
}
