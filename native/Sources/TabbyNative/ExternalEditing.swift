import Foundation
import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// The editor only sees a local working copy. SSH credentials remain in Axon.
@MainActor final class ExternalEdit: ObservableObject, Identifiable {
    let id = UUID()
    var backend: any FileEndpoint
    var sourceHost: Host?
    var sourceUsername: String?
    let remotePath: String
    let localURL: URL
    @Published var state = "editing"
    @Published var error = ""
    @Published var changed = false
    @Published var preview = ""
    @Published var comparison: EditComparison?
    private var original: Data
    private var metadata: FileEntry
    weak var leasePane: FilePane?
    var editorURL: URL?
    private var timer: Timer?
    private var uploading = false
    static let maximumBytes = 32 * 1024 * 1024

    init(backend: any FileEndpoint, entry: FileEntry, localURL: URL, original: Data) {
        self.backend = backend; remotePath = entry.path; metadata = entry
        self.localURL = localURL; self.original = original
    }
    static func read(_ entry: FileEntry, from backend: any FileEndpoint) async throws -> Data {
        guard !entry.directory, !entry.symlink, entry.size <= maximumBytes else { throw AppFailure.message("Choose a regular text file up to 32 MB / 请选择不超过 32 MB 的普通文本文件") }
        var result = Data()
        while UInt64(result.count) < entry.size {
            try Task.checkCancellation()
            let bytes = try await backend.read(entry.path, offset: UInt64(result.count), count: min(256 * 1024, Int(entry.size) - result.count))
            guard !bytes.isEmpty, result.count + bytes.count <= maximumBytes else { throw AppFailure.message("File changed while reading / 读取时文件已改变") }
            result.append(bytes)
        }
        let after = try await backend.stat(entry.path)
        guard FileContentDigest.sameMetadata(entry, after) else { throw AppFailure.message("File changed while reading / 读取时文件已改变") }
        return result
    }
    static func prepare(entry: FileEntry, backend: any FileEndpoint, directory: URL? = nil) async throws -> ExternalEdit {
        let data = try await read(entry, from: backend)
        guard !data.contains(0) else { throw AppFailure.message("Binary files cannot be edited / 无法编辑二进制文件") }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TabbyNative/ExternalEdits/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = URL(fileURLWithPath: entry.path).lastPathComponent
        guard name != ".", name != "..", !name.isEmpty else { throw AppFailure.message("Invalid file name") }
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ExternalEdit(backend: backend, entry: entry, localURL: url, original: data)
    }
    func open() throws {
        error = ""
        if let app = editorURL {
            NSWorkspace.shared.open([localURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(localURL) {
            throw AppFailure.message("Choose an editor to open this file / 请为此文件选择编辑器")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkChanges() } }
    }
    func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.prompt = "选择编辑器 / Choose editor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editorURL = url
        do { try open() } catch { self.error = error.localizedDescription }
    }
    func checkChanges() {
        guard !uploading else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maximumBytes else { throw AppFailure.message("Edited file exceeds 32 MB / 编辑文件超过 32 MB") }
            let current = try Data(contentsOf: localURL)
            comparison = nil
            changed = current != original
            if changed {
                state = "changed"
                if let old = String(data: original, encoding: .utf8), let new = String(data: current, encoding: .utf8) {
                    preview = EditDifferencePreview.make(old: old, new: new)
                    comparison = EditComparison.make(old: old, new: new)
                } else { preview = "Encoding or binary content changed. Review in your editor. / 编码或内容已改变，请在编辑器中比较。" }
            } else { state = "editing"; preview = "" }
        } catch { self.error = error.localizedDescription }
    }
    func upload() async throws {
        guard !uploading else { return }
        checkChanges(); guard changed else { return }
        uploading = true; state = "uploading"; defer { uploading = false }
        let temp = remotePath + ".tabby-" + UUID().uuidString
        let backup = remotePath + ".backup-" + UUID().uuidString
        var backedUp = false
        do {
            let bytes = try Data(contentsOf: localURL)
            guard bytes.count <= Self.maximumBytes, !bytes.contains(0) else { throw AppFailure.message("Choose a text file up to 32 MB") }
            let current = try await backend.stat(remotePath)
            guard !current.symlink, FileContentDigest.sameMetadata(metadata, current), try await Self.read(current, from: backend) == original else {
                throw AppFailure.message("Remote file changed. Keep your local copy and reopen the remote file to compare. / 远端文件已改变；保留本地修改，重新打开远端文件进行比较。")
            }
            var offset = 0
            if bytes.isEmpty { try await backend.write(temp, offset: 0, bytes: Data()) }
            while offset < bytes.count {
                try Task.checkCancellation()
                let end = min(offset + 256 * 1024, bytes.count)
                try await backend.write(temp, offset: UInt64(offset), bytes: bytes.subdata(in: offset..<end)); offset = end
            }
            try await backend.chmod(temp, metadata.permissions & 0o777)
            let final = try await backend.stat(remotePath)
            guard FileContentDigest.sameMetadata(current, final), try await Self.read(final, from: backend) == original else { throw AppFailure.message("Remote file changed before upload committed / 提交前远端文件已改变") }
            try await backend.rename(remotePath, backup); backedUp = true
            do { try await backend.rename(temp, remotePath) }
            catch { try? await backend.rename(backup, remotePath); throw error }
            metadata = try await backend.stat(remotePath); original = bytes; changed = false; preview = ""; error = ""; state = "saved"
        } catch {
            if let partial = try? await backend.stat(temp) { try? await backend.removeStagingFile(partial) }
            self.error = error.localizedDescription + (backedUp ? "\nBackup: " + backup : "")
            state = "failed"; throw error
        }
    }
    func stop() { timer?.invalidate(); timer = nil; leasePane?.readerCount -= 1; leasePane = nil }
    deinit { timer?.invalidate() }
}

@MainActor final class ExternalEditCenter: ObservableObject {
    @Published var edits: [ExternalEdit] = []
    func open(entry: FileEntry, pane: FilePane, host: Host? = nil, username: String? = nil) async throws {
        pane.readerCount += 1
        let edit: ExternalEdit
        do { edit = try await ExternalEdit.prepare(entry: entry, backend: pane.backend) }
        catch { pane.readerCount -= 1; throw error }
        edit.sourceHost = host; edit.sourceUsername = username
        edit.leasePane = pane
        edits.append(edit)
        do { try edit.open() } catch { edit.error = error.localizedDescription; throw error }
    }
    func rebind(_ old: any FileEndpoint, to pane: FilePane) {
        for edit in edits where edit.state != "uploading" && (edit.backend as AnyObject) === (old as AnyObject) {
            edit.leasePane?.readerCount -= 1; pane.readerCount += 1; edit.leasePane = pane; edit.backend = pane.backend
        }
    }
    func remove(_ edit: ExternalEdit) { edit.stop(); edits.removeAll { $0.id == edit.id } }
}

struct ExternalEditsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: ExternalEditCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeading(title: store.text("External editing", "外部编辑任务"), subtitle: store.text("Save in your editor, review changes, then upload. Working copies are kept locally.", "在外部编辑器保存后，检查更改并回传；本地工作副本始终保留。"))
                .padding(24)
            if center.edits.isEmpty {
                VStack(spacing: 14) {
                    IconTile(symbol: "square.and.pencil", color: Palette.accent, size: 48)
                    Text(store.text("No tracked files", "暂无跟踪文件")).font(.system(size: 16, weight: .semibold))
                    Text(store.text("In SFTP, right-click a text file and choose Edit externally.", "在 SFTP 中右键点击文本文件，选择“使用外部编辑器”。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(center.edits) { edit in ExternalEditRow(edit: edit, remove: { center.remove(edit) }) }
                    }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.background).foregroundStyle(Palette.text)
    }

}
struct ExternalEditRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var edit: ExternalEdit
    let remove: () -> Void
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((edit.remotePath as NSString).lastPathComponent).font(.headline).textSelection(.enabled)
            if let host = edit.sourceHost {
                Label(host.name.isEmpty ? host.address : host.name, systemImage: "server.rack").font(.system(size: 13, weight: .medium))
                Text((edit.sourceUsername ?? host.username) + "@" + host.address + ":" + String(host.port)).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
            } else {
                Label(edit.backend is LocalFiles ? store.text("Local files", "本地文件") : store.text("Source host unavailable", "来源主机信息不可用"), systemImage: "desktopcomputer")
            }
            Text(store.text("Source path: ", "原始路径：") + edit.remotePath).font(.system(size: 12)).textSelection(.enabled)
            DisclosureGroup(store.text("Local working copy", "本地工作副本")) {
                Text(edit.localURL.path).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            Text(store.text(edit.state, ["editing": "编辑中", "changed": "有修改", "uploading": "回传中", "saved": "已回传", "failed": "失败"][edit.state] ?? edit.state)).foregroundStyle(Palette.muted)
            if !edit.error.isEmpty { Text(edit.error).foregroundStyle(.red) }
            HStack {
                Button(store.text("Open editor", "打开编辑器")) { do { try edit.open() } catch { edit.error = error.localizedDescription } }
                Button(store.text("Choose editor…", "选择编辑器…"), action: edit.chooseEditor)
                Button(store.text("Check changes", "检查更改"), action: edit.checkChanges)
                Button(store.text("Upload changes", "回传修改")) { confirming = true }.disabled(!edit.changed || edit.state == "uploading")
                Button(store.text("Stop tracking", "停止跟踪"), action: remove).disabled(edit.state == "uploading")
            }.buttonStyle(ChromeButtonStyle())
            if edit.changed {
                if let comparison = edit.comparison { EditComparisonView(comparison: comparison) }
                else { Text(edit.preview).font(.caption).foregroundStyle(Palette.muted) }
            }
        }.padding(16).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
        .appAlert(store.text("Upload edited file?", "回传修改后的文件？"), isPresented: $confirming) {
            AppAlertButton(store.text("Upload", "回传")) { Task { try? await edit.upload() } }
            AppAlertButton(store.text("Cancel", "取消"), role: .cancel) {}
        } message: { Text(edit.remotePath + "\n" + store.text("Checks the original contents and keeps a remote backup.", "检查原始内容，并保留远端备份。")) }
    }
}

enum EditDifferencePreview {
    static func make(old: String, new: String) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let removed = a[start..<endA], added = b[start..<endB]
        let summary = "@@ line \(start + 1) · −\(removed.count) / +\(added.count) @@\n"
        let preview = summary + removed.prefix(150).map { "− " + $0 }.joined(separator: "\n") + "\n" + added.prefix(150).map { "+ " + $0 }.joined(separator: "\n")
        return String(preview.prefix(32000)) + (removed.count > 150 || added.count > 150 || preview.count > 32000 ? "\n… Preview truncated / 预览已截断" : "")
    }
}


struct EditComparison {
    struct Row: Identifiable {
        let id: Int
        let oldNumber: Int?
        let newNumber: Int?
        let oldText: String?
        let newText: String?
        let changed: Bool
    }
    let rows: [Row]
    let truncated: Bool
    static func make(old: String, new: String) -> EditComparison {
        // Bound preview work independently of the upload's full byte comparison.
        let a = Array(old.prefix(64000).components(separatedBy: "\n").prefix(1000))
        let b = Array(new.prefix(64000).components(separatedBy: "\n").prefix(1000))
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if removed.contains(i) || inserted.contains(j) {
                var left: [Int] = [], right: [Int] = []
                while i < a.count && removed.contains(i) { left.append(i); i += 1 }
                while j < b.count && inserted.contains(j) { right.append(j); j += 1 }
                for k in 0..<max(left.count, right.count) {
                    let l = k < left.count ? left[k] : nil, r = k < right.count ? right[k] : nil
                    rows.append(Row(id: rows.count, oldNumber: l.map { $0 + 1 }, newNumber: r.map { $0 + 1 }, oldText: l.map { a[$0] }, newText: r.map { b[$0] }, changed: true))
                }
            } else {
                rows.append(Row(id: rows.count, oldNumber: i < a.count ? i + 1 : nil, newNumber: j < b.count ? j + 1 : nil, oldText: i < a.count ? a[i] : nil, newText: j < b.count ? b[j] : nil, changed: false))
                i += 1; j += 1
            }
        }
        return EditComparison(rows: rows, truncated: old.count > 64000 || new.count > 64000 || old.components(separatedBy: "\n").count > 1000 || new.components(separatedBy: "\n").count > 1000)
    }
}

struct EditComparisonView: View {
    @EnvironmentObject var store: AppStore
    let comparison: EditComparison
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(store.text("Before editing", "编辑前 · 原始文件"), systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
                Label(store.text("After editing", "编辑后 · 本地修改"), systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12, weight: .semibold)).padding(12).background(Palette.field)
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(comparison.rows) { row in
                            HStack(spacing: 0) {
                                cell(number: row.oldNumber, text: row.oldText, changed: row.changed, color: Palette.danger, width: max(geometry.size.width / 2, contentWidth))
                                cell(number: row.newNumber, text: row.newText, changed: row.changed, color: Color(hex: Palette.terminalForeground), width: max(geometry.size.width / 2, contentWidth))
                            }
                        }
                    }.frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
            }.frame(height: 260)
            if comparison.truncated { Text(store.text("Preview limited to the first 1,000 lines / 64,000 characters. Review the full file in your editor.", "预览最多显示前 1,000 行 / 64,000 字符，完整文件可在编辑器查看。" )).font(.caption).foregroundStyle(Palette.muted).padding(8) }
        }.background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
    }
    private var contentWidth: CGFloat { CGFloat(comparison.rows.map { max($0.oldText?.count ?? 0, $0.newText?.count ?? 0) }.max() ?? 0) * 8 + 64 }
    private func cell(number: Int?, text: String?, changed: Bool, color: Color, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number.map(String.init) ?? "").foregroundStyle(Palette.muted).frame(width: 38, alignment: .trailing)
            Text(text ?? " ").textSelection(.enabled).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 4).padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: width)
            .background(changed ? color.opacity(text == nil ? 0.04 : 0.13) : Palette.card)
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1) }
    }
}


struct ExternalEditSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var center: ExternalEditCenter
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(store.text("Done", "完成"), action: dismiss)
                    .buttonStyle(ChromeButtonStyle(prominent: true))
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.top, 20)
            ExternalEditsView(center: center)
        }.frame(width: 850, height: 620).background(Palette.background)
    }
}
