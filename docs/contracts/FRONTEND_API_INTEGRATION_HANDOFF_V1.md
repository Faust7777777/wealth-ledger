# FRONTEND_API_INTEGRATION_HANDOFF_V1

状态：历史阶段交接；保留用于解释早期 mock/dev 接线，不再作为当前实现矩阵。
用途：记录 Flutter 前端早期在不等待真实服务器、真实行情、真实 AI 时如何对准接口形状。
非用途：不是生产后端说明，不授权接真实钱、真实交易、真实 AI 写账。

> 当前权威边界以 `openapi_v1.yaml`、`HTTP_API_V1.md`、`LOCAL_LEDGER_FORMAT_V1.md`、`server-rs/README.md` 和最新 `docs/handoffs/` 回执为准。本文后续“第一阶段”“当前”均指早期联调阶段，端点列表不是现状的完整清单。

## 1. 当前真实/空壳边界（2026-07-13）

Flutter 当前仍保留多种数据源，但它们的真实性边界不同：

```text
real_local      默认；Flutter 内部空账本壳；不直接读写 JSON，写操作不支持
debug_fixture   仅 debug/demo；虚构只读演示数据；显示 DEMO；禁止同步/备份
local_server    Flutter HTTP adapter；连接带 --ledger-path 的 Rust 服务时是真实本地持久化路径
api_remote      预留；尚不是完整 VPS 多设备同步实现
```

服务端边界：

```text
Rust + --ledger-path  真实 accounts/movements/DCA/subscriptions/proposals/snapshots/taxonomy 持久化
Rust 无 ledger path   确定性 empty/degraded 读模型与进程内 proposal 联调；重启丢失
Python dev/mock       接口形状与 smoke；不得作为真实副作用验收依据
```

`local_server` 的写入能力必须由 `/v1/ledger/bootstrap.data.capabilities` fail-closed 控制。当前已落地的订阅管理路由包括 list/upcoming/detail/create/update/cancel/charge-proposal；订阅计划不会自动扣款，charge proposal 经用户确认后才影响余额。真实 AI 模型、支付代扣、券商交易和完整远端同步仍未实现。

## 2. 前端接入顺序

建议顺序：

1. 保持 `real_local` 为默认启动模式。
2. 保持 `debug_fixture` 只在 debug/demo 下启用，并常驻 DEMO 标记。
3. 新增一个可选的本地 HTTP repository，用于读取 dev server/mock server。
4. HTTP repository 只读首页、账户、持仓、AI pending、DCA proposal 等接口形状。
5. 写入路径仍只能生成 proposal 或 pending review，不得直接改正式账本。

不建议前端现在做：

- SQLite / 加密存储。
- 真实登录。
- 真实同步。
- 真实行情供应商。
- 真实 AI 调用。
- 真实交易、转账、券商连接。

## 3. 本地服务启动

Python dev server：

```bash
python server/dev_server.py --port 8790
```

Rust dev server：

```bash
cargo run --manifest-path server-rs/Cargo.toml -- --port 8791
```

只读 mock server：

```bash
python tools/mock_api_server.py --port 8787
```

统一校验：

```bash
python tools/server_smoke.py
```

## 4. 前端第一批可接端点

优先接这些端点即可覆盖 V2.1 首屏与核心复核流：

```text
GET  /v1/health
GET  /v1/ledger/bootstrap
GET  /v1/portfolio/overview
GET  /v1/accounts
GET  /v1/accounts/{accountId}
GET  /v1/accounts/{accountId}/holdings
GET  /v1/accounts/anomalies
GET  /v1/portfolio/holdings
GET  /v1/portfolio/allocation
GET  /v1/movements
GET  /v1/movements/{movementId}
GET  /v1/dca/plans
GET  /v1/dca/reminders/due
GET  /v1/ai/proposals/pending
GET  /v1/ai/proposals/{proposalId}
GET  /v1/snapshots/latest
GET  /v1/snapshots
GET  /v1/quotes/summary
```

`/v1/ledger/bootstrap.data.capabilities` 是写入口 gating 的服务端口径。前端不得只凭 data source 名称猜测能力；至少应读取 `canWriteConfirmedLedger`、`canCreateAccount`、`canRecordMovement`、`canConfirmProposal`、`canPersistPendingProposal` 和 `proposalPersistence`。

用于按钮行为的 proposal 端点：

```text
POST /v1/dca/reminders/{reminderId}/mark-executed-as-proposal
POST /v1/ai/proposals/from-text
POST /v1/ai/proposals/from-image
POST /v1/ai/proposals/from-csv
POST /v1/ai/atomic-groups/{atomicGroupId}/approve
POST /v1/ai/atomic-groups/{atomicGroupId}/reject
PATCH /v1/ai/atomic-groups/{atomicGroupId}
POST /v1/quotes/refresh
```

这些 POST/PATCH 在当前 dev server 中不代表真实副作用；它们只返回候选/示例/空壳结果，用来固定 UI 与接口形状。

## 5. 场景参数

首页可用场景：

```text
GET /v1/portfolio/overview?scenario=empty
GET /v1/portfolio/overview?scenario=degraded
```

Rust dev server 还支持把 `?scenario=degraded` 加到第一批只读端点上，用同一组虚构数据驱动账户、持仓、流水、DCA、AI pending、快照、报价摘要页面：

```text
GET /v1/accounts?scenario=degraded
GET /v1/accounts/acct_us_broker?scenario=degraded
GET /v1/accounts/acct_us_broker/holdings?scenario=degraded
GET /v1/accounts/anomalies?scenario=degraded
GET /v1/portfolio/holdings?scenario=degraded
GET /v1/portfolio/allocation?scenario=degraded
GET /v1/movements?scenario=degraded
GET /v1/movements/mov_luckin_001?scenario=degraded
GET /v1/dca/plans?scenario=degraded
GET /v1/dca/reminders/due?scenario=degraded
GET /v1/ai/proposals/pending?scenario=degraded
GET /v1/ai/proposals/proposal_ai_001?scenario=degraded
GET /v1/snapshots/latest?scenario=degraded
GET /v1/snapshots?scenario=degraded
GET /v1/quotes/summary?scenario=degraded
```

规则：

- `empty` 用于真实空账本首屏。
- `degraded` 用于报价过期、AI 待确认、定投到期、账户异常、在途交易并发态。
- 不带 `scenario=degraded` 时，Rust dev server 的第一批列表端点仍返回空态。
- `degraded` 不是用户真实数据，也不是 debug fixture 种子。

## 6. 必须保持的 UI 语义

前端接 HTTP repository 后仍必须保持：

- 默认启动不显示 DEMO 数据。
- DEMO / fixture / mock 数据必须有可见标记。
- 断网、报价过期、unpriceable 不能被渲染成“精确净值”。
- `unpriceable` 显示 `—`，不得当 0 计入估值。
- 首页涨跌默认是“较上次快照”；只有 quote/fx 全 fresh 才允许写“今日”。
- `primaryHoldings` 按市值占比展示，不按收益率排行。
- 负债账户余额为负是正常负债，不触发 `negative_balance`。
- 消费只作为资产变动解释，优惠/免单只作为交易金额拆分字段。

## 7. AI 与 DCA 按钮边界

AI：

- AI 导入只创建 `AiProposal`。
- 修改已有记录必须显示 old → new diff。
- 最小确认单位是 `atomic_group`。
- 确认前不得进入正式余额、流水、净值。
- approve 前必须重新校验。

DCA：

- “记录已执行”只调用 `mark-executed-as-proposal`。
- 调用时必须提交持仓账户、实际成交数量、实际总成本、报价币种与可选成交时间；
  `plannedAmount` 只能作为表单默认值，不能直接当作持仓数量。
- 前端应在提交前让用户确认实际成交数据；现金腿使用总成本，持仓腿使用数量。
- 它只生成待确认候选记录。
- 不连接券商。
- 不下单。
- 不转账。

## 8. 永远禁止接入的端点或能力

以下端点在 mock/dev/Rust server 中都应返回 403，前端不应依赖它们：

```text
POST /v1/transfers/execute
POST /v1/broker/orders
POST /v1/broker/buy
POST /v1/broker/sell
POST /v1/ai/auto-approve
POST /v1/ai/write-ledger-directly
POST /v1/coupons/plan
```

对应产品能力也禁止出现：

- 自动转账。
- 自动下单。
- 券商交易权限。
- AI 自动确认。
- AI 直接写正式账本。
- 优惠券规划、省钱排行、奶茶规划。

## 9. 给前端的最小验收

前端 HTTP repository 做完后，应至少满足：

1. `real_local` 默认仍进入空账本首屏。
2. `debug_fixture` 仍只在 debug/demo 下出现，并显示 DEMO。
3. `api_mock/dev_server` 能渲染 `empty` 与 `degraded` 首页。
4. AI 待确认页能渲染 old → new diff。
5. DCA “记录已执行”按钮只生成/展示 pending review proposal / draft，不出现下单/转账语义；确认前不影响 confirmed/effective ledger。
6. 禁止端点即使被误调，也以 403 呈现为产品边界错误。

后端线验收命令：

```bash
python tools/contract_check.py
python tools/server_smoke.py
cargo test --manifest-path server-rs/Cargo.toml
```

前端线有 Flutter 环境后再跑：

```bash
flutter analyze
flutter test
```
