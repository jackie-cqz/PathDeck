# 日常操作补齐：使用与验证

日期：2026-10-30。用户同意继续“终端入口＋常用目录管理＋当前目录名称过滤”。本轮使用已可用的 Xcode 27.2 / Swift 6.4.2，未增加外部依赖、未改变全局权限或签名账户。

## 实现范围

| 功能 | 行为 |
| --- | --- |
| Terminal | 空白处作用于当前目录，单个目录作用于该目录，树节点作用于节点；多选/普通文件不增加含糊入口。“前往”菜单另提供当前目录入口 |
| 终端路径 | 先在后台检查可访问的普通目录，再通过 NSWorkspace 向系统 Terminal 传递 URL。没有 shell、AppleScript 源码或路径字符串命令拼接；失效目标报错，可继续复制路径 |
| 常用目录 | 右键编辑显示名称（留空恢复原名）、上移/下移、重新定位、检查可用性、取消固定。上下边界禁用；重新定位保留别名/顺序，拒绝重复固定目标 |
| 配置兼容 | 原有 favorites 路径数组保留，新增可选 favoriteNames 字典；旧 JSON 不缺字段报错。名称最多 120 字符，孤立别名在保存时整理；更改仅作用于配置 |
| 可用性 | 后台检查常用项目，失败显示文字“不可用”，禁用该常用项终端入口，保留重新定位/移除；启动、激活、相关失效事件和菜单可重新检查 |
| 过滤 | ⌘F 或过滤框；当前目录名称子串匹配，支持大小写/重音差异、中文、emoji、字面括号等；不按正则或通配符解释，不递归 |
| 选择与写操作 | 不可见选择立即清除，右键操作使用可见行引用。状态显示匹配数/总数；0 匹配与空目录区分。新建后清除过滤并显示名称编辑 |
| 查询生命周期 | 刷新、排序保留查询；跳转其他目录或显式定位文件清除；Esc 清除并聚焦列表，Enter/向下键返回列表。输入法组合态不触发过滤或被后台绘制覆盖 |

系统 API 依据：[Apple NSWorkspace open(_:withApplicationAt:configuration:)](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))。该 API 的返回只表示打开完成；本轮另外核查 shell cwd，未将“Terminal 已启动”当作目录正确的证据。

## 验证结果

- 最新 Xcode 原生测试：**58 tests / 9 suites，全通过**（含后续 Home 路径小修）。
- 最新真实 AppKit 窗口检查：**103 项，全通过**。含过滤快捷键/文本编辑、不可见选择清除、过滤后复制范围、外部刷新、新建显示、菜单目录目标、真实别名保存 sheet、移动菜单、失效标记、重新定位、配置重新加载和 VS Code 六项菜单检查。
- Terminal：**5 项，全通过**。两个目录分别包含中文、emoji、引号、`;$(...)`、`&`，以及换行/组合字符；实际 shell cwd 均与唯一夹具目录相同。另检查路径没有被当作命令执行、普通文件与缺失目录被拒绝。
- Terminal 验收器读取进程 cwd，并同时校验进程为 shell、父链属于本次打开的 Terminal。特权 login 父进程用只读 KERN_PROC_PID 后备查询。结束时只向匹配唯一夹具 cwd 的测试 shell 发 HUP，不终止共享 Terminal 或已有会话；窗口是否保留“进程已完成”受用户 Terminal 设置影响。
- 新测试全部使用唯一临时夹具/私有剪贴板，保持既有 M1–M3 回归；不改动用户真实文件或全局偏好。

```bash
xcodebuild -project PathDeck.xcodeproj -scheme PathDeck \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/XcodeDerivedData test

build/XcodeDerivedData/Build/Products/Debug/PathDeck.app/Contents/MacOS/PathDeck --smoke-test

# 单独 opt-in，会打开测试 Terminal 会话并检查真实 cwd。
build/XcodeDerivedData/Build/Products/Debug/PathDeck.app/Contents/MacOS/PathDeck --terminal-test
```

日志在 `build/validation/`：`daily-test.log`、`daily-smoke.json`、`terminal-test.json`、`terminal-test-stderr.log`、`daily-release-build.log`、`daily-performance.json`、`daily-pack-debug.log`、`daily-pack-release.log`、`daily-release-smoke.json`。

## 性能

本机 Mac16,12 / 24 GiB，macOS 27.2，APFS SSD；Xcode 原生 Release 构建。方法沿用 [performance.md](performance.md)，新生成真实文件、OS 热缓存；不代表冷启动、网络卷或云盘。

| 场景 | 本轮结果 |
| --- | --- |
| 1,000 项三次显示 | 113.3 / 97.5 / 86.9 ms，中位数 97.5 ms |
| 10,000 项三次显示 | 647.4 / 637.2 / 636.4 ms，中位数 637.2 ms |
| 10,000 项名称过滤＋布局显示 | 49.6 ms；10 个匹配，完整快照仍为 10,000 项 |
| 主线程心跳最大间隔 | 97.2 ms，包含原生绘制/布局与过滤，不等同帧率保证 |
| 有限导航/滚动前后物理内存 | 70.0 → 82.4 MiB，不等同长期泄漏结论 |
| 监听数量 / 停止后 | 31 / 0；图标缓存 2 / 128 |
| 快速连续导航 50 次 | 最终目录和行数正确 |

## 保留边界

这轮未添加 Quick Look、拖放、标签页、双栏、递归/全盘搜索、跨卷移动、覆盖/合并或文件撤销。过滤不是搜索索引。可用性检查失败统一显示“不可用”，不会断言文件已被删除。真实 VoiceOver 朗读、不同 Terminal shell/profile、macOS 14/Intel、真实 TCC 和外接卷异常仍沿用 M3 人工验收待项。

## 后续小修与 VS Code 入口

- `~/Desktop` 已支持；补充兼容全角 `～/Desktop` 和独立 `～`。仅处理 Home 前缀，不全局规范化文件名；真实 `～` 目录使用 `./～/` 或绝对路径。新增测试在唯一临时 Home/Desktop 下验证两种输入均读取同一真实文件，另测补全和字面路径保持。
- “用 VS Code 打开”通过 `com.microsoft.VSCode` 查找应用，向 NSWorkspace 传递本地 URL。文件、文件夹、空白、多选和树节点目标分别验证，并模拟未安装分支的明确禁用；无需 code CLI 或 shell 命令。
- 本机已安装 Visual Studio Code。额外实际向其发送项目 SPEC.md 的文件 URL，返回 `com.microsoft.VSCode`，调用成功，记录在 `build/validation/vscode-open.log`；未通过自动化读取 VS Code 活动编辑器内容，不据此宣称其所有配置/扩展均已验收。
- 整体回归暴露了可用性检查被新任务替换时，等待旧任务会过早返回的问题；等待方法现跟踪最新 generation。
- 最新日志：`home-path-test.log`、`home-path-smoke.json`、`vscode-test.log`、`vscode-smoke.json` 和 `vscode-pack-*.log`。两个常用 Debug/Release .app 均已更新。
