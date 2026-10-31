import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
private final class PathBackground: NSView {
    var onClick: (() -> Void)?
    var drawsContainer = false
    override func draw(_ dirtyRect: NSRect) {
        guard drawsContainer else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill(); path.fill(); NSColor.separatorColor.setStroke(); path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
@MainActor final class KeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

@MainActor
final class AddressBarView: NSView, NSTextFieldDelegate {
    let path = NSTextField()
    private let crumbs = NSStackView()
    private let background = PathBackground()
    private let errorLabel = NSTextField(labelWithString: "")
    private let repairButton = NSButton(title: "移除末尾换行并重试", target: nil, action: nil)
    private let editButton = KeyboardButton()
    private var directory: URL
    private var buttons: [NSButton] = []
    private var completionTask: Task<Void, Never>?
    private let reader = DirectoryReader()
    private var candidates: [URL] = []
    private var candidateIndex = -1
    private var panel: NSPanel?
    private var candidateButtons: [NSButton] = []
    private var editing = false
    private var submitting = false
    private var changingFocus = false
    private var revision = 0
    private var hasMoreCandidates = false
    var completionCount: Int { candidates.count }
    var completionIsVisible: Bool { panel?.isVisible ?? false }
    var isEditing: Bool { editing }
    func waitForCompletions() async {
        var stamp: Int
        repeat { stamp = revision; await completionTask?.value } while stamp != revision
    }
    var showHidden = false
    var onSubmit: ((String) -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
        super.init(frame: .zero)
        let controls = NSStackView()
        controls.spacing = 6; controls.distribution = .fillEqually
        for (symbol, title, action) in [
            ("chevron.left", "后退", #selector(back)), ("chevron.right", "前进", #selector(forward)),
            ("arrow.up", "上一级", #selector(up)), ("arrow.clockwise", "刷新", #selector(refresh)),
        ] {
            let b = KeyboardButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
            b.bezelStyle = .texturedRounded; b.toolTip = title
            b.setAccessibilityLabel(title)
            buttons.append(b); controls.addArrangedSubview(b)
        }
        path.delegate = self
        path.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        path.bezelStyle = .roundedBezel; path.isHidden = true
        path.setAccessibilityLabel("输入文件夹路径"); path.setAccessibilityIdentifier("PathDeck.AddressBar")
        path.placeholderString = "输入路径并按 Enter，例如 ~/Downloads"
        background.onClick = { [weak self] in self?.beginEditing() }
        background.drawsContainer = true
        crumbs.spacing = 2; crumbs.alignment = .centerY
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setAccessibilityIdentifier("PathDeck.AddressError")
        repairButton.target = self; repairButton.action = #selector(repairNewline)
        repairButton.bezelStyle = .inline; repairButton.isHidden = true
        repairButton.font = .systemFont(ofSize: 11)
        let edit = editButton
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑路径"); edit.target = self; edit.action = #selector(editPath)
        edit.bezelStyle = .texturedRounded; edit.toolTip = "编辑路径（⌘L）"
        edit.setAccessibilityLabel("编辑路径"); edit.setAccessibilityHelp("切换为可输入的完整路径，快捷键 Command L。")
        for v in [controls, background, path, errorLabel, repairButton, edit] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        crumbs.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(crumbs)
        let spacer = PathBackground(); spacer.onClick = { [weak self] in self?.beginEditing() }
        spacer.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(spacer)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), controls.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            controls.widthAnchor.constraint(equalToConstant: 146), controls.heightAnchor.constraint(equalToConstant: 28),
            background.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 12), background.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -6),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 11), background.heightAnchor.constraint(equalToConstant: 30),
            path.leadingAnchor.constraint(equalTo: background.leadingAnchor), path.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            path.topAnchor.constraint(equalTo: background.topAnchor), path.heightAnchor.constraint(equalTo: background.heightAnchor),
            crumbs.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4), crumbs.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -8),
            spacer.leadingAnchor.constraint(equalTo: crumbs.trailingAnchor), spacer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            spacer.topAnchor.constraint(equalTo: background.topAnchor), spacer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            edit.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), edit.centerYAnchor.constraint(equalTo: background.centerYAnchor), edit.widthAnchor.constraint(equalToConstant: 28),
            errorLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: background.bottomAnchor, constant: 2),
            repairButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), repairButton.topAnchor.constraint(equalTo: background.bottomAnchor, constant: 1),
        ])
        update(directory: directory, canBack: false, canForward: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(directory:)") }

    func update(directory: URL, canBack: Bool, canForward: Bool, preserveDraft: Bool = false) {
        let keepDraft = preserveDraft && editing && !submitting
        self.directory = directory
        buttons[0].isEnabled = canBack; buttons[1].isEnabled = canForward; buttons[2].isEnabled = directory.path != "/"
        if !keepDraft { path.stringValue = directory.path; cancelEditing() }
        for v in crumbs.arrangedSubviews { crumbs.removeArrangedSubview(v); v.removeFromSuperview() }
        var ancestors: [URL] = []; var cursor = directory
        while true {
            ancestors.insert(cursor, at: 0)
            if cursor.path == "/" { break }
            let parent = cursor.deletingLastPathComponent(); if parent == cursor { break }; cursor = parent
        }
        let visible = ancestors.count > 3 ? Array(ancestors.suffix(2)) : ancestors
        if ancestors.count > 3 {
            let overflow = NSPopUpButton(frame: .zero, pullsDown: true); overflow.addItem(withTitle: "…")
            for url in ancestors.dropLast(2) {
                let item = NSMenuItem(title: url.path, action: #selector(goToCrumb(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = url; overflow.menu?.addItem(item)
            }
            crumbs.addArrangedSubview(overflow)
        }
        for url in visible {
            let b = NSButton(title: url.path == "/" ? "/" : url.lastPathComponent, target: self, action: #selector(goToCrumb(_:)))
            b.isBordered = false; b.lineBreakMode = .byTruncatingMiddle; b.toolTip = url.path
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            b.identifier = NSUserInterfaceItemIdentifier(url.absoluteString); b.menu = pathMenu(url)
            crumbs.addArrangedSubview(b); crumbs.addArrangedSubview(NSTextField(labelWithString: "›"))
        }
        background.menu = pathMenu(directory)
        background.setAccessibilityLabel("当前位置")
        background.setAccessibilityValue(directory.path)
    }
    func connectKeyLoop(sidebar: NSView, list: NSView, tasks: NSView) {
        for i in 0..<(buttons.count - 1) { buttons[i].nextKeyView = buttons[i + 1] }
        buttons.last?.nextKeyView = editButton; editButton.nextKeyView = sidebar
        path.nextKeyView = sidebar; sidebar.nextKeyView = list; list.nextKeyView = tasks; tasks.nextKeyView = buttons.first
    }
    func beginEditing() {
        changingFocus = true
        defer { changingFocus = false }
        window?.makeFirstResponder(nil)
        submitting = false; crumbs.isHidden = true; path.isHidden = false
        path.stringValue = directory.path; window?.makeFirstResponder(path)
        path.selectText(nil)
        editing = true; path.isHidden = false; crumbs.isHidden = true
    }
    func showError(_ message: String) {
        submitting = false; errorLabel.stringValue = message; errorLabel.toolTip = message
        repairButton.isHidden = !(path.stringValue.hasSuffix("\n") || path.stringValue.hasSuffix("\r"))
        if !repairButton.isHidden { errorLabel.stringValue = "路径末尾含换行。" }
        if editing && path.currentEditor() == nil {
            changingFocus = true; window?.makeFirstResponder(path); changingFocus = false
        }
    }
    private func cancelEditing() {
        revision += 1; completionTask?.cancel(); closeCandidates()
        editing = false; submitting = false; path.isHidden = true; crumbs.isHidden = false; errorLabel.stringValue = ""; repairButton.isHidden = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { if !submitting && !changingFocus { cancelEditing() } }
    func controlTextDidChange(_ obj: Notification) {
        revision += 1; let stamp = revision
        errorLabel.stringValue = ""; submitting = false; completionTask?.cancel(); closeCandidates()
        guard let editor = path.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let input = path.stringValue; let base = directory; let hidden = showHidden; let reader = reader
        completionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let (parent, prefix) = try PathInputParser().completionParent(input, relativeTo: base)
                let dirs = try await reader.childDirectories(parent, showHidden: hidden || prefix.hasPrefix("."))
                try Task.checkCancellation()
                guard let self else { return }
                guard self.revision == stamp, self.editing else { return }
                let matches = dirs.filter { prefix.isEmpty || $0.realName.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil }
                self.hasMoreCandidates = matches.count > 20
                self.candidates = Array(matches.prefix(20).map(\.url))
                self.showCandidates()
            } catch { /* Suggestions are optional; navigation reports actual read errors. */ }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            if candidateIndex >= 0 { acceptCandidate(candidateIndex) }
            closeCandidates(); submitting = true; onSubmit?(path.stringValue); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if panel != nil { closeCandidates() } else { cancelEditing(); window?.makeFirstResponder(nil) }; return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !candidates.isEmpty else { return false }
            candidateIndex = command == #selector(NSResponder.moveDown(_:)) ? min(candidateIndex + 1, candidates.count - 1) : max(candidateIndex - 1, 0)
            for (i, b) in candidateButtons.enumerated() { b.contentTintColor = i == candidateIndex ? .controlAccentColor : .labelColor; if i == candidateIndex { b.scrollToVisible(b.bounds) } }; return true
        case #selector(NSResponder.insertTab(_:)):
            guard !candidates.isEmpty else { return false }; acceptCandidate(max(candidateIndex, 0)); return true
        default: return false
        }
    }
    private func showCandidates() {
        guard !candidates.isEmpty, let window else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true; panel.backgroundColor = .controlBackgroundColor; panel.level = .popUpMenu; panel.hidesOnDeactivate = true
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        candidateButtons = candidates.enumerated().map { i, url in
            let b = NSButton(title: url.lastPathComponent + "/", target: self, action: #selector(clickedCandidate(_:)))
            b.tag = i; b.isBordered = false; b.alignment = .left; b.toolTip = url.path; stack.addArrangedSubview(b); return b
        }
        if hasMoreCandidates { stack.addArrangedSubview(NSTextField(labelWithString: "还有更多目录，请继续输入以缩小范围")) }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        let rect = window.convertToScreen(convert(path.frame, to: nil)); let height = min(CGFloat(candidates.count) * 27 + 6, 250)
        panel.setFrame(NSRect(x: rect.minX, y: rect.minY - height, width: rect.width, height: height), display: false); panel.contentView = scroll
        stack.setFrameSize(NSSize(width: rect.width, height: CGFloat(candidates.count) * 27 + (hasMoreCandidates ? 24 : 0)))
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for b in candidateButtons { b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; b.heightAnchor.constraint(equalToConstant: 27).isActive = true }
        self.panel = panel; window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
    }
    private func acceptCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }; path.stringValue = candidates[index].path + "/"
        if let editor = path.currentEditor() as? NSTextView { editor.string = path.stringValue; editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }; closeCandidates()
    }
    private func closeCandidates() {
        if let panel { window?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil; candidates = []; candidateButtons = []; candidateIndex = -1
    }
    private func pathMenu(_ url: URL) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("复制完整路径", #selector(copyCrumb(_:))), ("前往此目录", #selector(goToCrumb(_:))), ("编辑路径", #selector(editPath))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = url; menu.addItem(item)
        }; return menu
    }
    @objc private func goToCrumb(_ sender: Any) {
        if let item = sender as? NSMenuItem, let url = item.representedObject as? URL { onNavigate?(url) }
        else if let b = sender as? NSButton, let id = b.identifier, let url = URL(string: id.rawValue) { onNavigate?(url) }
    }
    @objc private func copyCrumb(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func clickedCandidate(_ sender: NSButton) { acceptCandidate(sender.tag) }
    @objc private func repairNewline() {
        while path.stringValue.hasSuffix("\n") || path.stringValue.hasSuffix("\r") { path.stringValue.removeLast() }
        repairButton.isHidden = true; submitting = true; onSubmit?(path.stringValue)
    }
    @objc private func editPath() { beginEditing() }
    @objc private func back() { onBack?() }
    @objc private func forward() { onForward?() }
    @objc private func up() { onUp?() }
    @objc private func refresh() { onRefresh?() }
}
