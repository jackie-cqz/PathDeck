# 正式图标验证

日期：2026-10-30。用户确认 C / Mint Path 浅色方案。本轮将它制作为应用图标，不安装到 /Applications，不修改已有应用实例或用户设置。

## 接入

- 保留 PNG 母图和确认预览于 `assets/branding/`，生成方式与完整提示词见该目录 README。
- `scripts/build-icon.sh` 使用 macOS sips 生成 10 个标准/Retina 槽，再通过 iconutil 生成 `PathDeck/Resources/PathDeck.icns`。
- Info.plist 的 `CFBundleIconFile=PathDeck`，build 从 1 增至 2，Bundle ID 与设置位置保持原值。
- 工程生成器增加 Resources group 和 app 的 PBXResourcesBuildPhase；命令行打包在签名前复制同一 .icns。
- Apple 依据：[CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile)。

## 实测

| 检查 | 结果 |
| --- | --- |
| 母图 | 1254×1254，RGBA，含透明通道 |
| 编码/读取 | 系统 iconutil 成功；NSImage 读出 16–1024 像素的 10 个标准/Retina 表示 |
| Xcode | 原生 Debug BUILD SUCCEEDED，.icns 被复制到 Contents/Resources |
| Debug / Release | 两个常用 .app 均已更新；签名校验通过 |
| 系统图标 | NSWorkspace.icon(forFile:) 对三个构建均返回新图标；导出并检查 128 像素结果，同时检查 32 像素缩小图 |
| 启动回归 | 最终 Release 103 项真实窗口检查全部通过 |
| Core | 本轮未改变业务代码；沿用上一轮 Xcode 58 tests / 9 suites 通过记录，不声称重复执行 |

```bash
bash scripts/build-icon.sh
python3 scripts/generate-project.py --check
xcrun swift -swift-version 6 -module-cache-path .build/NativeModuleCache \
  scripts/check-icon.swift "$PWD/build/debug/PathDeck.app" "$PWD/build/release/PathDeck.app"
```

日志与系统导出的图标在 `build/validation/`：`icon-xcode-build.log`、`icon-pack-debug.log`、`icon-pack-release.log`、`icon-check.log`、`icon-smoke.json` 和 `app-icon-*.png`。

当前 Agent 受限沙盒中，iconutil 将有效 PNG 集合报为 Invalid Iconset；同一集合在允许本机图标服务访问的执行环境中成功转换，没有改系统安全配置。普通 Terminal 可直接运行脚本。图像生成服务只参与源图制作，构建/安装不依赖该服务。
