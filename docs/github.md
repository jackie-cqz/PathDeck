# GitHub 仓库

仓库地址：https://github.com/jackie-cqz/PathDeck

仓库名为 PathDeck，默认分支为 main，可见性为 public。main 的最终源码对应本机已验证的 0.3.0（4）。

提交按三个功能阶段整理：v0.1 文件管理核心，v0.2 原生浏览窗口与日常操作，v0.3 撤销、拖放与会话恢复。由于首次导入前没有单独归档各版源码，这三项是从当前源码重新拆分的功能提交，不是当时发布版本的精确历史快照。v0.1 为可独立测试的 Core 包，v0.2 起提供桌面应用。

## 获取与构建

```bash
git clone https://github.com/jackie-cqz/PathDeck.git
cd PathDeck
bash scripts/build-app.sh debug
open build/debug/PathDeck.app
```

仓库可直接克隆，无需登录 GitHub。工程同时提供 PathDeck.xcodeproj 与共享 scheme；工具链、测试命令和功能说明见 README.md。

## 仓库内容

保留 Swift/AppKit 源码、核心测试、Xcode/SwiftPM 工程、脚本、SPEC、产品文档以及 Mint Path 图标源文件和资源。

.gitignore 排除 .build、build（包括应用和旧版备份）、DerivedData、用户 Xcode 状态、环境文件/私钥、临时工作目录及本地 Agent 工作记录。原始验证日志和本机安装记录保留在本机 build/validation；仓库中的 docs/continuity-validation.md 提供本轮验证摘要与复现方式。用户偏好和文件操作日志不存放在项目中。

## 后续提交

使用 Conventional Commits，例如 `feat: add a file operation` 或 `fix: preserve tab selection`。修改源码后运行与改动相应的验证，检查 `git diff` 与 `git status`，再提交和推送。新增文件后使用 `python3 scripts/generate-project.py` 同步 Xcode 工程。

本次只创建源码仓库并推送；未发布安装包 Release，也未额外授予开源许可。
