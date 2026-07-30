# Agent 加密资产快照 symbol 解析修复

## 生产诊断

- 只读取 Pi Agent 已脱敏的结构化日志和状态投影，没有输出消息正文、文件名、账户 ID、标的 ID、金额、数量或凭据。
- 最近一条完成的 JPEG 请求确实进入 Grok；accounts、instruments、holdings 查询和报价候选工具均成功。
- Grok 三次调用持仓快照均失败。隔离重放与账本引用检查确认：目标账户真实存在且是 holdings 型 exchange，但所有提交的 `instrumentId` 均不存在。
- 模型没有调用资产登记工具；伪 ID 中仍能识别出图片来源的 BTC、ETH、USDT symbol。
- 因此根因不是上传、vision、报价 provider 或 Flutter 刷新，而是模型在工具参数中自造了标的 ID。

## 修复

- `finwealth_propose_holding_snapshot` 的 Agent 参数从 `instrumentId + targetQuantity` 改为 `symbol + targetQuantity`，用于交易所和钱包的加密资产快照。
- sidecar 统一大写并校验 symbol、数量精度和重复项，先调用 `crypto-instruments/ensure`。
- sidecar 只接受 ensure 响应中的真实 symbol/ID 映射，再调用既有 holding snapshot proposal 接口。
- ensure 缺少任一 symbol、返回空 ID 或重复输入时 fail-closed，不提交快照。
- 模型继续不能生成 ID；底层 Rust 快照接口仍只接受真实 ID，Flutter 和 OpenAPI wire contract 不变。
- 工具仍只创建一个 atomic review group，不确认持仓、不写报价、不采用报价。

## 回归

- 生产中复现的旧参数形状（只交伪 `instrumentId`）现在会在任何 HTTP 请求前失败。
- `btc`/`ETH` 输入会先规范化并登记，再映射为服务端返回的两个真实 ID，只提交一次快照。
- ensure 响应漏掉 ETH 时只发生 ensure 请求，snapshot 请求为零。
- 真实模型 smoke 改为要求模型提交来源 symbol，不再要求模型编排或携带 ID。
- Agent 32 条测试、TypeScript check/build、Rust 155 条测试、OpenAPI/contract check 与 Rust↔Pi 双进程 smoke 全部通过。

## 边界

- 本批只修改 Agent sidecar、测试、smoke 与后端契约说明，不修改 Flutter。
- 非 crypto 的股票、基金持仓仍可走既有 App/Rust 真实 instrument ID 接口；本次 Pi 工具不自动登记或猜测非 crypto 标的，后续需要单独的匹配流程。

## 生产部署

- 集成提交 `1ca95e2` 已推送 `origin/feat/integration-self-use` 并部署到 VPS。
- Agent 状态备份：`/var/backups/finwealth-agent/20260730-201948Z`。
- 旧 sidecar 回滚目录：`/opt/finwealth/rollback-agent-20260730-202003Z`。
- VPS 安装阶段重新执行 bubblewrap 边界 smoke、32 条 Agent 测试、TypeScript check/build 与生产依赖审计；审计为 0 个已知漏洞。
- Rust/Agent 服务均为 active，公网 readiness 与 health 通过；生产 Grok 状态为 configured 且模型数量大于零。
- 从生产已安装 JS 直接读取工具 schema，确认 position 必须包含 `symbol`，不存在 `instrumentId` 参数。
- 部署后结构化日志中没有 run/tool error；未触发真实模型请求、未创建测试账户、标的、持仓或待审核项。
