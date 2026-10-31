import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class OperationsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSTextView()
    private let service: FileOperationService
    private let indicator = NSProgressIndicator()
    var onCancel: ((UUID) -> Void)?
    init(service: FileOperationService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "PathDeck · 文件任务"; window.minSize = NSSize(width: 580, height: 360); window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSView(); window.contentView = root
        for (id, title, width) in [("name", "操作 / 当前项目", 270.0), ("state", "状态", 210.0), ("count", "已处理", 120.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        detail.isEditable = false; detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.frame = NSRect(x: 0, y: 0, width: 720, height: 180)
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true
        let cancel = NSButton(title: "取消所选任务", target: self, action: #selector(cancelSelected))
        indicator.style = .spinning; indicator.controlSize = .small
        for v in [list, details, cancel, indicator] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor), list.trailingAnchor.constraint(equalTo: root.trailingAnchor), list.topAnchor.constraint(equalTo: root.topAnchor), list.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5),
            details.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), details.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), details.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 8), details.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -8),
            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            indicator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), indicator.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
        ])
        window.setContentSize(NSSize(width: 760, height: 480)); window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(service:)") }
    func update() {
        let selected = table.selectedRow
        table.reloadData()
        if service.isBusy { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
        if selected >= 0 && selected < service.records.count { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        else if !service.records.isEmpty { table.selectRowIndexes(IndexSet(integer: service.records.count - 1), byExtendingSelection: false) }
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { service.records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = service.records[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "state": text = record.state.title
        case "count": text = "\(record.results.count) / \(record.total)"
        default: text = "\(record.request.kind.title) · \(record.currentName)"
        }
        return NSTextField(labelWithString: text)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        guard service.records.indices.contains(table.selectedRow) else { return }
        let record = service.records[table.selectedRow]
        var lines = ["\(record.request.kind.title)：\(record.state.title)", "成功 \(record.successCount) · 跳过 \(record.skippedCount) · 失败 \(record.failureCount) · 未处理 \(max(0, record.total - record.results.count))"]
        for result in record.results { lines.append("\(result.outcome.rawValue): \(result.source?.path ?? "") → \(result.destination?.path ?? "")\n\(result.message)") }
        if !record.artifacts.isEmpty { lines.append("未提交的临时项目（请核实后处理）：\n" + record.artifacts.map(\.path).joined(separator: "\n")) }
        detail.string = lines.joined(separator: "\n\n")
    }
    @objc private func cancelSelected() { if service.records.indices.contains(table.selectedRow) { onCancel?(service.records[table.selectedRow].id) } }
}
