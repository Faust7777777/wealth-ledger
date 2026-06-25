# BACKEND_INTERFACE_IMPLEMENTATION_PLAN_V1

状态：接口线执行计划。  
用途：在 Claude 前端返工期间，Codex 继续推进后端/接口方向时使用。  
边界：不接手 Flutter UI，不改前端页面，不实现真实交易/转账能力。

## 0. 当前已完成

契约入口：

- `README.md`
- `DATA_SCHEMA_V1.md`
- `AI_PROPOSAL_SCHEMA_V1.md`
- `LOCAL_LEDGER_FORMAT_V1.md`
- `QUOTE_RATE_CONTRACT_V1.md`
- `SYNC_API_DRAFT.md`
- `APPLICATION_INTERFACES_V1.md`
- `HTTP_API_V1.md`
- `openapi_v1.yaml`

OpenAPI 当前状态：

- OpenAPI 版本：3.1.0
- path 数：54
- schema 数：94
- 已确认无禁止端点：
  - `/transfers/execute`
  - `/broker/*`
  - `/ai/auto-approve`
  - `/ai/write-ledger-directly`
  - `/coupons/plan`

Mock API 当前状态：

- `tools/mock_api_server.py` 已可启动。
- 默认只绑定 `127.0.0.1:8787`。
- 只读 `docs/contracts/examples/*.json`。
- 不写文件，不持久化 POST 副作用。
- 本地 smoke 覆盖：
  - `GET /v1/health`
  - `GET /v1/portfolio/overview?scenario=degraded`
  - `POST /v1/dca/reminders/{id}/mark-executed-as-proposal`
  - 禁止端点 `POST /v1/broker/orders` 返回 403。

Server smoke 当前状态：

- `tools/server_smoke.py` 已可运行。
- 会临时启动 mock API、Python dev server 与 Rust server。
- 覆盖：
  - mock degraded overview。
  - mock DCA proposal。
  - mock quote stale/offline cached。
  - dev login。
  - dev empty bootstrap。
  - dev sync empty changes。
  - rust degraded overview。
  - rust DCA proposal。
  - rust dev login。
  - 禁止端点 403。

Dev server skeleton 当前状态：

- `server/dev_server.py` 已可运行。
- 默认只绑定 `127.0.0.1:8788`。
- 仅内存/空响应，不写数据库。
- 无真实 auth；只返回 `dev_*_not_for_production` token。
- 不接真实 AI / 行情 / 同步。
- 禁止端点同样返回 403。

Rust 环境当前状态：

- Rustup stable 已安装。
- 默认工具链：`stable-x86_64-pc-windows-gnu`。
- MSVC 工具链仍保留。
- MinGW 已通过 Scoop 安装，用作 GNU 链接器。
- `rustfmt` / `clippy` / `rust-analyzer` 已可用。

Rust/Axum server skeleton 当前状态：

- `server-rs/` 已创建。
- 默认只绑定 `127.0.0.1:8790`。
- 无真实 auth；只返回 `dev_*_not_for_production` token。
- 不接真实 AI / 行情 / 同步。
- 禁止端点同样返回 403。
- 已通过：
  - `cargo fmt --manifest-path server-rs/Cargo.toml --check`
  - `cargo check --manifest-path server-rs/Cargo.toml`
  - `cargo test --manifest-path server-rs/Cargo.toml`
  - `cargo clippy --manifest-path server-rs/Cargo.toml -- -D warnings`
- 当前 Rust 路由回归测试数：7。
- Rust 路由测试覆盖：
  - localhost-only bind guard。
  - contract examples parse。
  - `GET /v1/health`。
  - degraded portfolio overview pending summary。
  - DCA mark-executed 只返回 `pending_review` proposal，并包含不下单/不转账提示。
  - 禁止产品边界端点返回 403。
  - AI proposal 包含 old → new diff。

## 1. 接口线优先级

### P1：契约一致性

目标：让 Markdown 契约与 OpenAPI 不发散。

任务：

1. 为 `openapi_v1.yaml` 增加 contract lint 脚本。
2. 检查 `DATA_SCHEMA_V1.md` 与 OpenAPI schema 命名一致。
3. 检查 `HTTP_API_V1.md` 中列出的 endpoint 都存在于 OpenAPI。
4. 检查禁止 endpoint 不存在于 OpenAPI。

### P2：本地 core 边界

目标：明确本地账本 core 的接口，不实现数据库。

候选产物：

- `CORE_PORTS_V1.md`
- `core_ports_v1.pseudo.ts` 或 `core_ports_v1.rs.md`

范围：

- LedgerRepository port
- QuoteProvider port
- AiProvider port
- SyncClient port
- Clock / IdGenerator / DecimalValidator port

不做：

- SQLite 表结构
- drift
- Rust FFI
- 加密实现

### P3：服务端最小接口骨架

目标：未来 VPS 服务可以从 OpenAPI 生成 stub。

候选技术：

- Rust Axum
- TypeScript Hono/Fastify
- Dart server 不优先

当前建议：

优先 Rust Axum，因为未来本地账本 core 也可能用 Rust，领域模型可以复用；但在正式实现前先完成接口 lint 与 core ports。

不做：

- 登录真实落库
- 真实同步
- 真实行情
- 真实 AI

## 2. 与前端的分工

Claude 前端可读取：

- `DATA_SCHEMA_V1.md`
- `AI_PROPOSAL_SCHEMA_V1.md`
- `APPLICATION_INTERFACES_V1.md`
- `openapi_v1.yaml`

前端第一阶段仍然只做：

- Repository interface
- `real_local` 空实现
- `debug_fixture` 隔离实现
- 空数据 UI
- DEMO 标记

前端不应该：

- 直接依赖 HTTP API
- 自创正式字段
- 接真实 VPS
- 接真实 AI
- 接真实行情

## 3. 接口不变量

这些规则后续实现必须持续满足：

1. AI 只产 proposal，不直接写账。
2. atomic group 是最小确认单位。
3. DCA 的“记录已执行”只生成候选记录，不下单、不转账。
4. debug fixture 不同步、不写正式账本。
5. confirmed movement 不静默覆盖，优先 correction。
6. `unpriceable` 不按 0 计入净值。
7. 负债账户负数不是异常。
8. 消费/优惠券不是主功能，只解释资产变化。
9. 服务端不提供交易权限接口。

## 4. 下一步建议

下一步应该做 P1：契约一致性脚本。

建议新增：

```text
tools/contract_check.py
```

检查项：

- `openapi_v1.yaml` 能被解析。
- OpenAPI 没有禁止端点。
- `HTTP_API_V1.md` 的 endpoint 在 OpenAPI 中存在。
- `README.md` 引用的契约文件都存在。

该脚本只读文件，不接网络，不改前端。

当前 P1 已完成：

```bash
python tools/contract_check.py
python -m py_compile tools/contract_check.py tools/mock_api_server.py tools/server_smoke.py server/dev_server.py
python tools/server_smoke.py
cargo fmt --manifest-path server-rs/Cargo.toml --check
cargo check --manifest-path server-rs/Cargo.toml
cargo test --manifest-path server-rs/Cargo.toml
cargo clippy --manifest-path server-rs/Cargo.toml -- -D warnings
```

进入 P2/P3 前的建议：

1. 前端先使用 `real_local` 空账本和 `debug_fixture` 隔离实现。
2. 如果需要 HTTP 联调，再使用 `tools/mock_api_server.py`。
3. 真实服务端 skeleton 可以从 `openapi_v1.yaml` 开始，但第一版只做内存/空响应，不接真实存储。
