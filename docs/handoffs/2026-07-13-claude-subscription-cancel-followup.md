# 2026-07-13 Claude 前端后续：待确认扣费时禁用取消订阅

范围：只修 Flutter 订阅详情页的前端动作门控并补回归测试。不要修改 Rust、后端接口、账本格式、OpenAPI 或同步契约。

## P0：修正 `pendingCharge` 状态下仍可取消的问题

当前集成代码 `lib/features/subscription_detail_page.dart` 的 `_ActionsState.build()` 为：

```dart
final canCharge = sub.isSchedulable && !sub.hasPendingCharge;
final canCancel = sub.isSchedulable;
```

因此 active/trial 订阅只要 `isSchedulable` 为真，即使已有
`pendingChargeMovementId` + `pendingChargeDate`，详情页的「取消订阅」按钮仍可点击并发出请求。

这与现有产品语义直接矛盾：

- `docs/handoffs/2026-07-13-subscriptions-frontend.md` 的页面最小闭环第 7 条要求：有待确认候选时禁用重复生成和取消，并引导用户先去审核。
- `docs/handoffs/2026-07-13-subscriptions-frontend-done.md` 的“关键产品语义”同样声称 pending 时禁止取消；但其 Golden 核验又把 pending 状态下「取消订阅」可用记录成“正常”。后一句是错误结论，不应继续作为实现依据。

修复要求：

1. 将取消动作的本地门控改为同时检查 `!sub.hasPendingCharge`，即 pending 时按钮实际禁用，不能弹确认框，也不能调用 Repository。
2. 保留页面顶部 `_PendingChargeBanner` 的「前往审核」入口，使用户有明确恢复路径。
3. 保留现有取消 409 的可恢复提示与测试。409 仍用于处理页面数据过期、并发生成候选等竞态；前端本地门控不能替代服务端权威校验。
4. 不改变无 pending 的 active/trial 订阅：其「取消订阅」仍应可用；paused/cancelled/expired 仍不可取消。

在 `test/subscription_widget_test.dart` 至少新增两个 widget 断言：

- `pending: true` 且 `canManageSubscriptions: true` 时，找到「取消订阅」对应的 `OutlinedButton`，断言 `onPressed == null`；点击不会出现取消确认框，也不会调用 `cancelSubscription()`。
- `pending: false` 的可排期订阅仍有可用的取消按钮，防止把所有取消入口一并锁死。

现有“取消冲突 409 提示先确认或拒绝”测试必须保留，它验证的是竞态兜底，不是正常 pending 页面交互。

## 分支与契约权威

不要继续从 `C:\Users\15892\projects\finwealth` 当前的
`feat/frontend-skeleton@31ff676` 直接派生后续工作。该前端工作树中的契约文档相对集成线已经落后，部分内容仍是订阅接入前的版本。

等待 Codex 完成并推送 `feat/integration-self-use` 后，从该远端分支最新 HEAD 派生本次前端修复，或先把你的前端工作分支同步到它。后续实现以集成线中的以下内容和真实行为为准：

- `docs/contracts/HTTP_API_V1.md`
- `docs/contracts/openapi_v1.yaml`
- `docs/contracts/DATA_SCHEMA_V1.md`
- `lib/data/api_mock_repositories.dart`
- `tools/frontend_local_server_smoke.ps1`

`docs/handoffs/` 下旧任务单和旧回执只用于了解历史意图；若它们与集成分支代码、当前契约或真实服务联调结果冲突，不以旧文档为权威，也不要把旧回执中的错误判断复制到新回执。

## 数据源边界

务必保持现有边界，不要因名称误判：

- `real_local` 是只读空壳。`lib/data/real_local_repositories.dart` 的
  `RealLocalSubscriptionRepository` 列表返回空，详情及所有写方法抛
  `UnsupportedError`；它不会直接读写真实 JSON 账本。
- `debug_fixture` / fake Repository 仅供演示和测试，不是持久化证据。
- `local_server` 才是唯一真实写入路径：`lib/data/providers.dart` 将其选择为
  `LocalServerSubscriptionRepository`，再由 `lib/data/api_mock_repositories.dart`
  通过 `DevApiClient` 调用 Rust HTTP 服务。
- 真实写入闭环以 `tools/frontend_local_server_smoke.ps1` 为准，不能用 fixture、mock 或
  `real_local` 空态宣称完成。

## 严格禁止的改动

本任务不需要也不授权修改：

- `server-rs/**`
- `docs/contracts/**`
- 后端请求/响应字段、状态码、幂等语义或账本持久化规则
- `tools/contract_check.py`
- 订阅确认、拒绝、余额推进或自然月锚点的服务端逻辑

预期业务改动应限于：

- `lib/features/subscription_detail_page.dart`
- `test/subscription_widget_test.dart`
- 一份新的完成回执

若发现服务端或契约问题，只记录证据并交回 Codex，不要在前端任务中改后端。

## 完成门禁

从最新 `feat/integration-self-use` 派生后运行：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test test\subscription_widget_test.dart
flutter test
pwsh -NoProfile -File tools\frontend_local_server_smoke.ps1
```

最后一项会从当前源码构建并启动 Rust server；若无法运行，必须在回执中明确写出原因，并由 Codex 在集成线补跑，不能把 mock/widget 测试当作真实写入闭环替代品。

完成后确认：

- 仅预期 Flutter 文件和新回执有改动；无 Rust/契约变更。
- 工作树无意外未跟踪文件，不提交生成的 golden PNG、账本、认证文件或日志。
- 提交并推送独立前端修复分支；不要直接合并 `main`、不要创建 Release。

## 回执要求

新增：

```text
docs/handoffs/2026-07-13-subscription-cancel-followup-done.md
```

回执必须包含：

1. 起始集成分支及 commit、修复分支及最终 commit。
2. `canCancel` 的修复前后语义，以及 pending/non-pending 两个 widget 回归测试名称。
3. 现有 409 竞态兜底仍保留的证据。
4. format、analyze、专项 test、全量 test、真实 `local_server` smoke 的实际结果；未运行项要明确说明，不能省略。
5. 明确声明未修改 `server-rs/**` 与 `docs/contracts/**`。
6. 最终 `git status --short --branch` 摘要与远端分支名。

回执不得包含 token、密码、认证文件内容、真实账本数据或其他秘密。

## Suggested skills

- `diagnose`：先用 widget 状态和 Repository 调用证据复现门控矛盾，再做最小修复与回归验证。
- Flutter widget testing：直接断言按钮可用性和交互副作用，避免只依赖截图或文案判断。
