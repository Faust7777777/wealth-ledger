# 插画源稿

打包用的透明 PNG 在上一级 `assets/illustrations/`；这里保留生成源稿，便于日后重抠/重制。

## investment-empty-state.raw.png

- 投资空态徽记（金线圆 + 同心弧）的**原始生成稿**：1254×1254，RGB，纯绿幕背景 `#00E000`，无 alpha。
- 由 Codex `image_gen__imagegen` 生成（严格约束：细线、香槟金 `#CBB079`、无俗套、居中方形徽记）。
- 打包版 `../investment-empty-state.png`（512×415，RGBA 透明）＝对本源稿做绿幕抠除 + 收边 + 缩放：

  ```bash
  magick investment-empty-state.raw.png \
    -fuzz 30% -transparent 'srgb(0,224,0)' -fuzz 22% -transparent 'srgb(15,237,20)' \
    -trim +repage -bordercolor none -border 56 -resize 512x512 \
    ../investment-empty-state.png
  ```

## 说明

- 首屏净值空态 `../net-worth-empty-state.png`（日出+水波徽记）的绿幕源稿未随仓库归档，
  留在生成环境；如需重制按同法重新生成 + 抠除即可。
