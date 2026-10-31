# M2 文件操作验证

日期：2026-10-30（Asia/Shanghai）。范围：新建、重命名、复制、剪切粘贴和系统废纸篓；保留 M1 导航行为。

## 实际结果

**44 项自动测试 / 6 个 suites、42 项真实窗口检查全部通过；完整验证命令退出码 0。**

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 scripts/generate-project.py
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/verify.sh
```

遵照用户“暂时先不用 Xcode”的要求，本轮没有运行 Xcode 工程构建或测试。环境仍为 macOS 27.2 / arm64、Apple Swift 6.4 / Command Line Tools；部署目标 macOS 14.0。Python 工程生成一致性、plist、shell 语法、Debug 编译、打包和本地 ad-hoc 签名校验通过。

日志：`build/validation/core-tests.log`、`build-app.log`、`smoke-test.json`、`smoke-stderr.log`；最终整轮输出另存 `final-run.log`。均为本地生成物，被 gitignore 排除。

## 已实现与验证

| 功能 | 验证 |
| --- | --- |
| 新建文件夹 / 空 UTF-8 文本 | 真实文件创建；冲突生成递增名称；非法名称不写磁盘 |
| 新建后编辑 / 重命名 | 原生内联编辑，Enter 提交、Esc 取消，大小写重命名保持对象身份 |
| 同名保护 | 跳过 / 保留两份 / 取消剩余任务；目录不合并；点号目录名不误当扩展名 |
| 复制 | 文件内容与扩展属性、目录、应用包、symlink；源对象保留；暂存成功后不覆盖提交 |
| 剪切粘贴 | 剪切时无移动；粘贴保持同一物理对象；完成清除待移动意图 |
| 剪贴板变化 / 部分失败 | 替换剪贴板取消淡化；仅移除成功移动项，失败项保留意图 |
| 同卷移动 / 跨卷拒绝 | 同卷身份保持；使用 /dev 的不同文件系统身份验证跨卷在写入前拒绝，不向 /dev 写入 |
| 废纸篓 | 实际系统 API 将唯一夹具移入废纸篓，随后移回；失败不永久删除；链接操作不影响目标内容 |
| 队列、取消与失败 | 排队取消、复制完成后提交前取消、迟到同名目标、模拟 ENOSPC、源/目标替换、部分批次失败 |
| 身份边界 | 同名替换对象被拒绝；不能把重命名变成跨目录移动；不能放入自身/后代；现有硬链接冲突回退不覆盖 |
| 任务记录 | 未完成日志恢复为待核实，不自动创建、移动或删除任何源对象 |
| 窗口与焦点 | 任务窗口打开；文本编辑 Delete 不触发文件动作；M1 导航、补全与窗口生命周期保留 |

自动测试中的文件变更仅发生在唯一临时夹具。废纸篓失败与部分故障通过注入验证；“真实磁盘满”没有实际制造。跨卷拒绝测试只读取系统 /dev 元数据，用于确认卷身份不同；源文件在临时夹具中且保持原位。

## 42 项窗口检查

前 24 项为 M1 导航/菜单/窗口回归；新增检查覆盖：

```text
newFolderCreated
newFolderStartsInlineRename
inlineRenameCommits
newTextFileIsEmpty
textDeleteDoesNotTouchFiles
escapeCancelsRename
copyWritesStandardFileURLs
pasteCopiesRealContents
keepBothCreatesNewName
cutDoesNotMoveEarly
cutPasteMovesSameObject
completedCutClearsIntent
clipboardReplacementClearsCut
systemTrashMovesOnlyFixture
trashFixtureRestored
partialCutRetainsOnlyFailedIntent
failedCutReplacementPreserved
taskWindowCanOpen
```

检查使用真实 NSApplication、NSTextView field editor、table 和后台操作引擎；新建、重命名、复制、移动均核对真实文件系统结果。冲突选择与废纸篓确认在 smoke check 中注入确定性答案，因此不把这些对话框的人工交互声称为已自动化覆盖。

### 夹具隔离

- 剪贴板使用唯一命名的私有 NSPasteboard，不读取或覆盖用户通用剪贴板内容。
- 废纸篓仅处理该轮自己的一个唯一文件，用返回的确切结果 URL 移回临时目录后统一清理。
- 不枚举、不清空、不删除已有废纸篓项目。
- 不修改用户目录权限、全局快捷键、系统默认应用或系统工具链配置。

## 当前行为与限制

- 首版只支持普通本地对象与已验证的卷能力，云文件提供程序位置、未下载云文件、网络卷和特殊设备对象拒绝写操作。
- 复制跨卷采用系统复制能力，但尚未在真实外接盘上完成兼容性矩阵；未验证的元数据能力不作无损承诺。
- 移动限同卷；不覆盖替换、目录合并、永久删除或提供通用撤销。
- 取消不保证立即中断同步系统复制；等待当前项目返回，在提交边界重新检查。已完成项目保留。
- 失败/取消可能保留未提交的临时副本，任务窗口列出位置，重启可核查；不自动递归清理。
- 剪切意图仅保证 PathDeck 内识别，其他应用接收标准 URL 时按复制处理。Finder 与用户真实通用剪贴板的人工往返尚未验收。
- 真实磁盘拔出、网络挂起、所有文件提供程序、TCC 对话框、人工退出等待/取消流程、VoiceOver、Intel 与 macOS 14 真机仍需后续验证。
- 工具链保留了 CommandLineTools/Developer 链接搜索路径警告；私有剪贴板读取 file URL 时有 `sandbox_extension_consume` 警告，相关复制/移动断言均通过。没有通过关闭系统安全机制掩盖警告。
- 未提供截图或声称完成视觉/可访问性全面验收。任务记录清理策略、目录监听、窗口/列设置恢复、大目录性能属于 M3 后续工作。

## 使用

```bash
open -n build/debug/PathDeck.app
```

空白处右键新建；F2 重命名；⌘C/⌘X/⌘V 复制、剪切、粘贴；⌘Backspace 移入废纸篓。Windows 习惯下列表还支持 Control+C/X/V、多选、Enter 打开与 Forward Delete。输入框保持文本编辑语义。右下角“文件任务”查看结果和取消请求。
