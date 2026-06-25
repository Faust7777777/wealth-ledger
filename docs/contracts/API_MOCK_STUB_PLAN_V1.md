# API_MOCK_STUB_PLAN_V1

状态：接口线计划。  
用途：定义后续如何基于 `openapi_v1.yaml` 和 `examples/` 提供 mock/stub，帮助前端联调 UI 状态。  
边界：mock/stub 不是真实后端，不写账、不同步、不接行情、不接 AI。

## 0. 为什么需要 mock/stub

Claude 前端当前第一阶段默认应使用 `real_local` 空账本和隔离 `debug_fixture`。  
但当 UI 骨架稳定后，前端需要验证以下接口状态：

- 空账本。
- 首页降级态。
- AI old → new diff。
- DCA “记录已执行”只生成 proposal。
- 报价 stale / offline_cached。

这些状态应来自契约 examples，而不是临时乱造字段。

## 1. mock/stub 原则

1. 只读。
2. 只返回 `docs/contracts/examples/*.json` 或按 OpenAPI 形状生成的空响应。
3. 不写正式账本。
4. 不写 debug fixture。
5. 不参与同步。
6. 不接真实行情。
7. 不接真实 AI。
8. 不提供任何交易/转账/下单接口。

## 2. 推荐实现阶段

### Phase A：文档与检查

当前阶段。只维护：

- `HTTP_API_V1.md`
- `openapi_v1.yaml`
- `examples/`
- `tools/contract_check.py`

### Phase B：本地静态 mock server

可选。只服务本地开发。

推荐：

```text
tools/mock_api_server.py
```

约束：

- 使用 Python 标准库优先，不引入重依赖。
- 仅绑定 `127.0.0.1`。
- 默认端口 `8787`。
- 返回 examples 文件。
- POST 请求不产生持久化副作用。
- 所有写类 POST 返回预设 proposal / result，不修改任何文件。

### Phase C：OpenAPI stub

后续如果需要生成 client/server stub，再基于 `openapi_v1.yaml` 选择工具。

候选：

- Rust Axum server stub。
- TypeScript client。
- Dart client。

但在前端第一阶段，不要求接入这些真实请求。

## 3. mock endpoint 映射建议

```text
GET  /v1/ledger/bootstrap
  -> examples/ledger_bootstrap_empty.response.json

GET  /v1/portfolio/overview?scenario=empty
  -> examples/portfolio_overview_empty.response.json

GET  /v1/portfolio/overview?scenario=degraded
  -> examples/portfolio_overview_degraded.response.json

POST /v1/ai/proposals/from-text
  -> examples/ai_modify_movement_diff.response.json

POST /v1/dca/reminders/{reminderId}/mark-executed-as-proposal
  -> examples/dca_mark_executed_proposal.response.json

POST /v1/quotes/refresh
  -> examples/quote_refresh_stale.response.json
```

## 4. 不允许 mock 的内容

以下内容即使 mock 也不应出现：

```text
POST /v1/transfers/execute
POST /v1/broker/orders
POST /v1/broker/buy
POST /v1/broker/sell
POST /v1/ai/auto-approve
POST /v1/ai/write-ledger-directly
POST /v1/coupons/plan
```

## 5. 前端接入建议

前端第一阶段仍然不接 mock API。  
只有当 UI 需要 HTTP 联调时，新增第四种明确开发模式，而不是污染现有 `real_local`：

```text
DataSourceMode:
  real_local       // 默认，空账本
  debug_fixture    // 隔离 demo
  api_remote       // 未来真实 VPS
  api_mock         // 可选，本地 mock server
```

如果引入 `api_mock`：

- 必须只在 debug/demo 构建可用。
- UI 必须显示 `MOCK` 标记。
- 禁止同步。
- 禁止保存 token。

## 6. 验收标准

mock/stub 只有满足以下条件才可进入仓库：

- `python tools/contract_check.py` 通过。
- OpenAPI 不包含禁止端点。
- mock server 不写文件。
- mock server 不监听公网地址。
- mock server 有清晰 `MOCK` 响应头或日志。
- 前端默认仍为 `real_local`。

