# 2026-07-13 订阅管理前端闭环 · 完成回执

执行对象：Claude（前端线）。工作树：`C:\Users\15892\projects\finwealth`，分支
`feat/frontend-skeleton`。对应任务单
`finwealth-backend/docs/handoffs/2026-07-13-claude-frontend-next.md`。

本轮只改前端。未触碰 `finwealth-backend`、Rust、OpenAPI、部署脚本，也未操作
`finwealth-corrections` 工作树。未合并 `feat/backend-hardening`。

## 起止 commit 与每个提交用途

Step 0 已在上一段把先前 8 个本地提交推送到
`origin/feat/frontend-skeleton`（现 `a4684fb`）。订阅工作为其后 4 个可回滚切片：

| commit | 用途 |
| --- | --- |
| `ddd8ae1` | feat(subscriptions): 领域模型 VM + `canManageSubscriptions` 能力位 |
| `e86766c` | feat(subscriptions): Repository 抽象 + 三实现 + HTTP 映射 + 409 + providers |
| `b5f2286` | feat(subscriptions): 列表/详情/表单页 + 设置入口 + 4 路由 + capability gating |
| `f36a019` | test(subscriptions): 纯校验抽取 + 映射/幂等/widget 测试 + golden 预览 |

起：`ddd8ae1`（含）。止：`f36a019`（HEAD）。

## 修改文件与新增路由

新增文件：
- `lib/features/subscriptions_page.dart`（列表 + 近期扣费区）
- `lib/features/subscription_detail_page.dart`（详情 + 待确认候选 + 动作）
- `lib/features/subscription_form_page.dart`（新建/编辑表单）
- `lib/features/subscription_visuals.dart`（状态色/文案、周期/时长、本地日期工具）
- `lib/features/subscription_form_validation.dart`（可单测纯校验）
- `test/subscription_mapping_test.dart`、`test/subscription_widget_test.dart`

改动文件：
- `lib/data/view_models.dart`：订阅 VM/枚举/输入 DTO + `LedgerCapabilitiesVm.canManageSubscriptions`
- `lib/data/repositories.dart`：`SubscriptionRepository` 抽象
- `lib/data/api_mock_repositories.dart`：`ApiConflictException`（409）、订阅枚举/JSON 映射、
  `parseSubscriptionData`（公开供单测）、`LocalServerSubscriptionRepository`
- `lib/data/real_local_repositories.dart`、`lib/data/fixture_repositories.dart`：另两实现
- `lib/data/providers.dart`：`subscriptionRepositoryProvider` + 列表/即将扣费/详情 provider +
  精确失效扩展
- `lib/features/ai_review_page.dart`：确认/拒绝候选后一并失效订阅视图（pending/nextCharge 会变）
- `lib/features/settings_page.dart`：设置页新增「财务管理 → 订阅管理」入口（不加第五个一级导航）
- `lib/app/router.dart`：4 条路由
- `test/preview_golden_test.dart`：订阅列表(暗/浅) + 详情(暗) 预览

新增路由：
```
/subscriptions            列表
/subscriptions/new        新建
/subscriptions/:id        详情
/subscriptions/:id/edit   编辑（extra 传入 SubscriptionVm）
```
`/new` 声明在 `/:id` 之前，避免 "new" 被当作 id。

## Repository / provider 的真实与 mock 边界

`subscriptionRepositoryProvider` 按数据源 `_pick`：
- `local_server` → `LocalServerSubscriptionRepository`：真实 HTTP，**唯一写入验收依据**。
  所有写走 `DevApiClient` 幂等路径（`cc0251a` 已完成），未在 Repository 内另生成第二个
  `Idempotency-Key` 或另写重试。
- `real_local` → `RealLocalSubscriptionRepository`：读返回空、写抛 `UnsupportedError`。
- `debug_fixture` → `FixtureSubscriptionRepository`：2 条明确标记的 DEMO 订阅（只读）；
  写一律抛 `UnsupportedError`，**不假装扣款成功**。DEMO 下 `canManageSubscriptions` 保持
  false，写入口被 gating 隐藏/禁用。

HTTP 路由：`GET/POST /v1/subscriptions`、`GET /v1/subscriptions/upcoming?days=`、
`GET/PATCH /v1/subscriptions/{id}`、`POST /v1/subscriptions/{id}/cancel`、
`POST /v1/subscriptions/{id}/charge-proposal`（返回 atomic group，进现有 AI 复核确认管线）。
PATCH 为整表替换语义：可空字段显式传 `null` 表示清除；`duration` 与 `endDate` 互斥。
金额全程十进制字符串；日期保持 `YYYY-MM-DD` 本地日历字符串，日期选择只在本地日历层
取值（不经 UTC，避免跨时区改扣费日）。

## Capability gating

`bootstrap.capabilities.canManageSubscriptions` → `LedgerCapabilitiesVm`：
- `false`：允许只读浏览；创建/编辑/取消/生成扣费候选全部隐藏或禁用，并给统一只读原因
  （复用 `WriteGate` / `kReadOnlyHint`）。
- `true`：开放写入口。
- 不按数据源名称猜测可写性；capabilities 请求失败继续 fail-closed（`LedgerCapabilitiesVm.locked`，
  `canManageSubscriptions=false`）。

## 关键产品语义（按任务单）

- 「记录本期扣费」只生成 `pending_review` 候选；成功文案固定「已生成待确认扣费，请到 AI 审核确认」，
  **不出现「已扣款」「已入账」**，并提供「前往审核」动作。
- 「取消订阅」二次确认，仅停未来排期；文案明示**不向 ChatGPT/Claude 等服务商发起真实退订**、
  不影响历史。
- 待确认候选存在时：详情页顶部 info 蓝提示条 + 「前往审核」；禁止重复生成扣费、禁止取消。
- 409 可恢复：重复候选 → 「本期已有待确认扣费」+ 前往审核；取消冲突 → 「请先在 AI 审核里
  确认或拒绝待处理扣费」+ 前往审核。
- 近期扣费区逾期项优先，用暖琥珀 warning，不用 error 危险色制造恐慌。
- `autoRenew` 仅记录续订偏好（表单副文案已说明），不代表应用自动支付。
- 表单可用性校验：金额正数且 ≤8 位小数；interval/duration count 正整数；reminderDaysBefore
  非负；`duration`/`endDate` 二选一（结束日期须晚于开始日期）；付款账户币种不支持时明确提示、
  不自动换汇。校验为纯函数（`subscription_form_validation.dart`），服务端仍是权威。

设计沿用现有 token/组件（Noto 字体、金色品牌、`ContentMaxWidth`、`EmptyState`、
`ErrorStateView`、`WriteGate`、`LeadingAvatar`、骨架、`formatMoney`）。未新增第二套
颜色/圆角/字体/金额格式化。

## 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test`：**通过**（0 处需改）。
- `flutter analyze`：**No issues found**。
- `flutter test`：**全绿**，80 passed / 12 skipped / 0 failed（12 skipped 为 golden 预览，
  仅 `PREVIEW_GOLDENS=1` 时运行，不进门禁）。其中订阅专项 32 条：
  - `subscription_mapping_test.dart` 21 条：JSON 完整/可选解析、capability 映射 + fail-closed、
    list/upcoming(days 夹取)/get 路由、create/patch/cancel/proposal 幂等键、401 refresh 后
    复用同一 key、`duration`/`endDate` 互斥与 PATCH 显式 null 清除、409 → `ApiConflictException`、
    金额精度/正整数/结束日期纯校验。
  - `subscription_widget_test.dart` 11 条：列表 empty/loading/error/data 四态、只读禁用写入口、
    409 可恢复动作、候选成功只显示待确认（不含已扣款/已入账）、手机 360 与宽屏 1200 无 overflow。

## Golden 人工核验

`PREVIEW_GOLDENS=1` 生成并逐张肉眼核验（PNG 走 `.gitignore`，未入库）：
- `subscriptions_dark.png`（400×900）：标题 + 新建入口、近期扣费(逾期琥珀)、全部订阅行
  （provider 首字母徽标、每月、下次日期、绿色「生效中」药丸、$20.00）——正常。
- `subscriptions_light.png`（400×900）：暖纸浅底、状态色主题感知无暗色泄漏——正常。
- `subscription_detail_dark.png`（400×1000）：头部 + 待确认蓝条 + 计划信息 + 扣费情况；
  因已有待确认候选，「记录本期扣费」正确禁用并显示「本期已有待确认扣费」，「取消订阅」可用——正常。

核验尺寸：手机 400 宽（暗/浅）+ 详情 400×1000（暗）。主题：深色、浅色。

## 未跟踪图片最终状态

任务单提到的根目录未跟踪 `investments-empty-state-emblem.png` 已在 Step 0 归档为
`assets/illustrations/source/investment-empty-state.raw.png` + `README.md`（来源/绿幕抠图
命令），提交于 `a4684fb`。根目录现无未跟踪图片，工作树干净。它是打包 PNG 的原始生成稿
（1254² 绿幕原稿 vs 打包件 512×415 RGBA），按任务单要求保留而非删除。

## P1（redesign 组件吸收）——评估后跳过，附理由

任务单允许「若抽象会增加重复或与现有 token 冲突，记录理由后跳过」。

- `StatusPill`：本轮订阅状态药丸 `SubscriptionStatusPill` 已实现且颜色全取现有语义 token
  （trial=info、active=positive、paused=warning、cancelled/expired=textTertiary 中性）。
  抽成覆盖 AI operation / inTransit 的通用 `StatusPill` 需改动已工作、已有独立操作胶囊实现的
  `ai_review_page`，回退风险 > 收益，且当前仅一个新调用点属过早抽象——**跳过**。
- `MoneyText`：订阅金额用现有 `formatMoney(withCode:)` 统一原币排版即可；引入 `MoneyText`
  不能替代需要过渡动画的 `AnimatedMoneyText`，会形成两套排版入口——**跳过**。

若后续确需统一，建议单独起 `refactor(ui)` 切片，先在一处落地再逐步替换，不与本轮 P0 混提交。

## 未完成项 / 已知风险 / 需 Codex 联合验证

- 未实现（本轮范围外，符合任务单）：真实 AI、自动批准/扣款、真实支付、服务商退订 API。
  未决定 Android 数据源（Rust FFI vs 认证 VPS）。
- 写入验收依赖真实 `local_server` + 后端订阅端点（`feat/backend-hardening`）。前端已按契约
  （`2026-07-13-subscriptions-frontend.md` / openapi 7A / DATA_SCHEMA 9A）映射；**未与真实
  服务端联调**。若实际 JSON 字段名/枚举取值与前端投影不符，请回填此回执交前端线，勿改后端契约。
- 自然月锚点（1/31 → 2 月末 → 3/31）由服务端 `billingAnchorDay` 权威计算；前端仅展示
  `nextChargeDate` 并在表单给出说明文案，不在前端推算扣费日。
- 需 Codex 在合并 `feat/backend-hardening` 后联合验证（任务单 §6）：真实 local server 建 USD
  订阅 → 生成候选 → 确认前余额不变 → 确认后扣款且日期推进 → 拒绝可重试 → 待确认时取消返回
  409；随后 Windows 自用包启动/登录/重启持久化/备份恢复人工验收。

本回执不含 token、密码、真实账本内容或其他机密。
