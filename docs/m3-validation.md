# M3 验证记录

日期：2026-10-30，Asia/Shanghai。M3 功能已实现，人工专项验收仍按下表保留。项目未初始化 Git，不提供虚构 commit。构建全程显式使用 `/Library/Developer/CommandLineTools`，未运行 Xcode。

## 实现与验证

| 项目 | 已实现行为与证据 |
| --- | --- |
| 目录监听 | 专用后台队列打开/关闭 vnode 描述符；监听当前目录、最多 24 个展开目录与 32 个可见文件，总上限 64。200 ms 合并事件；当前目录切换立即更新订阅，滚动变化延迟 80 ms 合并 |
| 外部修改 | 实际夹具新增/删除文件、外部改名、原地追加文件内容均反映到真实列表；新增检查要求 1 秒内反映 |
| 选择与滚动 | 刷新按捕获的文件身份匹配选择/锚点，路径被替换不会错误选中新对象；同名替换和外部改名有真实文件测试 |
| 输入与编辑 | 路径草稿不被后台刷新覆盖；内联重命名期间延后刷新，结束后补刷；显式前往另一个目录清理残留编辑状态；失败输入仍可继续编辑 |
| 目录异常 | 当前目录被外部改名时按 FD 查询并验证原身份，跟随新位置；删除后显示失败并禁用写操作，可重新选择目录恢复 |
| 设置 | JSON 原子写入；350 ms 合并保存，关闭窗口捕获状态，退出时 flush。损坏/未知版本备份后恢复默认，数值/路径/列表长度有边界整理 |
| 恢复 | 新控制器重新加载磁盘配置，实际创建新窗口验证目录、排序、隐藏项、列宽/顺序/隐藏、窗口大小、侧栏宽度、常用目录、按键习惯；另测失效保存位置返回 Home |
| 资源 | 列表单元格复用；文件类型图标缓存最多 128；历史/最近目录各 50；保存的展开路径 128。折叠/重建树时取消旧加载；窗口关闭停止监听和剪贴板轮询，重新显示恢复监听 |
| 性能 | Release 真实 1,000/10,000 个文件列表显示、50 次快速导航、滚动与资源检查；方法和数值见 [performance.md](performance.md) |
| 可访问性 | 路径、树、列表、列内容、按钮有名称/说明；“待移动”有文字值；保留原生选中/层级/菜单语义。真实窗口验证 Tab 到任务入口、Shift+Tab 返回列表；方向键/Enter/F2 与原有路径输入流程继续回归 |
| 外观 | 实际窗口切换 Aqua、Dark Aqua、两种高对比度外观并验证布局；自身内容视图导出后检查浅/深色显示。使用动态系统颜色，无自定义动画 |

## 执行结果

- Swift Testing：**52 tests / 8 suites，全部通过**。
- 真实 AppKit 窗口：**78 项检查，全部通过**，包含此前 M1/M2 的导航、剪贴板、实际文件操作与系统废纸篓检查。
- 工程生成一致性、project/Info.plist、shell 语法、Debug/Release 打包和 ad-hoc 签名校验通过。
- `check-native.py` 直接编译不带 `SWIFT_PACKAGE` 的 app 模块，共享测试按 `@testable import PathDeck` typecheck 通过；它不是 Xcode build/test。
- Release benchmark：显示的行数与真实文件数一致，性能目标通过，停止后的订阅为 0。

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/verify.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/performance.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 scripts/check-native.py
```

可选内容视图导出（仅应用自己绘制的 view，不读取其他窗口或截取屏幕）：

```bash
PATHDECK_SNAPSHOT_DIR="$PWD/docs/images" \
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/verify.sh
```

最终日志位于 `build/validation/`：`core-tests.log`、`smoke-test.json`、`smoke-stderr.log`、`m3-full-verify.log`、`performance.json`、`performance-environment.txt`、`release-build.log`、`native-check.log`。工具链仍有不存在的 CLT 链接搜索目录警告；直接原生分支编译另提示 C 字符数组转 String 的弃用警告。构建、测试与签名校验成功，没有修改系统目录掩盖警告。

## 原生内容视图

来自实际运行的 Debug 窗口和唯一临时夹具，经 AppKit `cacheDisplay` 导出；不含系统标题栏/菜单，不是设计稿。浅色与深色各导出了导航、文件新建/内联编辑、路径失败三个场景。

| 场景 | 浅色 | 深色 |
| --- | --- | --- |
| 路径与真实文件 | [浏览](images/pathdeck-m3-browse-light.png) | [浏览](images/pathdeck-m3-browse-dark.png) |
| 新建与名称编辑 | [文件操作](images/pathdeck-m3-files-light.png) | [文件操作](images/pathdeck-m3-files-dark.png) |
| 路径失败与保留内容 | [错误](images/pathdeck-m3-error-light.png) | [错误](images/pathdeck-m3-error-dark.png) |

## 仍需人工/其他环境验收

| 项目 | 当前边界与补验方式 |
| --- | --- |
| VoiceOver | 已提供原生语义和 AX 属性，未实际启用 VoiceOver 听读。需要验证路径、树层级/展开、文件名、选中状态、待移动、菜单与错误的朗读顺序 |
| 完整键盘体验 | 已自动验证关键焦点跳转和文本编辑路由；仍需实际键盘遍历整个窗口、IME、长文件名/emoji，以及启用 VoiceOver 后的导航 |
| 高对比度/减少动态效果 | 检查了 NSAppearance 和动态系统颜色；未改动用户全局辅助功能偏好，也未宣称人工视觉效果已全部验收 |
| 真实权限 | 确定性读取拒绝保留位置并说明权限；未修改用户 TCC/ACL。需实际拒绝桌面/文稿访问后，在“系统设置 → 隐私与安全性 → 文件与文件夹”恢复，再刷新验证 |
| 窗口重启 | 用新配置控制器和新原生窗口验证磁盘恢复；不是跨进程重启自动化。仍需实际退出/重开、换显示器/分辨率和强制退出后恢复 |
| 真机卷异常 | 未拔出用户外接磁盘；未填满真实磁盘。网络卷、云盘占位文件、外接卷断连与跨卷复制仍需实测，既有故障注入不代表这些真机已通过 |
| 性能长跑 | 有限次数导航、窗口重开和句柄/缓存上限检查不等同长时间泄漏检测；任务记录和失败临时副本仍不自动清理 |
| 冷启动与兼容性 | 未清空 OS 缓存或重启机器；仅 macOS 27.2 arm64 实测。macOS 14、Intel、完整 Xcode 工程和 XCUITest 仍未验证 |

首版继续不支持跨卷移动、覆盖/合并同名内容、通用文件操作撤销或永久删除；这些不因 M3 放开。

## 补充：Xcode 核查

2026-10-30，用户随后要求检查 Xcode 是否已经可用。本节更新前文中“完整 Xcode 未验证”这一项，其余人工验收边界保留。

- 默认 Developer directory：`/Applications/Xcode.app/Contents/Developer`，未改动全局选择。
- Xcode **27.2 / 27B52**，Swift **6.4.2**，macOS **27.2 SDK**。
- `xcodebuild -checkFirstLaunchStatus` 退出码 0，首次设置已完成，无需再次接受许可或安装组件。
- PathDeck scheme 的原生 Debug **BUILD SUCCEEDED**。
- 原生测试 **TEST SUCCEEDED**：52 tests / 8 suites 全部通过。
- Xcode 构建的实际 app 以 `--smoke-test` 启动，隔离夹具下 78 项窗口检查全部通过。

```bash
xcodebuild -project PathDeck.xcodeproj -scheme PathDeck \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/XcodeDerivedData build

xcodebuild -project PathDeck.xcodeproj -scheme PathDeck \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/XcodeDerivedData test
```

记录位于 `build/validation/xcode-build.log`、`xcode-test.log`、`xcode-smoke.json`、`xcode-smoke-stderr.log` 和 `XcodeTests-20261030.xcresult`。存在 String(cString:) 弃用及未使用 AppIntents 元数据提取的提示，均未阻止构建或测试。未修改业务源码或签名账户配置。
