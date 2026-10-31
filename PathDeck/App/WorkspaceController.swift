import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
enum WorkspaceController {
    static func capture(_ controllers: [MainWindowController], active: MainWindowController?) -> WorkspaceSnapshot {
        let open = controllers.filter { !$0.isClosed }
        var seen: Set<ObjectIdentifier> = [], groups: [WindowGroupSnapshot] = [], activeIndex = 0
        for controller in open {
            guard let window = controller.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let windows = window.tabGroup?.windows ?? [window]
            let pages = windows.compactMap { w in open.first { $0.window === w } }
            guard !pages.isEmpty else { continue }
            pages.compactMap(\.window).forEach { seen.insert(ObjectIdentifier($0)) }
            let selected = pages.firstIndex { $0.window === window.tabGroup?.selectedWindow } ?? 0
            let frame = pages[selected].window!.frame
            if pages.contains(where: { $0 === active }) { activeIndex = groups.count }
            groups.append(WindowGroupSnapshot(pages: pages.map { $0.browser.pageSnapshot() }, selectedIndex: selected, frame: WindowPlacement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)))
        }
        return WorkspaceSnapshot(groups: groups, activeGroup: activeIndex)
    }
}
