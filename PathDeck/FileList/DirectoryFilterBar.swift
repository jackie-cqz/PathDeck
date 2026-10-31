import AppKit

@MainActor
final class DirectoryFilterBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let title = NSTextField(labelWithString: "当前位置")
    var directory: URL? { didSet { title.stringValue = directory?.path == "/" ? "/" : directory?.lastPathComponent ?? "当前位置"; title.toolTip = directory?.path } }
    var onChange: ((String) -> Void)?
    var onExit: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = BrowserAppearance.mint
        field.placeholderString = "按名称过滤（⌘F）"
        field.delegate = self; field.target = self; field.action = #selector(changed)
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.setAccessibilityLabel("过滤当前目录名称")
        field.setAccessibilityIdentifier("PathDeck.NameFilter")
        field.setAccessibilityHelp("只显示当前目录中名称匹配的项目，不递归搜索。Escape 清除过滤并返回列表。")
        for v in [icon, title, field] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), title.centerYAnchor.constraint(equalTo: centerYAnchor), title.trailingAnchor.constraint(lessThanOrEqualTo: field.leadingAnchor, constant: -24),
            field.widthAnchor.constraint(equalToConstant: 300), field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    @objc private func changed() { guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }; onChange?(field.stringValue) }
    func controlTextDidChange(_ notification: Notification) {
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }; onChange?(field.stringValue)
    }
    func display(_ query: String) {
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != query { field.stringValue = query }
    }
    func focus() { window?.makeFirstResponder(field); field.selectText(nil) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.cancelOperation(_:)) { field.stringValue = ""; onChange?(""); onExit?(); return true }
        if command == #selector(NSResponder.insertNewline(_:)) || command == #selector(NSResponder.moveDown(_:)) { onExit?(); return true }
        return false
    }
}
