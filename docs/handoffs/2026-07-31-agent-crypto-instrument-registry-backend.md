# Agent 加密标的登记后端回执

## 目标

修复交易所/钱包图片或文件中出现 BTC、ETH、USDT，但账本缺少对应 `instrumentId` 时，Agent 无法继续生成持仓快照的问题。

## 实现

- 新增幂等接口：`POST /v1/accounts/{accountId}/crypto-instruments/ensure`。
- 输入只允许 BTC、ETH、USDT；大小写与精确名称可规范化，重复项去重。
- 先复用已有标的；旧标的只有 `displayName` 时补 `symbol`/`market`；不存在时创建确定性 crypto Instrument。
- 自动把被复用标的的 `quoteCurrency` 加到账户 `supportedCurrencies`。
- 接口只写标的与账户元数据，不创建 holdings、cash balance、quote 或 movement。
- Pi Agent 新增 `finwealth_ensure_crypto_instruments`，要求先查询 accounts/instruments；工具执行后用返回的真实 ID 调 `finwealth_propose_holding_snapshot`。
- public provider 新增 BTC/ETH/USDT 交叉报价，例如 ETH/BTC 使用同一时点 USD 价格比值。

## 附带修复

本机/服务器配置 HTTP(S) 代理但 `NO_PROXY` 未含 loopback 时，Rust 到 loopback Agent sidecar 或 loopback AI provider 会错误走代理。现在这两类明确 loopback 端点强制 `no_proxy`；公网行情和公网模型仍遵循系统代理。

`tools/agent_local_smoke.ps1` 也显式隔离 localhost，并加入“登记三项标的后 holdings 仍为空”的真实双进程断言。

## 边界

- 不支持 DOGE 等其他资产；返回结构化 400，不猜 ticker。
- 登记标的不代表用户持有该资产；数量必须来自文件/用户输入并进入持仓快照审核。
- 不自动确认持仓，不自动采用报价，不改变余额。

## 验证

- Rust：152 passed。
- Node：31 passed；TypeScript check/build 通过。
- OpenAPI/contract check 通过。
- Rust + Node 本地双进程 Agent smoke 通过。
- `cargo fmt --check`、`git diff --check` 通过。

## 生产部署

- 集成提交 `6eb4375` 已部署到 VPS；Rust 与 Pi Agent systemd 服务均为 active。
- 部署前账本备份：`/var/backups/finwealth/20260730-164158Z`。
- 部署前 Agent 状态备份：`/var/backups/finwealth-agent/20260730-164158Z`。
- 代码回滚目录：`/opt/finwealth/rollback-20260730-165130Z`，同时保存上一版 Rust 二进制与 Agent 程序目录。
- 新 Rust 二进制先以生产环境文件独立执行配置校验，通过后才替换并重启服务。
- Agent 安装时重新执行 31 条 Node 测试、TypeScript 构建和生产依赖审计；测试全过且审计无已知漏洞。
- loopback 探针确认 `finwealth_ensure_crypto_instruments` 已进入实际运行的 Agent 构建，Agent 模型状态为 configured。
- 对生产 OKX 账户登记 BTC、ETH、USDT 时三项均复用已有标的，未创建或修补标的；操作前后该账户 holding 条目数不变。
- `check_vps_readiness.sh --public-base-url https://wuwaidut.com` 通过；未修改 Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
