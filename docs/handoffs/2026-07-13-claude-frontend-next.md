# 2026-07-13 Claude 前端下一轮任务单

执行对象：Claude。工作树仅限 `C:\Users\15892\projects\finwealth`，分支
`feat/frontend-skeleton`。

后端由 Codex 负责，当前契约基线是
`feat/backend-hardening@09d1d18`。不要修改
`C:\Users\15892\projects\finwealth-backend`、Rust、OpenAPI、部署脚本，也不要操作
`C:\Users\15892\projects\finwealth-corrections` 的脏工作树。

## 0. 开始前保护现场

当前已知状态：

- `feat/frontend-skeleton@f28ea43`，相对
  `origin/feat/frontend-skeleton@3d23af4` 领先 8 个提交。
- 根目录存在未跟踪文件 `investments-empty-state-emblem.png`。
- 最新 8 个提交包含 `LeadingAvatar`、投资空态插画、Noto Serif 字重调整、AI
  审核页与流水详情视觉收口。

开始时先执行并记录：

```powershell
git status --short --branch
git log origin/feat/frontend-skeleton..HEAD --oneline
flutter analyze
flutter test
```

不要删除或覆盖未跟踪图片。先检查它是否只是
`assets/illustrations/investment-empty-state.png` 的原始生成稿：

- 若是需要保留的源资产，移动到清晰命名的 `design/source/` 或现有约定目录，补充
  来源说明后提交。
- 若是已打包 PNG 的重复副本，在交接文档中说明哈希/尺寸证据，交给用户或 Codex
  决定是否清理；本轮不要自行删除。

基线测试通过后，先把当前 8 个提交推送到
`origin/feat/frontend-skeleton`，避免继续积累本地独占资产。不要推送未跟踪文件。

## 1. P0：完成订阅管理前端闭环

产品目标：用户管理 ChatGPT、Claude 等周期订阅，记录原币金额、付款账户、开始时间、
持续时长或结束日期，并在每期生成待确认扣费。订阅计划不是已经发生的流水；只有用户
确认扣费候选后才改变余额。

权威契约：

- `finwealth-backend/docs/handoffs/2026-07-13-subscriptions-frontend.md`
- `finwealth-backend/docs/contracts/openapi_v1.yaml`
- `finwealth-backend/docs/contracts/HTTP_API_V1.md` 的 `7A. Subscriptions`
- `finwealth-backend/docs/contracts/DATA_SCHEMA_V1.md` 的 `9A. Subscription`

如前端需要的字段与契约冲突，停止自创字段，把问题写入回执交给 Codex；不要改后端契约。

### 1.1 领域模型

增加以下前端投影，金额继续使用十进制字符串，不使用 `double`：

```text
SubscriptionBillingCycleVm
  unit: day | week | month | year
  interval: int

SubscriptionDurationVm
  unit: day | month | year
  count: int

SubscriptionVm
  id
  displayName
  provider
  planName?
  amount: MoneyVm
  paymentAccountId
  billingCycle
  billingAnchorDay
  startDate                 // YYYY-MM-DD，本地日历日期
  duration?
  endDate?
  nextChargeDate?
  autoRenew
  reminderDaysBefore
  status                    // trial/active/paused/cancelled/expired
  pendingChargeMovementId?
  pendingChargeDate?
  lastChargeDate?
  lastChargeMovementId?
  note?
  createdAt
  updatedAt
```

日期型计费字段保持 `YYYY-MM-DD` 字符串或无时区的日历值。不要先转换成 UTC
`DateTime` 再截断，否则跨时区可能改变扣费日。

### 1.2 Repository 与 HTTP 映射

在现有 Repository 体系中增加 `SubscriptionRepository`，至少支持：

```dart
Future<List<SubscriptionVm>> listSubscriptions();
Future<List<SubscriptionVm>> listUpcomingSubscriptions({int days = 30});
Future<SubscriptionVm> getSubscription(String id);
Future<SubscriptionVm> createSubscription(CreateSubscriptionInput input);
Future<SubscriptionVm> updateSubscription(
  String id,
  UpdateSubscriptionInput input,
);
Future<SubscriptionVm> cancelSubscription(String id);
Future<AtomicGroupVm> createChargeProposal(String id);
```

HTTP 路由：

```text
GET   /v1/subscriptions
POST  /v1/subscriptions
GET   /v1/subscriptions/upcoming?days=30
GET   /v1/subscriptions/{id}
PATCH /v1/subscriptions/{id}
POST  /v1/subscriptions/{id}/cancel
POST  /v1/subscriptions/{id}/charge-proposal
```

所有写调用必须复用 `cc0251a` 已完成的 `DevApiClient` 幂等请求路径；不要在
Repository 内另写 HTTP 重试或自行生成第二个 `Idempotency-Key`。

实现对应的 provider，并在写成功后精确失效：

- subscriptions 列表；
- upcoming 列表；
- 对应订阅详情；
- 扣费候选成功后还要失效 AI pending / review 数据；
- 候选确认或拒绝后刷新订阅、账户、概览、流水和 AI pending。

`debug_fixture` 可提供少量明确标记的演示订阅；非持久化模式不得假装扣款成功。
`local_server` 才是写入验收依据。

### 1.3 Capability gating

把 bootstrap 中的 `capabilities.canManageSubscriptions` 映射到
`LedgerCapabilitiesVm`。

- `false`：允许只读浏览，但隐藏或禁用创建、编辑、取消、生成扣费候选动作，并显示统一
  只读原因。
- `true`：开放写入口。
- 不得通过数据源名称猜测是否可写。
- capabilities 请求失败时继续 fail-closed。

补充 capability mapping 与 widget 回归测试，防止后端新增字段被静默忽略。

### 1.4 页面与导航

不要增加第五个一级导航。订阅管理放在设置页的“财务管理”区域，并提供以下路由：

```text
/subscriptions
/subscriptions/new
/subscriptions/:id
/subscriptions/:id/edit
```

最小页面闭环：

1. 订阅列表：名称、服务商、原币金额、周期、下次扣费日、状态。
2. 近期扣费区：调用 upcoming API；逾期项优先并有清晰状态，不使用危险色制造恐慌。
3. 创建/编辑表单：服务商、计划名、原币金额、付款账户、开始日期、周期、持续时长或
   结束日期、自动续订、提前提醒天数、备注。
4. 详情页：展示计划信息、上一期/下一期、关联付款账户、待确认候选和历史状态。
5. “记录本期扣费”：只生成 `pending_review` 候选；成功文案必须是“已生成待确认扣费”，
   不能写“已扣款”或“已入账”。提供“前往 AI 审核”动作。
6. “取消订阅”：二次确认；只取消未来扣费，不暗示已向服务商发起真实退订。

设计要求：沿用当前 Noto 字体、金色品牌 token、`ContentMaxWidth`、`EmptyState`、
`ErrorStateView`、`WriteGate`、`LeadingAvatar`、骨架和 reduce-motion 语义。不要新增第二套
颜色、圆角、字体或金额格式化工具。

### 1.5 表单和错误语义

客户端先做可用性校验，但服务端仍是权威：

- 金额必须为正数，最多 8 位小数。
- billing interval、duration count 必须是正整数。
- `duration` 与 `endDate` 二选一。
- `reminderDaysBefore` 必须为非负整数。
- 付款账户应支持订阅金额币种；不支持时明确提示，不自动换汇。
- 月/年周期解释自然月锚点：1 月 31 日 → 2 月末 → 3 月 31 日。

错误处理：

- 400：显示字段或请求错误，不清空用户输入。
- 401：继续使用现有 refresh 流程。
- 404：详情页显示订阅不存在并可返回列表。
- 409 重复候选：提示“本期已有待确认扣费”，提供前往审核入口。
- 409 取消冲突：提示先确认或拒绝待处理扣费。
- 网络失败：保留表单和动作上下文，允许重试；同一逻辑请求重放仍复用原幂等键。

`autoRenew` 只记录服务商续订偏好，不代表应用会自动支付；固定结束日期到期后仍停止排期。
取消动作只更新本地计划，不调用 ChatGPT、Claude 等服务商的退订 API。

## 2. P1：收敛 redesign 中仍有价值的组件

当前最新前端已经重新实现并使用 `LeadingAvatar`，不要 merge 或 cherry-pick
`feat/redesign`，也不要覆盖当前 `shared/widgets.dart`。旧 redesign 工作树缺少最新的
动画、骨架、错误态和 capability gating，直接选边会造成回退。

在订阅 P0 完成后，仅按行为吸收：

- `StatusPill`：统一 trial/active/paused/cancelled/expired、AI operation、在途等短状态；
  颜色必须来自现有语义 token。
- `MoneyText`：仅当它能统一原币金额排版且不替代需要过渡效果的
  `AnimatedMoneyText` 时引入。

增加组件测试，不以截图替代语义断言。若抽象会增加重复或与现有 token 冲突，记录理由后
跳过，不为“合并 redesign”而合并。

## 3. 不属于 Claude 本轮范围

- 不修改 Rust、本地账本格式、OpenAPI、VPS、备份恢复或打包脚本。
- 不实现模型 AI、自动批准、自动扣款、真实支付或服务商退订。
- 不决定 Android 使用 Rust FFI 还是认证 VPS。
- 不合并 `feat/backend-hardening`；联合集成线与 Windows 包由 Codex 负责。
- 不清理 `finwealth-corrections` 工作树。
- 不把 mock/dev 成功文案包装成真实写账结果。

## 4. 必须补的测试

至少覆盖：

1. Subscription JSON 完整/可选字段解析。
2. bootstrap capability 映射与 fail-closed。
3. list/upcoming/get 路由与 query 映射。
4. create/patch/cancel/proposal 都携带幂等键。
5. 订阅写请求经历 401 refresh 后复用同一个 key。
6. duration/endDate 互斥、金额精度、正整数和付款币种校验。
7. 只读模式禁用所有订阅写入口。
8. 409 重复候选和取消冲突显示可恢复动作。
9. 候选成功只显示“待确认”，不会显示已扣款/已入账。
10. 列表 empty/loading/error/data 四态。
11. 手机与宽屏布局无 overflow。
12. `StatusPill` / `MoneyText`（若引入）的主题和语义测试。

完成后运行：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

不要把 preview PNG 更新当成测试通过。若 golden 需要更新，使用现有
`PREVIEW_GOLDENS=1` 流程，并在回执中记录人工检查了哪些尺寸和主题。

## 5. 提交与交接

建议按可回滚切片提交，不要把全部工作压成一个提交：

1. `chore(frontend): preserve latest visual assets`（仅在确有源资产需归档时）
2. `feat(subscriptions): add models and repository mapping`
3. `feat(subscriptions): add management screens and capability gating`
4. `test(subscriptions): cover scheduling and charge proposal flows`
5. `refactor(ui): unify subscription status and money presentation`（可选 P1）
6. `docs(handoff): report subscription frontend completion`

完成后推送 `feat/frontend-skeleton`，并新增回执：

```text
docs/handoffs/2026-07-13-subscriptions-frontend-done.md
```

回执必须包含：

- 起止 commit 与每个提交用途；
- 修改文件和新增路由；
- Repository/provider 的真实与 mock 边界；
- `flutter analyze` / `flutter test` 的实际结果与测试数量；
- 未跟踪图片最终处理状态；
- 未完成项、已知风险和需要 Codex 联合验证的步骤；
- 不包含 token、密码、真实账本内容或其他秘密。

## 6. Codex 接回后的联合门禁

Claude 不执行这一段，但交接必须准备好让 Codex完成：

1. 合并最新 `feat/frontend-skeleton` 与 `feat/backend-hardening`。
2. 运行 Flutter、Rust、contract、mock/dev/Rust smoke 和真实 local-ledger smoke。
3. 以真实 local server 验证创建 USD 订阅、生成候选、确认前余额不变、确认后扣款与日期
   推进、拒绝可重试、待确认时取消返回 409。
4. 生成 Windows 可写自用包并做启动/登录/重启持久化/备份恢复人工验收。
5. 联合门禁通过前不合并 `main`、不创建 Release。
