# 2026-07-13 订阅取消门控修复 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-13-claude-subscription-cancel-followup.md`。
本修复与 due-scan 前端闭环同分支交付，总回执见
`docs/handoffs/2026-07-13-subscription-due-scan-frontend-done.md`。

## 1. 分支与 commit

- 起始集成基线：`origin/feat/subscription-due-scan` @
  `9b3e0f7f5d99b9ecf349e83af4afb5ffdcfbe35a`（含 due-scan 后端与最新契约）。
- 修复分支：`feat/subscription-due-scan-ui`（工作树
  `C:\Users\15892\projects\finwealth-subscription-ui`）。
- 本修复提交：`70e09ac fix(subscriptions): disable cancel while a charge is pending review`
  （分支首个提交；其后为 due-scan 各切片，最终提交见总回执）。

## 2. `canCancel` 修复前后语义

`lib/features/subscription_detail_page.dart` `_ActionsState.build()`：

```dart
// 修复前
final canCancel = sub.isSchedulable;
// 修复后
final canCancel = sub.isSchedulable && !sub.hasPendingCharge;
```

- pending 时「取消订阅」`onPressed == null`：不弹确认框、不调用 Repository。
- 顶部 `_PendingChargeBanner` 的「前往审核」恢复路径保留。
- 无 pending 的 active/trial 订阅取消仍可用；paused/cancelled/expired 仍不可取消
  （由 `isSchedulable` 覆盖，未改动）。

新增 widget 回归测试（`test/subscription_widget_test.dart` cat12）：

1. `pending 时取消按钮禁用：不弹确认框、不调用 Repository` ——
   断言 `OutlinedButton.onPressed == null`、tap 后无确认对话框、
   fake repo 的 `cancelSubscription` 调用次数为 0、「前往审核」仍在。
2. `无 pending 的可排期订阅取消仍可用` —— 断言 `onPressed != null`，
   防止把所有取消入口一并锁死。

## 3. 409 竞态兜底保留证据

- 代码：`_cancel()` 的 `on ApiConflictException` 分支未改动，仍提示
  「有待确认扣费，请先在 AI 审核里确认或拒绝，再取消订阅」+「前往审核」。
- 测试：cat8 `取消冲突 409 提示先确认或拒绝` 保留且通过。该测试夹具为
  **非 pending** 订阅（页面数据过期的真实竞态场景），与新门控不冲突。
- 真实服务端：联调测试中「待确认存在时 `cancelSubscription` 抛
  `ApiConflictException`」断言保留并通过（见总回执 smoke 结果）。

另：上一轮回执 `2026-07-13-subscriptions-frontend-done.md` 的 golden 核验曾把
pending 下「取消订阅」可用记为“正常”，该结论错误（任务单已指出）。本轮重新生成的
`subscription_detail_dark.png`（pending 夹具）中「取消订阅」呈禁用态，已人工复核。

## 4. 门禁实际结果（与 due-scan 合并跑，最终态）

- `dart format --output=none --set-exit-if-changed lib test`：通过（0 处需改）。
- `flutter analyze`：No issues found。
- `flutter test test/subscription_widget_test.dart`：18 passed（含上述 2 条新回归）。
- `flutter test`（全量）：93 passed / 16 skipped / 0 failed
  （16 skipped = 14 golden 预览仅 `PREVIEW_GOLDENS=1` 运行 + 2 条真实联调测试仅在
  smoke 注入 `LOCAL_SERVER_API_BASE` 时运行）。
- `pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1`：**通过**，
  输出 `OK: Flutter local-server subscription integration smoke passed`
  （从当前源码 cargo build 并启动 Rust server，2 条联调测试全过）。

无未运行项。

## 5. 边界声明

- 未修改 `server-rs/**`、`docs/contracts/**`、`tools/contract_check.py`。
- 未修改后端请求/响应字段、状态码、幂等语义或账本持久化规则。
- 本修复业务改动仅：`lib/features/subscription_detail_page.dart`、
  `test/subscription_widget_test.dart`、本回执。

## 6. 最终 git 状态

`git status --short --branch`（提交回执后）：

```text
## feat/subscription-due-scan-ui...origin/feat/subscription-due-scan-ui
```

工作树干净，无意外未跟踪文件；golden PNG 走 `.gitignore` 未入库。
远端分支：`origin/feat/subscription-due-scan-ui`。未合并 `main`、未创建 Release。

本回执不含 token、密码、认证文件内容或真实账本数据。
