# FRONTEND_API_INTEGRATION_HANDOFF_V1

状态：给 Flutter 前端线的本地联调交接。  
用途：让前端在不等待真实服务器、真实行情、真实 AI 的情况下，对准同一套接口形状。  
非用途：不是生产后端说明，不授权接真实钱、真实交易、真实 AI 写账。

## 1. 当前结论

第一阶段前端可以并行做三种数据源，但默认仍是本地空账本：

```text
real_local      默认；真实本地账本壳；当前返回空态
debug_fixture   仅 debug/demo；虚构演示数据；必须显示 DEMO；禁止同步
api_mock        仅本地联调；请求 localhost stub；不得作为默认模式
```

当前仓库已经有两个可用于本地联调的 HTTP 服务：

```text
Python dev server  http://127.0.0.1:8790
Rust dev server    http://127.0.0.1:8791
```

前端若新增远端/HTTP repository，建议命名为 `api_mock` 或 `dev_server`，不要命名成生产 `api_remote`。`api_remote` 留给未来 VPS 同步服务。

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
GET  /v1/holdings
GET  /v1/movements/recent
GET  /v1/movements/{movementId}
GET  /v1/dca/plans
GET  /v1/dca/reminders/due
GET  /v1/ai/proposals/pending
GET  /v1/ai/proposals/{proposalId}
GET  /v1/snapshots
GET  /v1/quotes/summary
```

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

规则：

- `empty` 用于真实空账本首屏。
- `degraded` 用于报价过期、AI 待确认、定投到期、账户异常、在途交易并发态。
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
5. DCA “记录已执行”按钮只生成/展示 pending review proposal，不出现下单/转账语义。
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
