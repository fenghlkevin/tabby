import AppKit
import SwiftUI

struct FileBreadcrumb: Equatable {
    let name: String
    let path: String
}

func fileBreadcrumbs(_ path: String) -> [FileBreadcrumb] {
    var current = ""
    return path.split(separator: "/").map { name in
        current += "/" + name
        return FileBreadcrumb(name: String(name), path: current)
    }
}

extension FileEntry {
    var permissionDescription: String {
        var characters = [Character](symlink ? "l" : directory ? "d" : "-")
        let groups: [(UInt32, UInt32, UInt32, UInt32, Character, Character)] = [
            (0o400, 0o200, 0o100, 0o4000, "s", "S"),
            (0o040, 0o020, 0o010, 0o2000, "s", "S"),
            (0o004, 0o002, 0o001, 0o1000, "t", "T"),
        ]
        for (read, write, execute, special, lower, upper) in groups {
            characters.append(permissions & read != 0 ? "r" : "-")
            characters.append(permissions & write != 0 ? "w" : "-")
            characters.append(permissions & special != 0 ? (permissions & execute != 0 ? lower : upper) : (permissions & execute != 0 ? "x" : "-"))
        }
        return String(characters)
    }
}

struct FileTableAction {
    var title = ""
    var enabled = true
    var separator = false
    var action: (() -> Void)?
    static var divider: FileTableAction { FileTableAction(separator: true) }
}

enum FileTableRow: Equatable {
    case parent(path: String)
    case file(FileEntry)
    var entry: FileEntry? { if case .file(let entry) = self { return entry }; return nil }
    var parentPath: String? { if case .parent(let path) = self { return path }; return nil }
}

func fileParentPath(_ path: String) -> String? {
    let normalized = (path as NSString).standardizingPath
    guard normalized.hasPrefix("/"), normalized != "/" else { return nil }
    let parent = (normalized as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
}

/// AppKit owns these rows throughout their lifetime. SwiftUI supplies the data
/// and selection only; it cannot replace the delegate or restore inset styling.
struct FileTableView: NSViewRepresentable {
    var entries: [FileEntry]
    var path = "/"
    @Binding var selection: Set<String>
    var columnTitles: [String]
    var folderTitle: String
    var linkTitle: String
    var remote: Bool
    var onOpen: (FileEntry) -> Void
    var onParent: (String) -> Void = { _ in }
    var parentTitle = "Parent folder"
    var onSort: (String) -> Void
    var actions: ([FileEntry]) -> [FileTableAction]

    var rows: [FileTableRow] {
        let files = entries.map(FileTableRow.file)
        guard let parent = fileParentPath(path) else { return files }
        return [.parent(path: parent)] + files
    }

    func makeCoordinator() -> FileTableCoordinator { FileTableCoordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self, in: view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The table's column widths belong to its scrolling document. They must
        // never become the minimum width of a SwiftUI pane or split container.
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

@MainActor final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var owner: FileTableView
    private(set) var rows: [FileTableRow]
    private(set) weak var table: FileNativeTable?
    private var updating = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter
    }()
    init(_ owner: FileTableView) { self.owner = owner; rows = owner.rows }

    func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(hex: "#EDF2F3")
        let table = FileNativeTable()
        table.style = .plain
        table.autoresizingMask = [.width]
        table.backgroundColor = NSColor(hex: "#EDF2F3")
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.rowSizeStyle = .custom
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let header = FileHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 36))
        table.headerView = header
        let identifiers = ["name", "modified", "size", "kind"]
        let widths: [CGFloat] = [260, 135, 75, 65]
        for (index, identifier) in identifiers.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = owner.columnTitles[index]
            column.headerCell = FileHeaderCell(textCell: column.title)
            column.width = widths[index]
            column.minWidth = index == 0 ? 140 : widths[index]
            column.maxWidth = index == 0 ? 4000 : widths[index]
            column.resizingMask = index == 0 ? [.autoresizingMask, .userResizingMask] : []
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(doubleClick(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.contextProvider = { [weak self] rows in self?.contextMenu(for: rows) }
        table.primaryAction = { [weak self] row in self?.open(row: row) }
        scroll.documentView = table
        self.table = table
        update(owner, in: scroll)
        return scroll
    }

    func update(_ owner: FileTableView, in scroll: NSScrollView) {
        guard let table = scroll.documentView as? FileNativeTable else { return }
        let newRows = owner.rows
        let dataChanged = rows != newRows
        let keepParentSelected = self.owner.path == owner.path && rows.first?.parentPath != nil && newRows.first?.parentPath != nil && table.selectedRowIndexes.contains(0)
        self.owner = owner
        rows = newRows
        updating = true
        defer { updating = false }
        for (index, column) in table.tableColumns.enumerated() {
            column.title = owner.columnTitles[index]
            column.headerCell.stringValue = column.title
        }
        if dataChanged || table.numberOfRows != rows.count { table.reloadData() }
        var selected = IndexSet(rows.indices.filter { rows[$0].entry.map { owner.selection.contains($0.path) } ?? false })
        if keepParentSelected { selected.insert(0) }
        if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        refreshVisibleCells(table)
        table.headerView?.needsDisplay = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 44 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileTableRowView()
        view.index = row
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let identifier = column.identifier
        if identifier.rawValue == "name" {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileNameCell) ?? FileNameCell()
            cell.identifier = identifier
            cell.configure(rows[row], selected: tableView.selectedRowIndexes.contains(row))
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileMetadataCell) ?? FileMetadataCell()
        cell.identifier = identifier
        configure(cell, row: rows[row], column: identifier.rawValue, selected: tableView.selectedRowIndexes.contains(row))
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if !updating {
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].entry?.path : nil })
            if owner.selection != selected { owner.selection = selected }
        }
        refreshVisibleCells(table)
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let key = tableColumn.identifier.rawValue
        if key == "name" || key == "size" || key == "modified" { owner.onSort(key) }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let entry = rows[row].entry else { return nil }
        return owner.remote ? ("tabby-remote:" + entry.path) as NSString : URL(fileURLWithPath: entry.path) as NSURL
    }

    @objc func doubleClick(_ sender: NSTableView) { open(row: sender.clickedRow) }
    func open(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .parent(let path): owner.onParent(path)
        case .file(let entry): owner.onOpen(entry)
        }
    }
    func contextMenu(for rows: IndexSet) -> NSMenu {
        let selected = rows.compactMap { self.rows.indices.contains($0) ? self.rows[$0].entry : nil }
        let parent = rows.compactMap { self.rows.indices.contains($0) ? self.rows[$0].parentPath : nil }.first
        let menu = NSMenu(); menu.minimumWidth = 240; menu.font = .systemFont(ofSize: 13)
        menu.autoenablesItems = false
        let actions = selected.isEmpty && parent != nil
            ? [FileTableAction(title: owner.parentTitle, action: { [weak self] in if let parent { self?.owner.onParent(parent) } })]
            : owner.actions(selected)
        for action in actions {
            if action.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.isEnabled = action.enabled
            if let callback = action.action {
                let target = FileMenuTarget(callback)
                item.target = target; item.action = #selector(FileMenuTarget.runAction(_:))
                item.representedObject = target // NSMenuItem's target alone is not retained.
            }
            menu.addItem(item)
        }
        return menu
    }

    private func configure(_ cell: FileMetadataCell, row: FileTableRow, column: String, selected: Bool) {
        guard let entry = row.entry else { cell.configure("", selected: selected); return }
        let value: String
        switch column {
        case "modified": value = dateFormatter.string(from: entry.modified)
        case "size": value = entry.directory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
        default: value = entry.directory ? owner.folderTitle : entry.symlink ? owner.linkTitle : (entry.name as NSString).pathExtension
        }
        cell.configure(value, selected: selected)
    }
    private func refreshVisibleCells(_ table: NSTableView) {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return }
        let end = min(rows.count, NSMaxRange(range))
        guard range.location < end else { return }
        for row in range.location..<end {
            let selected = table.selectedRowIndexes.contains(row)
            for (column, item) in table.tableColumns.enumerated() {
                if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? FileNameCell {
                    cell.configure(rows[row], selected: selected)
                } else if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? FileMetadataCell {
                    configure(cell, row: rows[row], column: item.identifier.rawValue, selected: selected)
                }
            }
            table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }
}

@MainActor final class FileNativeTable: NSTableView {
    var contextProvider: ((IndexSet) -> NSMenu?)?
    var primaryAction: ((Int) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0 {
            if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
            return contextProvider?(selectedRowIndexes)
        }
        return contextProvider?([])
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 { primaryAction?(selectedRow); return }
        super.keyDown(with: event)
    }
}

@MainActor final class FileTableRowView: NSTableRowView {
    var index = 0
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor(hex: index.isMultiple(of: 2) ? "#EDF2F3" : "#E8EEF0").setFill()
        bounds.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(hex: "#2E91EC").setFill()
        bounds.fill()
    }
    override func drawSeparator(in dirtyRect: NSRect) {}
}

@MainActor private final class FileNameCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let permissions = NSTextField(labelWithString: "")
    private var navigationRow = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13)
        permissions.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        for label in [name, permissions] { label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1; addSubview(label) }
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        textField = name; imageView = icon
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: FileTableRow, selected: Bool) {
        let entry = row.entry
        navigationRow = row.parentPath != nil
        name.stringValue = entry?.name ?? ".."
        permissions.stringValue = entry?.permissionDescription ?? ""
        permissions.isHidden = navigationRow
        name.textColor = selected ? .white : NSColor(hex: "#171A2A")
        permissions.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : NSColor(hex: "#7B8A92")
        let symbol = navigationRow ? "folder.fill" : entry?.symlink == true ? "link" : entry?.directory == true ? "folder.fill" : "doc"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        icon.contentTintColor = selected ? .white : NSColor(hex: navigationRow || entry?.directory == true ? "#65CDF5" : "#7B8A92")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: 9, width: 24, height: 26)
        let width = max(0, bounds.width - 54)
        name.frame = NSRect(x: 46, y: navigationRow ? 12 : 6, width: width, height: 19)
        permissions.frame = NSRect(x: 46, y: 25, width: width, height: 14)
    }
}

@MainActor private final class FileMetadataCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        addSubview(label); textField = label
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: String, selected: Bool) { label.stringValue = value; label.textColor = selected ? .white : NSColor(hex: "#7B8A92") }
    override func layout() { super.layout(); label.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 20), height: 18) }
}

@MainActor private final class FileMenuTarget: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func runAction(_ sender: NSMenuItem) { callback() }
}

private final class FileHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) { NSColor(hex: "#EDF2F3").setFill(); dirtyRect.fill(); super.draw(dirtyRect) }
}

private final class FileHeaderCell: NSTableHeaderCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        NSColor(hex: "#EDF2F3").setFill(); frame.fill()
        let title = NSAttributedString(string: stringValue, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(hex: "#171A2A")])
        title.draw(in: NSRect(x: frame.minX + 10, y: frame.midY - 7, width: max(0, frame.width - 20), height: 17))
        NSColor(hex: "#D5DCE1").setFill()
        NSRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1).fill()
        NSRect(x: frame.maxX - 1, y: frame.minY, width: 1, height: frame.height).fill()
    }
}
