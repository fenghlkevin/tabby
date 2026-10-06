import SwiftUI

enum CatalogManagementSection: String, CaseIterable, Identifiable {
    case groups, tags
    var id: String { rawValue }
}

enum CatalogNames {
    static func unique(_ values: [String]) -> [String] {
        var names: [String] = []
        for value in values {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !contains(names, name) { names.append(name) }
        }
        return names
    }
    static func matches(_ first: String, _ second: String) -> Bool { first.caseInsensitiveCompare(second) == .orderedSame }
    static func contains(_ names: [String], _ value: String) -> Bool { names.contains { matches($0, value) } }
    static func valid(_ value: String) -> Bool { !value.isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil }
}

extension AppStore {
    var tags: [String] {
        TagTokens.unique(workspace.tags + workspace.hosts.flatMap { TagTokens.parse($0.tags) })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// Catalog changes touch no secrets. Roll back all host and catalog metadata on failed persistence.
    func commitCatalog(_ updated: Workspace) throws {
        let previous = workspace
        workspace = updated
        guard save() else {
            workspace = previous
            throw AppFailure.message(error ?? text("Could not save workspace", "无法保存配置"))
        }
    }
    private func validatedTag(_ raw: String, excluding old: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CatalogNames.valid(name), TagTokens.parse(name) == [name] else {
            throw AppFailure.message(text("Enter one tag without spaces or commas", "请输入一个不含空格或逗号的标签"))
        }
        guard !tags.contains(where: { CatalogNames.matches($0, name) && (old == nil || !CatalogNames.matches($0, old!)) }) else {
            throw AppFailure.message(text("This tag already exists", "标签已存在"))
        }
        return name
    }
    func createTag(_ raw: String) throws {
        let name = try validatedTag(raw)
        var updated = workspace
        updated.tags = TagTokens.unique(updated.tags + [name])
        try commitCatalog(updated)
    }
    func renameTag(_ old: String, to raw: String) throws {
        guard CatalogNames.contains(tags, old) else { throw AppFailure.message(text("Tag no longer exists", "标签已不存在")) }
        let name = try validatedTag(raw, excluding: old)
        var updated = workspace
        updated.tags = TagTokens.unique(tags.map { CatalogNames.matches($0, old) ? name : $0 })
        for index in updated.hosts.indices {
            updated.hosts[index].tags = TagTokens.serialized(TagTokens.parse(updated.hosts[index].tags).map {
                CatalogNames.matches($0, old) ? name : $0
            })
        }
        try commitCatalog(updated)
    }
    func deleteTag(_ name: String) throws {
        var updated = workspace
        updated.tags = tags.filter { !CatalogNames.matches($0, name) }
        for index in updated.hosts.indices { updated.hosts[index].tags = TagTokens.removing(name, from: updated.hosts[index].tags) }
        try commitCatalog(updated)
    }
    func catalogHostCount(_ name: String, section: CatalogManagementSection) -> Int {
        workspace.hosts.filter { host in
            section == .groups ? CatalogNames.matches(host.group, name) : CatalogNames.contains(TagTokens.parse(host.tags), name)
        }.count
    }
}

struct TagsManagementView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var editingName: String?
    @State private var renameDraft = ""
    @State private var deletionName: String?
    @State private var error = ""
    @FocusState private var nameFocused: Bool
    private var entries: [String] { store.tags }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "tag.fill", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.text("Manage tags", "管理标签")).font(.system(size: 17, weight: .semibold))
                    Text(store.text("Labels for finding and filtering hosts", "用于搜索和筛选主机的标签")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).focusEffectDisabled()
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(store.text("Close management", "关闭管理"))
            }.padding(20)
            Divider().overlay(Palette.border)
            VStack(alignment: .leading, spacing: 14) {
                Text(store.text("Renaming or deleting a tag updates every host using it.", "重命名或删除标签会同步更新所有使用它的主机。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                HStack(spacing: 10) {
                    TextField(store.text("New tag name", "新标签名称"), text: $newName)
                        .appInput().focused($nameFocused).onSubmit(create).accessibilityIdentifier("axon-catalog-new-name")
                    Button(action: create) { Label(store.text("Create", "创建"), systemImage: "plus") }
                        .buttonStyle(ChromeButtonStyle(prominent: true)).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("axon-catalog-create")
                }
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red).accessibilityIdentifier("axon-catalog-error") }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries, id: \.self) { name in row(name) }
                        if entries.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tag").font(.system(size: 30)).foregroundStyle(Palette.muted)
                                Text(store.text("No tags yet", "还没有标签"))
                                    .font(.system(size: 14, weight: .medium))
                                Text(store.text("Enter a name above to create one.", "在上方输入名称即可创建。"))
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }.frame(maxWidth: .infinity).padding(.vertical, 45)
                        }
                    }.padding(.vertical, 2)
                }
            }.padding(20)
            Divider().overlay(Palette.border)
            HStack {
                Text(String(entries.count) + store.text(" tags", " 个标签"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button(store.text("Done", "完成")) { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 570, height: 560).foregroundStyle(Palette.text).background(Palette.sidebar)
            .appAlert(store.text("Delete tag?", "删除标签？"),
                   isPresented: Binding(get: { deletionName != nil }, set: { if !$0 { deletionName = nil } }), presenting: deletionName) { name in
                AppAlertButton(store.text("Cancel", "取消"), role: .cancel) { deletionName = nil }
                AppAlertButton(store.text("Delete", "删除"), role: .destructive) { delete(name) }
            } message: { name in
                let count = store.catalogHostCount(name, section: .tags)
                Text(store.text("“\(name)” will be removed from \(count) hosts. The hosts will remain in your vault.", "将从 \(count) 台主机中移除“\(name)”标签，主机仍保留在主机库中。"))
            }
    }
    private func row(_ name: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: "tag.fill", size: 34)
            if editingName == name {
                TextField(store.text("Name", "名称"), text: $renameDraft).appInput().onSubmit(rename)
                    .accessibilityLabel(store.text("Rename \(name)", "重命名 \(name)"))
                Button(action: rename) { Image(systemName: "checkmark") }.buttonStyle(IconButtonStyle())
                    .accessibilityLabel(store.text("Save name", "保存名称"))
                Button { editingName = nil; error = "" } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                    .accessibilityLabel(store.text("Cancel rename", "取消重命名"))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 14)).lineLimit(1)
                    Text(String(store.catalogHostCount(name, section: .tags)) + store.text(" hosts", " 台主机"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 6)
                Button { editingName = name; renameDraft = name; error = "" } label: { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle()).help(store.text("Rename", "重命名"))
                    .accessibilityLabel(store.text("Rename \(name)", "重命名 \(name)"))
                Button { deletionName = name } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle()).help(store.text("Delete", "删除"))
                    .accessibilityLabel(store.text("Delete \(name)", "删除 \(name)"))
            }
        }.padding(.horizontal, 12).frame(height: 62).background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }
    private func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); error = ""; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func create() {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if perform({ try store.createTag(newName) }) { newName = ""; nameFocused = true }
    }
    private func rename() {
        guard let old = editingName else { return }
        if perform({ try store.renameTag(old, to: renameDraft) }) { editingName = nil }
    }
    private func delete(_ name: String) {
        _ = perform { try store.deleteTag(name) }
        deletionName = nil
    }
}
