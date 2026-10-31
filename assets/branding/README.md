# PathDeck 图标

用户选定：**C / Mint Path — Light**，浅薄荷色圆角底、玉绿色 P／路径标记。图像使用内置 imagegen 生成和编辑，未使用 CLI/API fallback。

## 文件

- `reference-light.png`：用户确认的浅色方案预览，仅作设计参考。
- `PathDeck-master.png`：选定的独立透明 PNG 母图，1254×1254，保留生成结果。
- `../../PathDeck/Resources/PathDeck.icns`：应用正式图标，10 个 1x/2x 槽，覆盖 16–1024 像素。
- `../../scripts/build-icon.sh`：从母图通过系统 sips 等比重采样，再由 iconutil 编码；不修改图形或源图。

```bash
bash scripts/build-icon.sh
```

母图或正式图标更新后，运行 `python3 scripts/generate-project.py` 检查工程；Xcode 的 Copy Bundle Resources 复制 .icns，命令行打包也会生成并复制同一资源。构建不需要重新调用图像生成服务。

## 生成提示词记录

输入参考：`reference-light.png`。第一次独立母图生成提示词如下（transparent_background=true）：

> Use the supplied selected PathDeck C / MINT PATH — LIGHT preview as the exact design reference. Produce the final production app-icon master: ONE icon only, square 1:1 canvas, 1024 x 1024 pixels, with true transparent alpha outside the icon. Extract/recreate the large pale mint rounded-square tile with the jade P path monogram. Match the reference's monogram silhouette precisely: a thick rounded upright stem, small integrated rounded-square endpoint at bottom-left, folder-tab-like stepped top, broad rounded P bowl, and the distinctive inward-curving open lower end. Preserve its relative position, spacing, stroke weight, negative space, proportions, jade green color and quiet satin finish. Preserve the very pale mint/off-white tile color and soft rounded corners; restrained mint bevel shading, a clean refined macOS utility icon. Center the tile, about 84 percent of the canvas width and height, leaving even transparent padding around all four sides. All parts of the P lie inside the tile. Keep a nearly front-on view with no perspective tilt. Remove the entire preview layout, both page backgrounds, labels, headings, duplicated icons, small examples and ground shadows. No letters or typography besides the P-shaped SYMBOL itself. No decorative additions, no dark outlines, no changes to the chosen identity. The finished image must be a single isolated icon ready for converting to .icns, not a presentation card.

随后对生成的独立图标使用以下编辑提示词，最终采用此轮输出作为 `PathDeck-master.png`（transparent_background=true）：

> Production-edge cleanup of this single app icon. Preserve the jade P monogram exactly and preserve the pale mint tile, silhouette proportions, positioning and color. CHANGE ONLY THE OUTER TILE EDGE AND TRANSPARENT OUTSIDE: the current outer contour contains ragged white flecks and small stray islands in the transparent padding. Remove every stray pixel, speckle and halo outside the intended rounded-square tile. Give the tile a perfectly smooth precision rounded-square continuous contour, clean antialiasing with NO chalky white rim, no rough mask, no sparkle or grain. Every pixel beyond that smooth contour must be fully transparent, including all padding and corners. No cast shadow or glow outside the tile. Preserve the restrained soft mint shading on the inside of the tile, not an external outline. Keep the SAME one centered icon and transparent margin; square 1:1 master image. No label, no extra preview, no redesign, no new decoration.

生成器实际返回 1254×1254；打包脚本确定性地输出各 macOS 槽尺寸。另一个更平面的试稿未采用。实际 32/128 像素图标及系统解析结果已检查，见 `../../docs/icon-validation.md`。
