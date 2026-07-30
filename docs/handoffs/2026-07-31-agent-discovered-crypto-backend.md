# Agent 任意加密资产登记后端回执

## 目标

让 Pi Agent 从交易所或钱包的用户消息、图片和文件中识别到新资产代码时，可以取得服务端生成的真实 `instrumentId` 并继续创建待审核持仓快照，不再局限于 BTC、ETH、USDT。

## 实现

- 保持 `POST /v1/accounts/{accountId}/crypto-instruments/ensure` 向后兼容，将 `symbols` 扩展为 1–20 个受约束的加密资产代码。
- 服务端统一大写、去重并按 crypto 类型和代码复用标的；非 crypto 同名标的不会被误用，ID 冲突时由服务端确定性避让。
- BTC、ETH、USDT 继续使用既有名称与 public provider 语义；其他标的以代码作为初始显示名，标记为 `finwealth_agent_discovered_crypto`。
- Agent 工具允许登记来源中实际出现的加密资产，但禁止把 symbol 当作 ID、禁止补造来源中没有的资产。
- 登记只修改标的与账户元数据，不创建 holding、余额、报价或 movement。持仓数量仍只通过一个 atomic group 进入待审核。
- 新标的没有结构化行情时保留原始数量；Agent 可走既有报价候选流程，但不得自动采用。

## 诊断与联调

- Agent 向 journald 输出结构化运行阶段：run 开始/完成/失败、工具开始/完成、错误码、附件数量与 MIME；不记录消息正文、文件名、金额、附件内容、token 或模型凭据。
- `agent_local_smoke.ps1` 使用 BTC、ETH、USDT、SOL 验证任意标的登记，并断言登记后 holding 仍为空。
- `agent_real_model_smoke.ps1 -CreateHoldingSnapshot` 新增 OKX 风格四资产图片路径，要求模型查询账户/标的/持仓、登记缺失标的、一次生成四项待审核快照，并断言确认前 holding 为空。
- real-model smoke 同时补齐 loopback `NO_PROXY`，避免本机系统代理劫持就绪探针。

## 验证

- Rust：152 passed。
- Node：31 passed；TypeScript check/build 通过。
- OpenAPI/contract check 通过。
- Rust + Node 本地双进程 Agent smoke 通过。
- `cargo fmt --check`、PowerShell 语法解析、`git diff --check` 通过。
- 真实模型 smoke 已进入模型请求阶段；本机旧 LORE 通道返回外部 `model_not_found`，未到工具执行。生产 Grok 配置不使用该旧模型，部署后通过真实会话补最终验收。

## 边界

- 内置 public provider 仍只覆盖明确支持的 BTC、ETH、USDT；任意新代码不会被伪造报价。
- 本轮不修改 Flutter；Claude 的 OKX 前端修正分支仍待后续处理。

## 生产部署

- 集成提交 `2623509` 已部署到 VPS，Rust 与 Pi Agent systemd 服务均为 active。
- 部署前账本备份：`/var/backups/finwealth/20260730-192715Z`。
- 部署前 Agent 状态备份：`/var/backups/finwealth-agent/20260730-192715Z`。
- 代码回滚目录：`/opt/finwealth/rollback-20260730-193013Z`，包含上一版 Rust 二进制与 Agent 程序目录。
- 新 Rust 二进制通过生产配置校验后原子替换；Agent 安装重新执行 31 条测试、TypeScript 构建和生产依赖审计，审计无已知漏洞。
- 生产 Agent 状态为 configured；现有 OKX 的 BTC、ETH、USDT 均被复用，探针前后 holding 条目数不变。
- 公网 readiness 通过；未修改 Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
