# 图片平铺视图

交付版本：0.4.0（5）。默认使用带图片缩略图的平铺视图；保留详情列表，可在过滤框旁切换，或按 ⌘1 / ⌘2。两种视图共享同一个目录会话、选择与文件操作控制器。

## 实现

- 原生 NSCollectionView，144 × 158 pt 卡片、100 pt 预览区域、两行文件名；跟随窗口宽度重新排列。文件夹、文档、包与链接保留类型图标，ImageIO 支持的普通图片显示真实缩略图。
- 仅为将要显示的卡片请求缩略图，后台最多两个解码任务，最长边 256 像素，应用方向变换；缓存配置上限为 128 项 / 32 MiB。复用、滚出、切换模式和关闭窗口取消无用任务，重开恢复请求。
- 以路径、文件身份、修改日期和大小标识缓存；回调核对卡片 key，过期或取消结果不会贴到另一文件。解码前后核对文件身份；损坏图片回退类型图标。动图取首帧，非图片不额外生成内容预览。
- 复用现有右键、复制/剪切粘贴、打开、Quick Look、属性、内联重命名、撤销及串行文件任务。Control 多选与原生键盘导航保留；名称编辑仍交给文本编辑器。
- 平铺导出标准 file URL；目录卡片和空白处可接收拖放，沿用原有复制/移动策略和固定身份落点。隐藏的详情表格不作为平铺的选择来源。
- 视图切换保留选择与滚动锚点；每页模式随 WorkspaceSnapshot 保存，默认模式保存在偏好中。旧设置未包含该字段时默认平铺，可与详情页同时恢复。新字段为可选值，兼容已有配置。

## 验证

- SwiftPM / Xcode 核心测试各 74 项通过，包含旧配置兼容、全局选择与每页混合视图序列化。
- 最终 Release 原生检查 208 项通过，新增平铺专项 24 项：真实 PNG 解码与尺寸限制、损坏图片、默认视图、菜单快捷键切换、选择、右键、键盘/可访问性打开动作、真实重命名与撤销、剪贴板、剪切外观、拖动引用与实际文件夹投放结果。
- 独立进程保存/重启恢复 15 项通过；三个标签与另一窗口中同时包含平铺和详情，并核对每页模式。
- 实际窗口浅色/深色视图已导出并核查，产品截图生成器覆盖平铺图片、详情、路径输入、过滤、改名和属性。
- 本机热缓存三次访问中位数：详情 1,000 / 10,000 项为 112.6 / 723.2 ms，过滤 51.2 ms；平铺为 81.9 / 1,266.8 ms，过滤 41.5 ms。两种视图的 50 次快速导航均正确，停止监听后句柄数为 0。每个基准独立串行执行。
- 完整窗口检查必须与 Xcode 测试宿主串行执行；同时运行会争夺激活窗口，导致键盘/预览/拖放前提失败。改为串行后全部通过。

原始结果：build/validation/tiles-core-tests.log、tiles-xcode-tests.log、tiles-release-smoke.json、tiles-native.json、tiles-performance-details.json、tiles-performance-grid.json、workspace-producer.json 和 workspace-consumer.json。

安装：/Applications/PathDeck.app 已更新为 0.4.0（5），正常启动，关键文件哈希与验证过的 Release 一致。0.3.0 原安装完整保存在 build/backups/PathDeck-0.3.0-4-20261031-230405.app，更新期间的候选版本也单独备份；记录见 build/validation/tiles-install.json。未强制终止文件任务或更改用户文件。

## 复现

```bash
bash scripts/swift.sh test
bash scripts/build-app.sh release
# 在图形登录会话中，用独立的临时 stdout/stderr 路径启动 --smoke-test 或 --tile-test
python3 scripts/check-workspace.py build/release/PathDeck.app
python3 scripts/capture-readme.py
```

平铺性能测量使用 `--performance-test --tiles-performance-test`；仅 `--performance-test` 测量详情。夹具为本地生成的 1,000 / 10,000 个文件，三次热缓存访问。图片解码边界另由实际 PNG 检查覆盖，这一列表基准不代表万张照片、冷缓存、网络卷或其他硬件。

Computer Use 未获得原生 UI 控制权限，未进行外部鼠标注入；窗口、菜单、file URL 回调、真实磁盘结果及自身视图导出均在应用进程内验证。VoiceOver 朗读、其他系统版本/Intel、网络/云盘和外接卷仍需对应环境验收。
