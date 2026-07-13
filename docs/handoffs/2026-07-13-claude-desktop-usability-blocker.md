# 2026-07-13 Claude 前端任务：桌面导航密度与说明文案清理

## 1. 优先级与基线

- 优先级：P0，可用性阻塞。
- 新分支应从 `origin/feat/subscription-sync-integration@fabf469` 派生。
- 建议分支：`fix/desktop-density-copy-cleanup`。
- 不要从旧 `frontend-skeleton` 或单独的 due-scan 分支继续。
- 本轮只修改 Flutter UI 与前端测试；不要修改 `server-rs/**`、
  `docs/contracts/**`、账本格式、同步语义或打包安全脚本。

当前 Windows 自用包暂不作为可交付版本，修复并重新打包前不要分发。

## 2. 用户可见问题

### 2.1 折叠侧栏的“记录”按钮过大

用户截图处于桌面折叠 NavigationRail。代码在宽度 960–1359 时设置
`extendedRail=false`，但 `leading` 仍使用 `FloatingActionButton.extended`。
高 DPI 下，带“+ 记录”文字的横向按钮明显超出折叠 Rail 的视觉规格。

相关代码：

- `lib/app/home_shell.dart`
- `lib/theme/app_theme.dart`
- `lib/theme/app_dimens.dart`（只在确有必要时调整；不要先扩大 Rail 掩盖问题）

修复要求：

1. 移动端继续保留当前可发现的“记录” FAB。
2. 折叠 Rail 使用图标型紧凑操作，不显示常驻“记录”文字：
   - 逻辑尺寸 40–48 px；
   - 必须有 tooltip/semantics：`记录`；
   - 不得溢出 72 px Rail；
   - 点击仍打开原 `showRecordSheet`。
3. 扩展 Rail 可显示“记录”文字，但必须是紧凑桌面按钮：
   - 高度不超过 48 px；
   - 宽度不超过 128 px；
   - 使用 `bodyStrong` 或同等级文本，不使用当前偏大的 `titleM`；
   - 不得通过增大 `railWidth` 掩盖控件规格问题。
4. 保持导航目的地、选中态、键盘焦点、hover 和 capabilities 行为不变。

## 3. 清理常驻解释性文案

用户明确要求主操作页面不要常驻展示产品边界、实现状态或 “MVP/后续做” 说明。
删除文案不等于放开能力，所有服务端和 capability 门控必须保留。

P0 必须删除：

1. `lib/features/manual_record_page.dart`

```text
记账会生成候选并即时确认入账；不下单、不转账、不连券商。
```

2. `lib/features/movement_detail_page.dart`

```text
MVP 只支持单分录金额更正；多腿交易更正后续做。
```

多腿记录不能更正时，不要展示一个禁用动作再配实现说明；直接隐藏不适用的
“发起更正”操作。单腿记录和 capability 允许时仍正常展示该操作。

同轮审查以下静态说明，只删除常驻正文/表单脚注，不删除必要的验证错误、操作结果、
确认对话框或 tooltip：

- `lib/features/ai_import_text_page.dart` 的长篇产品边界正文；
- `lib/features/transfer_page.dart` 底部“不下单/不连银行”脚注；
- `lib/features/dca_plan_form_page.dart` 的常驻“不下单”提示；
- 其他包含 `MVP`、`后续做`、`不下单`、`不转账`、`不连券商` 的静态页面文案。

保留以下内容：

- 表单字段说明和输入校验；
- 写入成功/失败/冲突等即时反馈；
- “只生成待确认候选、尚未入账”这类会影响用户决策的结果状态；
- capability 不可用时必要且简短的恢复提示。

## 4. 必须新增的自动回归信号

现有 preview golden 被 `.gitignore`，且默认测试跳过，不能单独作为 P0 门禁。

在 widget 测试中给桌面记录操作增加稳定 Key，并至少覆盖：

1. 1200 px 窗口（折叠 Rail）：
   - 按钮宽高均不超过 48 px；
   - 找不到常驻文字 `记录`，但 tooltip/semantics 存在；
   - 点击会打开记录 sheet；
   - 无 overflow exception。
2. 1440 px 窗口（扩展 Rail）：
   - 高度不超过 48 px、宽度不超过 128 px；
   - 显示 `记录`；
   - 无 overflow exception。
3. 手机宽度：原 FAB 仍可见且可打开记录 sheet。
4. ManualRecordPage 不再找到上述边界脚注。
5. 多腿 MovementDetailPage 不显示 MVP 文案，也不显示不适用的更正操作。
6. 单腿 MovementDetailPage 的更正操作仍存在。

建议再以 125%/150% Windows 显示缩放人工验证 1200–1440 宽窗口。可以重生成 ignored
preview golden 辅助肉眼检查，但不能用“更新 golden 后通过”代替尺寸断言。

## 5. 完成门禁

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
pwsh -NoProfile -File tools\frontend_local_server_smoke.ps1
pwsh -NoProfile -File tools\package_release.ps1 -WindowsOnly -CheckReadinessOnly
```

完成后新增回执：

`docs/handoffs/2026-07-13-desktop-usability-cleanup-done.md`

回执必须包含：最终提交、尺寸测试结果、删除的可见文案清单、真实 Windows 截图核验、
全量测试结果和远端分支。不要提交 golden PNG、账本、auth、日志或打包二进制。

## 6. 预计工时

- 桌面/移动记录入口分型与尺寸测试：2–3 小时。
- 静态解释文案清理及页面回归：1–2 小时。
- 全量测试、真实联调、Windows 缩放截图和回执：2–3 小时。

前端合计约 5–8 小时。前端推送后，Codex 合并、完整门禁和重新打包约 2–3 小时。
预计新的可用 Windows 自用包需要 7–11 小时，即约 1 个完整工作日。

