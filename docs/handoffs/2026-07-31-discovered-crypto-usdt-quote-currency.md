# 非内置 crypto 的 USDT 计价修复

## 问题

任意 crypto 登记与 OKX 公共报价已经存在，但新标的此前会继承账户默认币种。账户以 CNY、USD 或 BTC 展示时，SOL 可能被登记为 SOL/CNY、SOL/USD 或 SOL/BTC，而结构化 OKX provider 当前只查询 SOL-USDT，导致标的登记成功后仍无法报价。

## 修复

- BTC、ETH、USDT 保持现有行为，可按账户默认币种使用 CoinGecko 直接或交叉报价。
- 其他新登记 crypto 一律以 USDT 作为 `Instrument.quoteCurrency`。
- ensure 自动把 USDT 加入账户 `supportedCurrencies`，但不改变账户 `defaultCurrency`。
- 原始 holding quantity 始终保留；账户汇总继续通过 `crypto/USDT → USDT/USD → USD/CNY` 等最多三跳路径折算。
- 既有已登记标的不被静默改写 quoteCurrency，避免破坏历史报价或 movement 引用。

## 回归

- CNY 默认的 exchange 登记 ETH 与 SOL：ETH 仍可用 CNY，SOL 必须是 USDT，账户支持币种成为 CNY/BTC/USDT 的真实并集。
- CNY 默认的 exchange 登记 SOL、确认持仓后，在 SOL/USDT、USDT/USD、USD/CNY 三段数据齐备时正确汇总为 CNY；缺 Quote 与缺 FX path 分别保持结构化问题状态。

## 门禁与部署

- Rust 全量 `155 passed`；Agent 全量 `32 passed`；TypeScript check/build、OpenAPI/契约检查和 `cargo fmt --check` 均通过。
- 实现提交 `931185d` 已推送到 `origin/feat/integration-self-use`。
- VPS 使用 Rust 1.97.1 从该提交归档重新执行 `cargo test --locked` 与 `cargo build --release --locked`，服务器侧同样为 `155 passed`。
- 候选二进制先通过生产配置、真实账本和 auth state 离线校验，再执行替换；未为验收创建 SOL、持仓、报价或其他生产记录。
- 部署前账本与认证状态备份：`/var/backups/finwealth/20260730-203712Z`。
- 旧 Rust 二进制回滚目录：`/opt/finwealth/rollback-20260730-203712Z`。
- Rust 与 Agent 服务均为 active；`check_vps_readiness.sh --public-base-url https://wuwaidut.com` 和公网 health 通过。
- VPS 临时源码归档与构建目录已清理；部署后根分区约有 38 GB 可用。未修改 Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
