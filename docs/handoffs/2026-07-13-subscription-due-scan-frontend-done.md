# 2026-07-13 订阅到期扫描前端闭环 + 取消门控修复 · 完成回执

执行对象：Claude（前端线）。对应任务单：
`C:/tmp/wealth-ledger-frontend-handoff-2026-07-13.md`（due-scan 前端闭环）与
`docs/handoffs/2026-07-13-claude-subscription-cancel-followup.md`（取消门控，
单独回执见 `2026-07-13-subscription-cancel-followup-done.md`）。

本轮只改 Flutter 前端与前端测试。未修改 `server-rs/**`、`docs/contracts/**`、
`tools/contract_check.py`、`ledgerVersion`/migration registry/`.lock` lease，
未实现服务商支付/退订、自动确认/自动扣账、Android 可写数据源或远端同步。

## 1. 基线与提交

- 基线：`origin/feat/subscription-due-scan` @
  `9b3e0f7f5d99b9ecf349e83af4afb5ffdcfbe35a`（按任务单从该远端 HEAD 建独立
  工作树 `C:\Users\15892\projects\finwealth-subscription-ui`，未继续使用旧
  `feat/frontend-skeleton@31ff676` 契约基线）。
- 分支：`feat/subscription-due-scan-ui`；4 个代码切片 + 回执：

| commit | 用途 |
| --- | --- |
| `70e09ac` | fix: pending 时本地禁用「取消订阅」（P0）+ 2 条 widget 回归 |
| `7204487` | feat: due-scan VM/Repository 抽象/HTTP 映射 + 4 条映射测试 |
| `4ad1bbf` | feat: 列表页「扫描到期扣费」入口 + 结果对话框 + provider 刷新 + 5 条 widget 测试 + 对话框 golden |
| `3e30e98` | test: 真实 local-server 联调覆盖 due-scan 全链路 |

最终提交为本回执所在 docs 提交（`git log` 可见）。远端分支：
`origin/feat/subscription-due-scan-ui`。未改写 `main`、未创建 Release。

## 2. 改动文件

数据层：
- `lib/data/view_models.dart`：`SubscriptionDueScanResultVm` /
  `SubscriptionDueScanCreatedVm`（包装 atomic group + `subscriptionId` +
  `scheduledChargeDate`）/ `SubscriptionDueScanSkipVm` /
  `SubscriptionDueScanSkipReason`（already_pending、payment_account_unavailable、
  payment_currency_unsupported）。
- `lib/data/repositories.dart`：`SubscriptionRepository.scanDueChargeProposals({required IsoDate throughDate, int limit = 100})`。
- `lib/data/api_mock_repositories.dart`：`parseDueScanData`（公开供单测）、
  skip reason 解析、`LocalServerSubscriptionRepository` 调
  `POST /v1/subscriptions/charge-proposals/due-scan`（body 只有
  `throughDate`+`limit`，limit 客户端夹取 1–200）。写路径继续复用
  `DevApiClient.postData()` 的幂等键与 401 单飞 refresh 重放，未另造第二套。
- `lib/data/real_local_repositories.dart`、`lib/data/fixture_repositories.dart`：
  扫描一律抛 `UnsupportedError`，不伪造扫描成功。
- `lib/data/providers.dart`：`refreshAfterDueScan()` 失效订阅列表/即将扣费/
  `aiPendingProvider`/`overviewProvider`；并给 `refreshAfterChargeProposal()`
  补上 `overviewProvider` 失效（修正单条候选生成后首页 pending count 不刷新）。

页面层：
- `lib/features/subscriptions_page.dart`：AppBar「扫描到期扣费」动作
  （`canManageSubscriptions` 门控、busy 期间禁点并显示进度、
  `todayIsoDate()` + 默认 `limit=100`、无页面打开静默扫描、无后台 timer）；
  `DueScanResultDialog` 结果对话框（公开类，golden 直接渲染）。
- `lib/features/subscription_visuals.dart`：`dueScanSkipReasonLabel` 中文
  可恢复提示。
- `lib/features/subscription_detail_page.dart`：`canCancel` 增加
  `!hasPendingCharge`（详见 cancel 回执）。

测试：
- `test/subscription_mapping_test.dart` +4（cat13）：完整响应解析含三种
  skip reason；POST 路径/请求体/幂等键 + limit 夹取；401 refresh 重放复用同一
  幂等键；real_local/fixture 不伪造扫描成功。
- `test/subscription_widget_test.dart` +7（cat12 ×2 + cat14 ×5）：pending 取消
  禁用且 Repository 零调用 / 非 pending 可用；只读能力下扫描按钮禁用；created
  结果显示数量与「前往审核」；already-pending/blocked 结果无「已扣款/已入账」
  且 blocked 显示订阅名+日期+中文原因；busy 不能重复发起（进行中二次点击不
  触发第二次调用）；hasMore 显示剩余数量且「再次扫描」再跑一轮。
- `test/local_server_subscription_integration_test.dart` +1：见 §5。
- `test/preview_golden_test.dart` +2：结果对话框暗/浅预览。
- `tools/frontend_local_server_smoke.ps1`：**未改**——其断言即联调测试文件的
  退出码，扩展测试文件即可，无需新增脚本断言。

## 3. 结果呈现语义（按任务单 §4.2）

- `createdCount > 0`：「已生成 N 个待确认扣费」+ 副文案「确认后才会入账；
  不代表已向服务商实际扣款」，并提供「前往审核」。
- 没有新候选：区分「截至 {throughDate} 没有需要生成的到期扣费」与
  「本次没有生成新的扣费候选」+ already-pending / blocked 分开报告，
  绝不误报为扣款成功（widget 测试断言无「已扣款/已入账」字样）。
- blocked 项用扫描前列表快照把 `subscriptionId` 映射为名称，展示
  「名称 · 计划 日期 + 中文可恢复原因」；快照缺失时回退显示 id。
- `hasMore == true`：提示「还有 remainingEligibleCount 个到期订阅本次未生成
  （单次上限）」，对话框提供「再次扫描」（用户显式再触发，非自动循环）。
- 扫描期间 spinner 只覆盖请求阶段；结果对话框打开时按钮不再显示进行中。

## 4. 门禁实际结果（任务单 §7 全部运行，无未运行项）

- `dart format --output=none --set-exit-if-changed lib test`：通过（0 处需改）。
- `flutter analyze`：No issues found。
- `flutter test test/subscription_mapping_test.dart`：25 passed。
- `flutter test test/subscription_widget_test.dart`：18 passed。
- `flutter test`（全量）：**93 passed / 16 skipped / 0 failed**。16 skipped =
  14 golden 预览（仅 `PREVIEW_GOLDENS=1`）+ 2 真实联调测试（仅 smoke 注入
  `LOCAL_SERVER_API_BASE`）。
- `pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1`：**通过**，
  退出码 0，输出 `OK: Flutter local-server subscription integration smoke passed`
  （从当前源码 `cargo build` 构建并启动 Rust server，临时账本，2 条联调测试全过）。

## 5. 真实 local-server 联调覆盖（任务单 §5.3）

`test/local_server_subscription_integration_test.dart` 新增
`due-scan proposes only due subscriptions and defers charging to confirmation`：

1. 同账户建一到期（start `2026-01-05`）+ 一未来（start `2099-01-05`）订阅。
2. `due-scan(throughDate=2026-07-13)` 只为到期项生成候选：`createdCount=1`、
   `created[0].subscriptionId/scheduledChargeDate` 正确、`skipped` 空、
   `hasMore=false`。
3. 扫描后余额 100.00 不变、`lastChargeDate` 仍空、`nextChargeDate` 不推进、
   未来订阅无 pending。
4. `GET /v1/ai/proposals/pending` 可读取新候选（standalone 投影包含该
   atomic group id）。
5. 重扫不重复建：`already_pending` 跳过（skip 项指向同一订阅）。
6. 确认 atomic group 后才扣款（80.00）并推进日期（`2026-01-05 → 2026-02-05`）。

跨重启幂等、稳定排序、blocked 与 ledger 原子性等后端不变量由 Rust/真实 ledger
smoke 覆盖，前端未复制 mock 冒充（任务单 §5.3 边界）。

## 6. Golden 人工核验（PNG 走 `.gitignore`，未入库）

`PREVIEW_GOLDENS=1` 重新生成后逐张核验订阅相关 5 张：
- `subscription_due_scan_dialog_dark/light.png`（400×760）：created/
  already-pending/blocked（名称+日期+原因）/hasMore 四区段 + 关闭/再次扫描/
  前往审核三动作，暗浅主题均正常，无「已扣款」措辞。
- `subscriptions_dark/light.png`（400×900）：AppBar 新增扫描图标 + 新建图标，
  列表原布局不变，浅色无暗色泄漏。
- `subscription_detail_dark.png`（400×1000）：pending 夹具下「取消订阅」
  正确呈禁用态（修正上一轮回执的错误核验结论），「前往审核」提示条保留。

## 7. 已知边界 / 交回 Codex

- 未发现后端契约或行为问题；实际 JSON 字段与 `HTTP_API_V1.md` §7A、
  `openapi_v1.yaml` due-scan schema 一致，联调一次通过。
- 前端未实现（任务单边界，非缺口）：后台自动扫描 timer、自动确认/扣款、
  服务商支付/退订、Android 数据源决策。
- 若后续 due-scan 响应新增 skip reason 取值，前端解析回退为 already_pending
  文案（宽松枚举，与既有映射层风格一致），需同步扩展
  `SubscriptionDueScanSkipReason` 与文案。

本回执不含 token、密码、认证文件内容或真实账本数据。
