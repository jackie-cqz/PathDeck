# M1 路径导航原型验证

日期：2026-10-30（Asia/Shanghai）。本轮目标：优先完成“输入路径 → 跳转目录 → 显示真实文件”，并接入 M1 导航原型的主要交互。

## 实现范围

- 绝对路径、`~`、相对路径、本地 file URL 解析；空格/中文/emoji/引号/百分号等按字面处理，不执行 shell。
- 后台有界目录读取、真实文件名/显示名、修改时间、类型与大小。
- 文件夹置顶、自然名称排序、按列排序、选择、多选、双击/Enter 打开。
- 面包屑与路径编辑切换、目录补全、上下键/Tab/Enter/Esc、末尾换行显式修正入口。
- `⌘L`、`Control+L`、`Option+D`、`⌘⇧G` 聚焦路径；导航、刷新与隐藏文件入口。
- 按需目录树、当前位置祖先展开、必要隐藏祖先显露、常用目录固定/取消固定。
- 后退/前进/上一级/刷新；历史保留选择、排序与滚动锚点；失败不新增历史。
- 普通文件路径定位并选中，文件包不当作普通目录遍历；目录链接导航到实际目标，断链保留为列表对象。
- 上下文菜单按空白区域/单项目/多项目捕获 URL，提供已实现的只读操作。
- 明确区分空目录、读取中、权限/不存在错误；错误保留原目录与输入；过期请求不覆盖最新状态。

## 环境与工具链

- macOS 27.2 / arm64，部署目标仍为 macOS 14.0。
- 使用已可用的 Command Line Tools / Apple Swift 6.4，保持 Swift 6 严格并发。
- 开发期间 `/Applications/Xcode.app` 已出现，并成为默认 Developer directory，但命令行报告首次许可未确认。
- 本轮显式设置 `DEVELOPER_DIR=/Library/Developer/CommandLineTools` 运行验证；没有自动接受许可或切换系统默认配置。
- `.xcodeproj` 与共享 scheme 已根据最新文件生成并校验。未声称本轮通过完整 `xcodebuild build/test`。

## 执行命令与结果

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 scripts/generate-project.py
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/verify.sh
```

**结果：退出码 0。**

| 检查 | 结果 |
| --- | --- |
| 工程生成一致性、project/Info.plist、脚本语法 | 通过 |
| Swift Testing | 23 tests / 5 suites / 0 failures；其中参数化测试包含多组特殊路径输入 |
| AppKit Debug 编译与 `.app` 打包 | 通过 |
| 本地 ad-hoc 签名与严格验证 | 通过 |
| 原生窗口交互 | 24 项检查全部通过 |
| 启动检查 stderr 中的 Auto Layout 冲突/异常 | 未发现匹配项 |

日志由验证脚本生成于 `build/validation/`，被 `.gitignore` 排除：`core-tests.log`、`build-app.log`、`smoke-test.json`、`smoke-stderr.log`。

## 自动测试覆盖

除 M0 状态/身份测试外，新增测试覆盖：

- 支持与拒绝的路径语法、普通文件名中的 `file:` 和其他冒号、file URL 只解码一次、补全父目录。
- 实际临时目录读取、元数据、自然排序、隐藏项、普通文件定位与选中身份一致性。
- symlink、断链、目录树不跟随链接、应用包、目录不存在报错。
- 历史刷新不重复、后退后分支、失败不污染历史、选择/排序/滚动锚点恢复。
- 可控延迟的后台读取乱序返回，只允许最后一次导航提交。
- 权限失败使用注入的确定性错误验证状态保留；没有修改用户真实目录权限或系统 TCC 设置。

所有文件夹/文件的创建和删除只发生在本测试拥有的唯一临时目录内。正常浏览路径是只读行为。

## 24 项真实窗口检查

启动检查使用真实 `NSApplication`、窗口、field editor、delegate/命令回调与 `NSTableView`，以专属临时目录作为数据源；不是只检查方法调用次数或伪造行数据。

```text
windowVisible
initialDirectoryRead
menuInstalled
commandRouting
pathFieldFocused
enteredPathNavigates
realFileRendered
pathAndRowsAgree
treeTracksPath
failedPathPreservesRows
failedInputRetained
filePathSelectsFile
fileMenuCapturesFile
blankMenuCapturesDirectory
directoryCompletionVisible
tabAcceptsCompletion
backReturnsToRoot
forwardReturnsToChild
emptyDirectoryIsLoaded
hiddenToggleReadsRealItem
refreshDoesNotAddHistory
addressFitsMinimumSize
canResizeToMinimum
canReopenWindow
```

实际使用 field editor 输入中文/空格路径并执行 Enter，经过地址栏 delegate、导航协调器、真实后台读取后验证表格。补全检查等待 debounce 和后台读取，使用 Down/Tab 接受，再 Enter 跳转。最终报告为 `milestone: M1, passed: true`。

## 限制与后续验证

- 完整 Xcode 的构建与测试需要用户先完成首次许可确认；本轮未代为确认。
- 未取得截图、VoiceOver 或完整人工视觉验收；当前原生交互检查不等同于 XCUITest 全覆盖。
- 真正的 TCC 授权弹窗、外接盘拔出/网络卷卡顿、默认应用打开、应用选择面板、在访达定位的外部界面交互尚未自动化验收。相关入口使用公开系统 API，并有打开失败处理。
- 终端打开入口、常用项显示别名/重排、完整 Windows/Mac 方案设置、列/窗口状态持久化、目录监控、原生类型图标缓存留待后续迭代；对应入口未伪装为已实现。
- 尚未在 macOS 14 或 Intel 真机测试，不把部署目标当兼容性验收。
- M2 新建、复制、移动、重命名、废纸篓及相关写操作尚未实现。当前原型可用于浏览和只读导航。
- 工具链仍有 `CommandLineTools/Developer/...` 搜索路径与 arclite 链接警告；构建、测试和运行通过，没有屏蔽全部警告或修改系统目录。

## 试用

在项目根目录运行：

```bash
open -n build/debug/PathDeck.app
```

按 `⌘L`，输入 `~/Downloads` 或项目绝对路径后按 Enter；输入不存在的路径验证保留原位置，使用左侧树与后退/前进继续浏览。
