# 2026-07-13 桌面导航密度 + 说明文案清理 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-13-claude-desktop-usability-blocker.md`。

基线：`origin/feat/subscription-sync-integration`（HEAD `1394c3a`，即任务单所述
`fabf469` + 任务单文档本身）。分支：`fix/desktop-density-copy-cleanup`，工作树
`C:\Users\15892\projects\finwealth-desktop-density`。

只改 Flutter UI 与前端测试。未修改 `server-rs/**`、`docs/contracts/**`、账本格式、
同步语义或打包安全脚本；未调整 `railWidth` 或断点。

## 1. 提交

| commit | 用途 |
| --- | --- |
| `5c9bb99` | fix(ux): 桌面记录入口分型 + 常驻边界文案清理 + 6 条回归测试 |

最终提交为本回执所在 docs 提交。远端分支：
`origin/fix/desktop-density-copy-cleanup`。未合并 `main`、未创建 Release。

## 2. 桌面记录入口修复（`lib/app/home_shell.dart`）

- 移动端（<960）：保留原 `FloatingActionButton.extended`「记录」FAB，不变。
- 折叠 Rail（960–1359）：改 `IconButton.filled`，44px 逻辑约束（含 tap target
  ≤48px），`tooltip: '记录'`（同时提供 semantics），无常驻文字，不溢出 72px Rail，
  点击仍打开 `showRecordSheet`。
- 扩展 Rail（≥1360）：改紧凑 `FilledButton.icon`（`minimumSize 96×40`、
  `maximumSize 128×44`、`textStyle: AppType.bodyStrong`），显示「记录」文字。
- 稳定 Key：`kDesktopRecordActionKey`（折叠/扩展共用，供尺寸断言）。
- 导航目的地、选中态、hover/焦点与 capabilities 行为未改动（入口始终可点，
  sheet 内条目仍按服务端 capabilities 逐项禁用）。

## 3. 删除的可见文案清单（门控全部保留）

| 文件 | 删除/修改 |
| --- | --- |
| `manual_record_page.dart` | 删底部脚注「记账会生成候选并即时确认入账；不下单、不转账、不连券商。」 |
| `movement_detail_page.dart` | 删「MVP 只支持单分录金额更正；多腿交易更正后续做。」；多腿/不适用记录**直接隐藏**「发起更正」（不再显示禁用按钮+说明）；单腿 + `canPersistPendingProposal` 缺失仍保留禁用态与简短 `kReadOnlyHint` |
| `ai_import_text_page.dart` | 删顶部正文「AI 只根据你输入的文本生成候选记录；不连接券商、不下单、不转账，需你逐条确认后才入账。」 |
| `transfer_page.dart` | 删底部脚注「同额同币种转账；暂不支持跨币种折算。不下单、不连银行。」（币种/金额约束仍由表单校验兜底） |
| `dca_plan_form_page.dart` | 备注字段 hint「只提醒与记录，不下单。」删除；创建 SnackBar 改「定投计划已创建。」 |
| `investment_page.dart` | 「记录已执行」SnackBar 改「已生成待确认记录，见 AI 待确认」（保留结果反馈，去边界括注） |
| `correction_page.dart` | 不适用空态 message 改「仅支持已确认或在途的单分录金额更正。」（去 MVP/diff 实现措辞） |

保留：表单校验错误、写入成功/失败/409 反馈、「只生成待确认候选/确认后才入账」类
结果状态（含订阅页）、capability 只读时的简短恢复提示。`lib` 内其余关键词命中均为
代码注释，不渲染，未动。

## 4. 尺寸/行为回归测试（`test/desktop_density_test.dart`，6 条全绿）

1. 1200px（折叠 Rail）：按 Key 实测宽高均 ≤48px；`find.text('记录')` 为空但
   `find.byTooltip('记录')` 存在；点击打开记录 sheet（出现「手动记账」）；
   `takeException()` 为 null（无 overflow）。
2. 1440px（扩展 Rail）：高 ≤48、宽 ≤128；按钮内找到「记录」文字；无 overflow。
3. 手机 400px：原 FAB 存在且点击可开记录 sheet。
4. ManualRecordPage：找不到「不下单/不连券商/记账会生成候选并即时确认入账」。
5. 多腿 MovementDetailPage：无 MVP/后续做文案，也无「发起更正」。
6. 单腿 MovementDetailPage：「发起更正」存在且（capability 允许时）可用。

## 5. 真实 Windows 截图核验

`flutter build windows`（release）后启动真实 `finwealth.exe`，用 Win32
（GetDpiForWindow + MoveWindow + CopyFromScreen）按窗口 DPI 换算截图。
本机显示缩放 **200%（dpi=192，高于任务单建议的 125%/150%，高 DPI 更严格）**：

- 逻辑 1200×800（物理 2400×1600，折叠 Rail）：记录入口为紧凑金色圆形图标钮，
  无「记录」常驻文字，完全在 72px Rail 内，无溢出/裁切。
- 逻辑 1440×900（物理 2880×1800，扩展 Rail）：紧凑「+ 记录」胶囊钮，高≈40px、
  宽约 96px 逻辑，字级正常，与导航行视觉规格一致。

两张截图已逐张肉眼核验（存于会话临时目录，未入库；按任务单不提交任何 PNG）。

## 6. 门禁实际结果（任务单 §5 全部运行）

- `dart format --output=none --set-exit-if-changed lib test`：通过（0 处需改）。
- `flutter analyze`：No issues found。
- `flutter test`（全量）：**99 passed / 16 skipped / 0 failed**（16 skipped =
  14 golden 预览[仅 PREVIEW_GOLDENS=1] + 2 真实联调测试[仅 smoke 注入 env]）。
- `pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1`：**通过**，
  `OK: Flutter local-server subscription integration smoke passed`（当前源码
  cargo build 起服，订阅全流程 + due-scan 两条联调测试全过）。
- `pwsh -NoProfile -File tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  **通过**，`Windows self-use package readiness passed`（内含 auth client 行为
  测试 10 条全绿）。

无未运行项。工作树干净，无意外未跟踪文件；未提交 golden PNG、账本、auth、日志或
打包二进制。重新打包与分发归 Codex（任务单 §6）。

本回执不含 token、密码、认证文件内容或真实账本数据。
