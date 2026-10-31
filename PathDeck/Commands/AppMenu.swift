import AppKit

@MainActor
enum AppMenu {
    static func install(commandTarget: AppDelegate) {
        let main = NSMenu()

        let app = NSMenu(title: "PathDeck")
        app.addItem(withTitle: "关于 PathDeck", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 PathDeck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        let keyboard = app.addItem(withTitle: "Windows 按键习惯", action: #selector(AppDelegate.toggleKeyboardStyle(_:)), keyEquivalent: "")
        keyboard.target = commandTarget
        app.addItem(.separator())
        app.addItem(withTitle: "退出 PathDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        append(app, to: main)

        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "新建窗口", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n").target = commandTarget
        file.addItem(withTitle: "新建标签页", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t").target = commandTarget
        file.addItem(.separator())
        for (title, action, key) in [
            ("新建文件夹", #selector(AppDelegate.newFolder(_:)), "N"),
            ("新建文本文件", #selector(AppDelegate.newTextFile(_:)), ""),
            ("重命名", #selector(AppDelegate.renameSelection(_:)), ""),
            ("移入废纸篓", #selector(AppDelegate.trashSelection(_:)), "\u{8}"),
            ("文件任务", #selector(AppDelegate.showFileTasks(_:)), ""),
        ] { file.addItem(withTitle: title, action: action, keyEquivalent: key).target = commandTarget }
        file.addItem(.separator())
        file.addItem(withTitle: "快速预览", action: #selector(AppDelegate.previewSelection(_:)), keyEquivalent: "").target = commandTarget
        file.addItem(withTitle: "属性…", action: #selector(AppDelegate.propertiesSelection(_:)), keyEquivalent: "i").target = commandTarget
        file.addItem(.separator())
        file.addItem(withTitle: "关闭标签页或窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        append(file, to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: #selector(AppDelegate.undo(_:)), keyEquivalent: "z").target = commandTarget
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "过滤当前目录名称…", action: #selector(AppDelegate.focusFilter(_:)), keyEquivalent: "f").target = commandTarget
        append(edit, to: main)

        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "平铺视图", action: #selector(AppDelegate.showTiles(_:)), keyEquivalent: "1").target = commandTarget
        view.addItem(withTitle: "详情列表", action: #selector(AppDelegate.showDetails(_:)), keyEquivalent: "2").target = commandTarget
        view.addItem(.separator())
        view.addItem(withTitle: "紧凑列表", action: #selector(AppDelegate.toggleCompactList(_:)), keyEquivalent: "").target = commandTarget
        append(view, to: main)

        let go = NSMenu(title: "前往")
        for (title, action, key) in [
            ("输入路径…", #selector(BrowserViewController.editLocation(_:)), "l"),
            ("后退", #selector(BrowserViewController.goBack(_:)), "["),
            ("前进", #selector(BrowserViewController.goForward(_:)), "]"),
            ("上一级", #selector(BrowserViewController.goUp(_:)), "\u{F700}"),
            ("刷新", #selector(BrowserViewController.refreshDirectory(_:)), "r"),
        ] { go.addItem(withTitle: title, action: action, keyEquivalent: key).target = commandTarget }
        let hidden = go.addItem(withTitle: "显示隐藏文件", action: #selector(BrowserViewController.toggleHidden(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = commandTarget
        for (key, modifiers) in [("l", NSEvent.ModifierFlags.control), ("d", .option), ("g", [.command, .shift])] {
            let shortcut = go.addItem(withTitle: "输入路径", action: #selector(BrowserViewController.editLocation(_:)), keyEquivalent: key)
            shortcut.keyEquivalentModifierMask = modifiers; shortcut.target = commandTarget
            shortcut.isHidden = true; shortcut.allowsKeyEquivalentWhenHidden = true
        }
        let recent = NSMenu(title: "最近目录"); recent.delegate = commandTarget
        go.addItem(withTitle: "在终端中打开当前目录", action: #selector(AppDelegate.openCurrentTerminal(_:)), keyEquivalent: "").target = commandTarget
        let recentItem = go.addItem(withTitle: "最近目录", action: nil, keyEquivalent: ""); recentItem.submenu = recent
        append(go, to: main)

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let next = window.addItem(withTitle: "下一个标签页", action: #selector(AppDelegate.nextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]; next.target = commandTarget
        let previous = window.addItem(withTitle: "上一个标签页", action: #selector(AppDelegate.previousTab(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]; previous.target = commandTarget
        window.addItem(withTitle: "将标签页移到新窗口", action: #selector(AppDelegate.detachTab(_:)), keyEquivalent: "").target = commandTarget
        window.addItem(withTitle: "合并所有窗口", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        append(window, to: main)

        NSApplication.shared.mainMenu = main
        NSApplication.shared.windowsMenu = window
    }

    private static func append(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

