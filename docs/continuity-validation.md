# v0.3：文件撤销、拖放与会话恢复

版本：0.3.0（4）。本轮完成用户要求的三项，沿用 Swift 6 + AppKit 和现有串行文件操作服务。

## 使用与实现

| 能力 | 行为与保护 |
| --- | --- |
| 撤销 | 编辑菜单、⌘Z，Windows 文件列表 Ctrl+Z；新建文件夹/空文本、重命名、同卷移动及拖放移动。所有窗口共享最近 50 个可撤销条目。 |
| 逆操作 | 日志保存身份、原父目录、原名称；逆序执行批次，部分失败后只重试未完成项。原位置被占用或对象被替换时失败，不覆盖。新建项目须仍为空且修改戳相同，撤销只移入系统废纸篓。 |
| 文本撤销 | 路径、过滤和内联文本编辑优先使用编辑器的原生 undoManager；不会撤销文件。文件任务/拖放准备期间文件撤销禁用。 |
| 拖放 | 列表/目录树多项 file URL 导出；空白处、目录行、侧栏目录接收。标签文件夹图标悬停切换，松手放入该页目录。应用内同卷默认移动，外部/跨卷默认复制；Option / Windows Ctrl 复制，Command 请求移动。对其他应用仅导出复制。 |
| 稳定引用 | 拖动源、目录行和侧栏目标固定身份，排序/导航不更换已接受的目标。拒绝自身/后代、根目录和无效同目录移动。外部引用异步准备，支持取消，关闭来源页后已接受任务继续。拖放不修改剪贴板。 |
| 完整会话 | 全部窗口分组、标签顺序、活动标签/窗口，以及每页目录、身份化选择、滚动锚点、过滤/排序/隐藏项/列和侧栏宽度；窗口位置和大小按组保存。约每秒捕获，350 ms 防抖原子落盘，退出等待保存。 |
| 失效状态 | 不可访问目录保留原标签及状态，可刷新重试；重启前改名的同身份文件继续选中，同名替换对象不选中。旧单目录设置兼容，损坏配置继续备份。 |

核心文件：Core/Operations/FileUndoHistory.swift、FileOperationEngine.swift、Core/Operations/FileDropPolicy.swift、Operations/FileDragSource.swift、FileDropController.swift、FileList/TabDropView.swift、Core/Persistence/WorkspaceSnapshot.swift、App/WorkspaceController.swift。

## 自动验证

最终源码与交付 Release 均完成验证。原始证据位于 build/validation/continuity-*、workspace-*。

- SwiftPM 与原生 Xcode 核心测试：各 73 tests / 13 suites 通过。覆盖逆操作链、空目录/空文件修改保护、占用冲突、部分撤销重试、重新读取日志、同名替换保护和大小写重命名日志归属；拖放策略与损坏/旧版会话配置也有核心测试。
- 原生专项检查覆盖真实菜单/窗口、文本编辑器、实际文件移动/撤销、系统废纸篓及标签落点。测试只将自己新建的空目录送入废纸篓，并按 API 返回的确切地址复原，不枚举或清理用户废纸篓。
- 独立进程检查使用两个真实 app 进程和私有设置文件：生产进程保存三个标签与另一个窗口后退出，检查器在进程退出期间改名目录/文件、替换一个选中对象，再由消费进程恢复。该检查验证磁盘读写，不依赖原进程内存。
- 最终 Release 完整原生回归：184 / 184，通过；其中拖放回调及文件结果 29 项，连续操作/撤销/标签与会话 16 项。跨进程生产 5 项、恢复 10 项，全部通过。
- Release 热缓存三次访问中位数：1,000 项 101.9 ms，10,000 项 643.1 ms；10,000 项名称过滤 48.4 ms。50 次快速导航正确；监听 29 / 64，停止后 0，图标缓存 2 / 128。最大主线程心跳间隔约 89.6 ms。未为性能测量同时运行其他编译/GUI 检查。
- Debug / Release 脚本打包、最终原生 Xcode 构建、工程同步、plist、脚本语法和签名检查通过。仅保留既有 DirectoryMonitor 中 String(cString:) 的 SDK 弃用警告，本轮未扩展该无关改动。

安装：/Applications/PathDeck.app 已替换为通过上述验证的 0.3.0（4），PID 25826 完成启动。二进制、图标和 Info.plist 与交付 Release 的 SHA-256 一致，签名校验通过。旧版正常退出后完整备份至 build/backups/PathDeck-0.2.0-3-20261031-122458.app；未强制结束旧版或修改用户设置/剪贴板/Dock。记录见 build/validation/continuity-install.json。

日志入口：continuity-core-tests.log、continuity-xcode-tests.log、continuity-debug-build.log、continuity-debug-package.log、continuity-release-package.log、continuity-release-smoke.json、continuity-performance.json、workspace-producer.json、workspace-consumer.json、workspace-before-restart.json 和 workspace-after-restart.json。

## 复现

```bash
bash scripts/verify.sh
bash scripts/build-app.sh release
python3 scripts/check-workspace.py build/release/PathDeck.app
```

需要图形登录会话的专项模式：`--drag-test`、`--continuity-test`、`--smoke-test`。通过 `open -n -W --stdout <唯一临时目录>/report.json --stderr <唯一临时目录>/stderr.log <app> --args <模式>` 启动，然后验证 JSON 的 passed，不能只检查 open 的退出码。使用临时日志路径避免 LaunchServices 启动阶段访问 Desktop 日志受限。性能模式 `--performance-test` 使用独立生成的 1,000 / 10,000 项目录。

check-workspace.py 自动使用 /private/tmp/PathDeck-Session-* 的私有设置；清理必须同时满足系统临时目录、PathDeck-smoke-* 名称与精确夹具标记。RuntimeContext 只在测试模式接受该环境变量，正常启动仍使用用户设置。测试剪贴板与日志独立于日常使用。

## 修复与验收边界

- 标签恢复追加到上一页之后，确保三个以上标签顺序一致；只向组的第一页追加会改变顺序。
- Native Command 等价键应先走主菜单；测试编辑文本时必须显式选中标签，核对 NSApp.keyWindow.firstResponder，不能向隐藏标签的编辑器写入后用另一个窗口验证命令。
- 文本撤销直接调用 NSTextView.undoManager。向编辑器发送 undo: 可沿响应链返回应用委托；该循环路由已移除。无状态命中测试回调为 nonisolated，不读取 UI 状态。
- 树落点回归按标准 URL writer 寻找实际目标节点，等待目录读取完成；不把异步同步产生的选中行当作固定落点。
- 拖放自动检查执行真实 AppKit data source/drag destination 回调、pasteboard 与实际文件操作，NSDraggingInfo 由测试提供。当前 Computer Use 权限未开放，未进行真实鼠标从 Finder 拖入/拖出的端到端验收；实现使用系统标准本地 file URL 协议。该边界与代码/文件结果验证区分记录。
- 复制/废纸篓撤销、文件重做、跨卷移动、覆盖/目录合并、文件承诺/邮件附件导入继续不提供。不可用撤销会显示失败详情，不降级为删除或覆盖。
- 会话防护上限：16 MB、64 组/512 页、每页 10,000 个选中引用；尚未提交的地址输入草稿和剪切意图不跨重启恢复。运行时自动保存有约一秒捕获窗口，强制结束可能丢失最新界面状态，正常退出会 flush。
- 当前设备为 macOS 27.2 / Apple Silicon。VoiceOver 实际朗读、macOS 14 / Intel、真实外接卷/TCC/云盘异常仍需要对应环境专项验收。性能数据仅代表本机本地生成的热缓存夹具。
