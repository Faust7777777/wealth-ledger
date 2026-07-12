# 打包字体来源与许可

本目录字体均为 **SIL Open Font License 1.1（OFL）** 授权，可随源码再分发。
每款字体的完整 OFL 文本见 `licenses/`。

## NotoSansSC-400.ttf — 正文/UI 无衬线（替代原 MiSans）

- 字体：Google **Noto Sans SC**（思源黑体，OFL 1.1）。
- 官方来源：https://github.com/google/fonts/tree/main/ofl/notosanssc
  （许可：https://github.com/google/fonts/blob/main/ofl/notosanssc/OFL.txt）
- 制作：从本机随附的 `NotoSansSC-VF.ttf`（Google Noto，可变字体）定格到
  `wght=400` 再裁子集：

  ```bash
  python -m fontTools.varLib.instancer NotoSansSC-VF.ttf wght=400 -o nssans-400.ttf
  pyftsubset nssans-400.ttf \
    --unicodes="U+0020-007E,U+00A5,U+00B7,U+00D7,U+2013-2014,U+2018-201F,U+2026,U+2033,U+2190-21FF,U+2200-22FF,U+2500-257F,U+25A0-25FF,U+2600-26FF,U+3000-303F,U+FF00-FFEF,U+4E00-9FFF" \
    --output-file=NotoSansSC-400.ttf --no-hinting --desubroutinize
  ```

- 覆盖：ASCII + 常用/次常用汉字（CJK Unified U+4E00–9FFF）+ 中日韩/全角标点 +
  货币/数学/箭头/几何符号（含涨跌 ▲▼、报价 ◐、约等 ≈，自带不靠系统兜底）。
  Ext-B（U+3400–4DBF）等生僻字未含，缺字回退系统字体。
- 许可：`licenses/NotoSansSC-OFL.txt`。

## NotoSerifSC-500.ttf / NotoSerifSC-700.ttf — 各级标题(500)/Hero 大数字(700) 衬线

- 字体：Google **Noto Serif SC**（思源宋体，OFL 1.1）。
- 官方来源：https://github.com/google/fonts/tree/main/ofl/notoserifsc
  （许可：https://github.com/google/fonts/blob/main/ofl/notoserifsc/OFL.txt）
- 制作：从 `NotoSerifSC-VF.ttf` 分别定格 `wght=500` 与 `wght=700`，仅裁 `lib/` 内
  出现的字符 + ASCII + ¥≈ 等符号（标题/Hero 专用，非正文；缺字回退 NotoSansSC）：

  ```bash
  for W in 500 700; do
    python -m fontTools.varLib.instancer NotoSerifSC-VF.ttf wght=$W -o nssc-$W.ttf
    # text-file 为 lib 下所有 .dart 内容的拼接
    pyftsubset nssc-$W.ttf --text-file=<all-lib-dart> \
      --unicodes="U+0020-007E,U+00A5,U+00B7,U+2212,U+2248,U+2026,U+2018-201F,U+3000-303F,U+FF01-FF60,U+2033,U+00D7,U+2192,U+2013-2014" \
      --output-file=NotoSerifSC-$W.ttf --no-hinting --desubroutinize
  done
  ```

- 许可：`licenses/NotoSerifSC-OFL.txt`。

## 说明

- 原 `MiSans.ttf`（取自本机 WPS 字体缓存、无随附许可）已移除，改用上述 OFL 字体。
- 两个 .ttf 均为子集，字体内部 version/name 元数据沿用上游；许可与来源以本文件及
  `licenses/` 为准。
