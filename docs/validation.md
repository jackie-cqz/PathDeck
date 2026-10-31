本轮 v0.2 结果见 [interaction-validation.md](interaction-validation.md)：60 项核心测试、139 项 Release 窗口检查，以及最新性能与安装记录。

# 开发验证记录

当前“日常操作补齐”及后续小修结果见 [daily-use-validation.md](daily-use-validation.md)：Xcode 下 58 项核心测试、103 项窗口检查及 5 项真实 Terminal 检查通过。M3 历史和 Xcode 首次核查见 [m3-validation.md](m3-validation.md)，性能基线见 [performance.md](performance.md)。M1/M2 历史记录见 [m1-validation.md](m1-validation.md)、[m2-validation.md](m2-validation.md)。以下保留 M0 当时的环境与结果。

## M0 历史验证记录

日期：2026-10-30（Asia/Shanghai）。项目尚未初始化 Git，因此本轮以当前工作树记录，不提供虚构的 commit hash。

## 环境实测

| 项目 | 结果 |
| --- | --- |
| 系统 | macOS 27.2，Build 26B123 |
| 体系结构 | arm64 / Apple Silicon |
| Swift | Apple Swift 6.4，`swiftlang-6.4.0.34.1 clang-2100.3.34.1` |
| Swift target | `arm64-apple-macosx27.2.0` |
| Developer directory | `/Library/Developer/CommandLineTools` |
| SDK | Command Line Tools 中的 macOS 27.0 SDK（默认 `MacOSX.sdk`） |
| 应用部署目标 | macOS 14.0 |
| 完整 Xcode | 未安装；`xcodebuild -version` 提示需要完整 Xcode |
| 外部依赖 | 无 |

## 验证结果

| 检查 | 状态 | 实际结果 |
| --- | --- | --- |
| 工程生成一致性 | 通过 | `python3 scripts/generate-project.py --check` |
| Xcode project / Info.plist 语法 | 通过 | `plutil -lint` 两个文件均 OK |
| 脚本语法 | 通过 | `bash -n` 检查三个 shell 脚本 |
| SwiftPM Debug 编译 | 通过 | 编译真实 AppKit 源码，Swift 6 语言模式 |
| Core tests | 通过 | Swift Testing：2 suites、7 tests、0 failures |
| `.app` 打包 | 通过 | `build/debug/PathDeck.app`，Info.plist 校验通过 |
| 本地签名 | 通过 | ad-hoc 签名，`codesign --verify --strict` 通过 |
| 动态链接依赖 | 通过 | `otool -L` 只包含系统框架/库，没有指向 `.build` 或临时 Core framework 的依赖 |
| 真实窗口 smoke check | 通过 | 11 项检查均为 true，程序退出码 0 |
| 非 SWIFT_PACKAGE 编译分支 | 通过 | 直接 swiftc 编译 app 全部源码，测试的 `@testable import PathDeck` 分支 typecheck 通过 |
| 完整 `xcodebuild build/test` | 未验证 | 当前仅 Command Line Tools，不能将其他编译路径的结果当作 Xcode 验证 |
| XCUITest / VoiceOver / 外观人工检查 | 未验证 | M0 未建立完整 UI 测试；本轮 native UI 自动化工具报告没有 Computer Use 权限，未取得截图 |
| macOS 14 / Intel 兼容性 | 未验证 | 只有部署目标设置，未在相应真机运行 |
| M1 文件浏览 / M2 写操作 | 不适用 | 本轮只实现 M0，不以模拟数据宣称这些功能通过 |

## 已执行命令

项目根目录：

```bash
python3 scripts/generate-project.py --check
plutil -lint PathDeck.xcodeproj/project.pbxproj PathDeck/Resources/Info.plist
bash -n scripts/swift.sh scripts/build-app.sh scripts/verify.sh
bash scripts/swift.sh test
bash scripts/build-app.sh debug
codesign --verify --strict build/debug/PathDeck.app
otool -L build/debug/PathDeck.app/Contents/MacOS/PathDeck
build/debug/PathDeck.app/Contents/MacOS/PathDeck --smoke-test
```

已完成一次 `bash scripts/verify.sh` 全链路通过。此后为补充最小尺寸缩放和窗口重新显示检查，修改 UI 布局与 smoke check，再次构建 Debug app 并运行最终 11 项 smoke check 通过。Core 模型与测试未发生业务变更。

上述命令在 Agent 沙盒内需要执行器允许 SwiftPM 的子沙盒初始化；没有修改系统安全设置。命令的成功退出不表示 Xcode 已安装。

当前工作树的验证日志与最终启动报告存于：

```text
build/validation/core-tests.log
build/validation/build-app.log
build/validation/smoke-test.json
build/validation/smoke-stderr.log
```

这些是本地生成物，被 `.gitignore` 排除。若需要重新生成与当前代码完全一致的全套日志，运行 `bash scripts/verify.sh`。

## 7 项基础测试

1. 未读取目录状态不会被当成空目录加载成功。
2. A/B/C 请求乱序返回时，只有最新结果可提交。
3. 导航失败保留原目录与原文件行。
4. 过期失败不会覆盖新导航的成功状态。
5. 请求不能跨窗口提交，也不能重复提交。
6. 同一路径在 Favorites 与 Locations 下具有不同的树行身份。
7. 本地化显示名称不会修改真实名称或路径。

这些是状态/身份模型测试，不代表磁盘枚举和路径解析已实现。

## 最终启动报告

```json
{
  "milestone": "M0",
  "passed": true,
  "checks": {
    "addressFitsMinimumSize": true,
    "addressHasLayout": true,
    "addressShowsHome": true,
    "canReopenWindow": true,
    "canResizeToMinimum": true,
    "contentController": true,
    "fourFileColumns": true,
    "menuInstalled": true,
    "minimumSize": true,
    "notPretendingToReadFiles": true,
    "windowVisible": true
  }
}
```

## 已修复与保留限制

- 修复地址栏按钮组宽度没有约束导致路径输入区域被压缩的问题。
- 修复代码创建的零尺寸 content view 把初始窗口缩至最小尺寸的问题。
- 修复侧栏 preferredContentSize 高度影响窗口最小高度的问题，启动检查覆盖缩小与恢复。
- 当前工具链不含 XCTest。使用自带的 Swift Testing；脚本显式定位其宏插件，绕开默认 swiftbuild 后端的漏载问题。
- 工具链生成了不存在的 `CommandLineTools/Developer/...` 链接搜索路径警告；当前构建、测试与启动成功，未通过创建系统目录或屏蔽全部警告来掩盖问题。
- 无完整 Xcode、无截图/人工视觉验收、无较低系统版本或 Intel 真机验证。安装 Xcode 后应补跑 README 中的 build/test 命令。
- 侧栏目前为布局展示，路径栏只读可选择，导航按钮禁用；文件内容明确未读取。M1 按 SPEC 接入真实导航。
