# v0.2：窗口、标签与日常交互验证

交付版本：0.2.0（3）。本轮完成 Windows 快捷键、真正的新窗口和原生标签组、右键整理、Quick Look、属性窗口与 Mint 外观。

| 范围 | 实现与验收点 |
| --- | --- |
| Windows 按键 | F5、Alt+方向键、Ctrl+Shift+N、Ctrl+F、Ctrl+N/T/W、Ctrl+Tab / Ctrl+Shift+Tab；保留 Command 基础动作。仅列表接收文件快捷键，文本与 IME 不执行文件操作。 |
| 窗口/标签 | ⌘N 创建新窗口；⌘T 建立真实 NSWindow tab group；各页独立路径、历史、选择与过滤。菜单/目录右键可新页打开，支持关闭、切换、拆出和合并。 |
| 共享文件服务 | 一个应用级队列、任务面板及剪贴板。来源窗口关闭后仍可剪切粘贴；提交复制后所属 browser 可释放，冲突转到仍打开的窗口并保留两份。退出检查全局任务。 |
| 右键 | 打开/预览、编辑、路径/属性三组；空白处指当前目录，单目录有“粘贴到此文件夹”，文件/多选按捕获的引用处理。常用项修改同步到其他窗口。 |
| Quick Look | 实际共享 QLPreviewPanel、URL 数据源与 Objective-C 事件代理；真实空格打开、面板空格事件关闭、恢复列表焦点、多选项目数检查。控制权统一由窗口控制器管理。 |
| 属性 | 单项与多项，真实类型/字节/日期/所有者/POSIX 权限、符号链接目标和错误。后台读取，不递归计算文件夹大小。关闭后释放控制器。 |
| 外观 | SF 系统字体，Mint 辅助符号、路径容器、目录标题与右侧过滤框、交替行背景。30 / 24 pt 密度跨窗口应用并保存；浅/深色及高对比度维持原生可读性。 |

## 结果

- SwiftPM：60 tests / 10 suites 通过；Xcode 原生：60 tests / 10 suites 通过。
- Debug / Release 打包、Info.plist / 工程同步、签名校验通过。
- 最终 Release 完整窗口回归：139 / 139，通过。其中新增交互检查 35 项。
- Release 热缓存三次访问中位数：1,000 项 99.5 ms；10,000 项 646.2 ms；10,000 项名称过滤 47.9 ms。50 次快速导航最终目录正确。
- 当前页监听 29 / 64，停止后 0；图标缓存 2 / 128。此数据是本机生成的本地夹具，不代表冷缓存、网络卷或其他硬件。
- 浅/深色内容视图已导出并检查，属性窗口补齐首次布局的长路径换行和原生背景。
- 已安装并启动 /Applications/PathDeck.app，版本 0.2.0（3）；二进制、图标和 Info.plist 与通过验证的 Release 一致，签名校验通过。旧版备份：/Users/apple/Desktop/work/github-work/PathDeck/build/backups/PathDeck-0.1.0-2-20261031-005147.app。安装记录：build/validation/interaction-install.json。

日志：build/validation/interaction-xcode-tests.log、interaction-core-tests.log、interaction-debug-build.log、interaction-release-build.log、interaction-release-smoke.json、interaction-performance.json。

## 复现

```bash
bash scripts/verify.sh
bash scripts/build-app.sh release
```

窗口检查需图形登录会话。使用 `open -n -W --stdout <临时目录>/report.json --stderr <临时目录>/stderr.log <应用路径> --args --smoke-test`，然后读取 JSON 的 `passed` 字段。仅核查新增功能可使用 `--interaction-test`。`open` 自身的退出码不代表应用内部检查通过；复用日志文件前需要清空，或每次使用唯一临时目录。

测试使用自己的临时目录、配置与私有剪贴板。已有文件操作回归仅将一个测试对象移入系统废纸篓并立即复原，不枚举或清理原有废纸篓。没有全局按键监听，也不申请辅助功能权限。

`PATHDECK_SNAPSHOT_DIR` 可导出本进程自己的 AppKit 内容视图。图片在 docs/images/interaction/，用于核对布局、文字、浅/深色；不读取外部屏幕，图片不包含系统玻璃标题栏的合成效果。

## 修复与边界

- 被遮挡的窗口继续监听，避免后台目录长时间陈旧。切换主窗口不启动抢占式刷新。
- 列表因读取而暂时禁用后，若用户未进入文本编辑，完成时恢复列表焦点。
- Quick Look 控制钩子不能同时放在浏览控制器与窗口控制器；交接可能清空新代理。本轮集中到窗口控制器，并验证真实代理安装与空格事件。
- Release 回归要等待列表恢复可操作再执行复制/粘贴；不把后台刷新时被禁用的操作当成文件引擎失败。
- 测试启动日志使用临时目录，避免 LaunchServices 启动阶段对桌面日志文件的访问失败；不更改系统权限设置。
- 当前只恢复上次一个目录和布局，不保存全部窗口/标签会话。文件操作没有通用撤销；跨卷移动、覆盖/合并及永久删除继续保持原有边界。
- Quick Look 的具体格式支持依赖系统预览器；属性大小不递归。VoiceOver 真实朗读、macOS 14 / Intel、外接卷/TCC 等其他环境专项仍需人工或相应设备验证。部署目标不等于兼容性验收。

实现依据：[Apple QLPreviewPanel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel)、[Apple NSWindowTabGroup](https://developer.apple.com/documentation/appkit/nswindowtabgroup) 及本机 SDK；组件分工见 docs/decisions.md 的 v0.2 补充。

最终竞态回归：新增 queuedRefreshCannotSupersedeNavigation。显式导航在排队时就拥有优先级，后台刷新执行前再次检查，写操作等待最新目录状态；完成后再处理合并刷新。避免尚未启动的新导航被旧目录刷新抢占。
