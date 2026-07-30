# Agent 非加密投资标的确定性解析

## 问题

加密持仓快照已经由 Rust 根据 symbol 生成真实 `instrumentId`，但券商、基金平台和其他非 crypto 来源仍只能依赖已有标的。缺少标的时，模型没有安全的登记与映射入口，容易自造 ID 或无法继续创建待审核快照。

## 后端实现

- 新增 `POST /v1/accounts/{accountId}/investment-instruments/ensure`。
- 每项只接受 `type + symbol + displayName + quoteCurrency + market`；类型限 `equity/fund/other`，不接受客户端或模型提供的 `id`。
- Rust 规范化 symbol、market 和 quoteCurrency，按 `type + market + symbol` 严格匹配；已有身份的计价币不一致时返回冲突，不静默覆盖。
- 找不到标的时由 Rust 生成稳定前缀的唯一 ID，写入 `sourceRef=finwealth_agent_source_instrument`，并把标的计价币补入账户 `supportedCurrencies`。
- ensure 只修改标的与账户元数据，不创建 holding、余额、报价或 movement。
- crypto 与 investment ensure 上限统一为 100 项，与持仓快照的 100 项上限一致；修复了原 crypto 超过 20 项时的端到端断链。

## Agent 实现

- 新增 `finwealth_propose_investment_holding_snapshot`。
- 模型只能提交来源中明确出现的类型、代码、名称、市场、计价币和当前总数量。
- sidecar 先调用 investment ensure，完整验证返回的账户、身份字段与唯一 ID 映射，再把真实 ID 提交到既有 holding snapshot proposal。
- 返回缺项、重复身份、市场/类型/计价币不一致或模型传入伪 ID 时，在 snapshot HTTP 请求前失败。
- 工具仍只创建一个 atomic review group，不确认持仓、不采用报价。

## 回归

- Rust：复用缺 market 的旧 AAPL 标的并补 NASDAQ；创建 SSE 基金标的；补齐 USD 支持；幂等重放；计价币冲突；拒绝 `id` 和 crypto 类型；确认 holdings/movements 始终为空。
- crypto 容量回归：一次登记 21 个来源 symbol 成功，确认不再被旧 20 项上限阻断。
- Agent：AAPL 与 510300 先登记、再以服务端真实 ID 提交一次快照；伪 ID 在任何 HTTP 请求前失败；ensure 返回错误计价币时不提交 snapshot。
- 本地门禁：Rust 156 项、Agent 33 项、TypeScript check、OpenAPI/契约检查与格式检查均通过。

## 边界与部署

- 本批不修改 Flutter；未知工具名仍会使用前端现有通用活动文案，run 完成后会刷新待审核列表。
- 当前 public 最新报价 provider 仍主要覆盖 crypto 与法币 FX；新登记股票/基金在没有已保存报价时保留原始数量并报告缺报价，不伪造估值。
- 实现提交 `d1d3fba` 已推送 `origin/feat/integration-self-use` 并部署到 VPS；服务器端重新执行 Rust 156 项、Agent 33 项、TypeScript check/build 与生产依赖审计，审计为 0 个已知漏洞。
- 部署前账本与认证状态备份：`/var/backups/finwealth/20260730-210450Z`；Agent 状态备份：`/var/backups/finwealth-agent/20260730-210539Z`。
- 旧 Rust 与 Agent dist 回滚目录：`/opt/finwealth/rollback-20260730-210539Z`。
- 使用临时端口、临时账本和临时 Agent state 复用生产 Grok 连接，真实读取合成券商 PNG；AAPL 与 510300 的类型、市场、计价币和数量均精确匹配，`finwealth_propose_investment_holding_snapshot` 成功生成一个两项待审核组。
- 隔离验收确认账户仍以 CNY 展示并补入 USD 支持，确认前持仓为空，权威报价摘要前后相同；没有调用确认、批准或报价采用。
- 隔离服务、临时账本、会话、附件、源码构建目录和上传包均已清理；VPS 根分区恢复约 39 GB 可用。
- Rust/Agent 服务均为 active，公网 readiness 通过；未修改 Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
