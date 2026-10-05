import SwiftUI
import AppKit

struct FileEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let entry: FileEntry
    let backend: any FileEndpoint
    let refresh: () async -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error = ""
    var body: some View {
        VStack(spacing: 12) {
            HStack { Label(entry.name, systemImage: "doc.text").font(.headline); Spacer(); Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            TextEditor(text: $text).scrollContentBackground(.hidden).background(Palette.background).font(.system(size: 14, design: .monospaced)).disabled(loading || saving)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if loading || saving { ProgressView().controlSize(.small) }
                Text(store.text("UTF-8 text · 2 MB maximum", "UTF-8 文本 · 最大 2 MB")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.text("Cancel", "取消")) { dismiss() }.disabled(saving)
                Button(store.text("Save", "保存")) { Task { await save() } }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(loading || saving || text == original)
            }
        }.padding(20).background(Palette.sidebar).foregroundStyle(Palette.text).frame(width: 820, height: 600).task { await load() }
    }
    func load() async {
        defer { loading = false }
        do {
            guard !entry.directory, !entry.symlink, entry.size <= 2 * 1024 * 1024 else { throw AppFailure.message(store.text("Choose a UTF-8 text file smaller than 2 MB", "请选择小于 2 MB 的 UTF-8 文本文件")) }
            var data = Data(); var offset: UInt64 = 0
            while offset < entry.size {
                let bytes = try await backend.read(entry.path, offset: offset, count: 256 * 1024)
                guard !bytes.isEmpty else { throw AppFailure.message("File changed while reading") }
                data.append(bytes); offset += UInt64(bytes.count)
                guard data.count <= 2 * 1024 * 1024 else { throw AppFailure.message("File too large") }
            }
            guard let content = String(data: data, encoding: .utf8), !content.contains("\0") else { throw AppFailure.message(store.text("Binary files cannot be edited", "无法编辑二进制文件")) }
            text = content; original = content
        } catch { self.error = error.localizedDescription }
    }
    func save() async {
        saving = true; defer { saving = false }
        let temp = entry.path + ".tabby-" + UUID().uuidString
        let backup = entry.path + ".backup-" + UUID().uuidString
        do {
            let current = try await backend.stat(entry.path)
            guard !current.symlink, !current.directory, current.size == entry.size, abs(current.modified.timeIntervalSince(entry.modified)) < 1 else { throw AppFailure.message(store.text("File changed. Reopen it before saving.", "文件已改变，请重新打开后保存。")) }
            let data = Data(text.utf8)
            guard data.count <= 2 * 1024 * 1024 else { throw AppFailure.message("File too large") }
            if data.isEmpty { try await backend.write(temp, offset: 0, bytes: data) }
            var offset = 0
            while offset < data.count {
                let end = min(offset + 256 * 1024, data.count)
                try await backend.write(temp, offset: UInt64(offset), bytes: data.subdata(in: offset..<end)); offset = end
            }
            try await backend.chmod(temp, entry.permissions & 0o777)
            try await backend.rename(entry.path, backup)
            do { try await backend.rename(temp, entry.path) }
            catch { try? await backend.rename(backup, entry.path); throw error }
            // Keep the backup beside the edited file so changes can be recovered.
            await refresh(); dismiss()
        } catch {
            if let partial = try? await backend.stat(temp) { try? await backend.removeStagingFile(partial) }
            self.error = error.localizedDescription
        }
    }
}
