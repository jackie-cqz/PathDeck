import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FilePropertiesWindowController: NSWindowController, NSWindowDelegate {
    private let reader = FilePropertiesReader()
    private let text = NSTextView()
    private let heading = NSTextField(labelWithString: "属性")
    private var task: Task<Void, Never>?
    private(set) var values: [FileProperties] = []
    var onClose: (() -> Void)?
    init(urls: [URL]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "属性 — PathDeck"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = BrowserBackground(); window.contentView = root
        heading.font = .systemFont(ofSize: 18, weight: .semibold); heading.lineBreakMode = .byTruncatingMiddle
        heading.stringValue = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个项目"
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 13); text.textContainerInset = NSSize(width: 18, height: 14)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineBreakMode = .byWordWrapping
        text.frame = NSRect(x: 0, y: 0, width: 560, height: 480); text.minSize = NSSize(width: 0, height: 480); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("文件属性详情"); text.setAccessibilityIdentifier("PathDeck.Properties")
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        for view in [heading, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.setContentSize(NSSize(width: 560, height: 560))
        text.string = "正在读取属性…"; window.center()
        task = Task { [weak self, reader] in
            let properties = await reader.read(urls)
            guard !Task.isCancelled, let self else { return }
            self.values = properties; self.text.string = Self.describe(properties)
            root.layoutSubtreeIfNeeded()
            self.text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, self.text.frame.height)))
            self.text.textContainer?.containerSize = NSSize(width: max(1, scroll.contentSize.width - self.text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(urls:)") }
    func waitForLoad() async { await task?.value }
    var detail: String { text.string }
    func windowWillClose(_ notification: Notification) { task?.cancel(); onClose?() }
    private static func describe(_ values: [FileProperties]) -> String {
        let bytes = values.compactMap(\.bytes).reduce(Int64(0)) { sum, next in
            let result = sum.addingReportingOverflow(next); return result.overflow ? Int64.max : result.partialValue
        }
        var sections: [String] = []
        if values.count > 1 { sections.append("\(values.count) 个项目\n已知文件大小合计：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\n文件夹大小未递归计算。") }
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .medium
        for value in values {
            var lines = ["名称：\(value.url.lastPathComponent)", "位置：\(value.url.path)", "类型：\(value.kind)"]
            if let error = value.error { lines.append("无法读取：\(error)") }
            else {
                lines += ["大小：\(value.bytes.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))（\($0) 字节）" } ?? "未计算（不递归扫描文件夹）")",
                    "创建时间：\(value.created.map(date.string) ?? "—")", "修改时间：\(value.modified.map(date.string) ?? "—")",
                    "所有者：\(value.owner)", "POSIX 权限：\(value.permissions)", "当前可写：\(value.writable ? "是" : "否")"]
                if let target = value.symbolicLink { lines.append("链接目标：\(target)") }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n──────────────────\n\n")
    }
}
