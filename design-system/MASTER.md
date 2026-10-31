# PathDeck · Native Desktop Design System

平台：Swift + AppKit，文件管理工具；以目录、文件和键盘操作为中心。检索建议的 minimal-modern、清楚边界和可扫描性适用；Web hero、Inter 和 indigo 不适用于本项目。

- 身份：用户选定的浅薄荷底、玉绿色 P。Mint accent 用于目录符号和辅助强调，不替代原生选择/焦点语义。
- 字体：SF 系统字体；目录标题 15 semibold，文件名 13，辅助信息 11–12；路径编辑为 13 等宽。
- 布局：紧凑导航和持久路径入口；第二行左侧目录名、右侧名称过滤；下方侧栏和列表，底部状态/任务。
- 层次：原生 window/control/text 背景、separator 边界；主文字 labelColor，辅助 secondaryLabelColor；浅/深色自动适配。
- 列表：标准 30 px、紧凑 24 px，保留原生选中和表头；图标 18 px，名称可编辑。
- 侧栏：目录/卷/不可用状态有 SF Symbol 和文字，不只依靠颜色。
- 交互：原生窗口标签栏、菜单分组、可见焦点、操作提示；不加无用途动画或不透明模糊装饰。
- 可访问性：动态系统颜色、AX 名称、工具提示、键盘通路；尊重高对比度和减少动态效果设置。
