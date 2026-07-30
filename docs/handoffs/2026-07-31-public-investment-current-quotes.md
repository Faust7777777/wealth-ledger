# 股票与基金结构化当前报价

## 问题

券商截图已经能由 Agent 登记 equity/fund 标的并生成待审核持仓快照，但生产使用的 `FINWEALTH_QUOTE_PROVIDER=public` 只覆盖 crypto 与法币 FX。AAPL、510300 等标的能够保留原始数量，却无法从结构化 lookup 获得当前报价。

## 实现

- `public` 现在是组合 provider：
  - BTC/ETH/USDT：CoinGecko；
  - 其他 USDT 计价 crypto：OKX 公共现货 ticker；
  - equity/fund 当前价：Yahoo chart；
  - 传统法币 FX：Frankfurter/ECB。
- 报价目标现在保留 Instrument.market；股票/基金只按明确市场映射：
  - NASDAQ/NYSE/AMEX/ARCA：保持原 symbol；
  - SSE/XSHG：六位数字代码加 `.SS`；
  - SZSE/XSHE：六位数字代码加 `.SZ`。
- 未知市场、不安全代码、返回币种与 `quoteCurrency` 不一致、非正数价格、无效市场时间全部逐项失败，不猜测市场或币种。
- 单项网络或数据错误不会阻断其他报价目标。
- lookup 仍然只读；结果只供 Agent 生成 `suggested` 报价候选，采用前不写权威报价、不改变估值。
- Agent 投资快照工具提示补充规范市场代码，但仍要求市场来自可验证来源，不根据证券代码猜测。

## 回归与真实验证

- Rust 全量 `160 passed`；Agent 全量 `33 passed`。
- TypeScript build、npm production audit、OpenAPI/契约检查、格式与 `git diff --check` 全绿，审计为 0 个已知漏洞。
- 新增 `tools/public_investment_quote_smoke.ps1`：临时本地账本真实查询 AAPL 与 510300，验证 USD/CNY、正数报价和 Yahoo 来源，并确认 lookup 前后 `/v1/quotes` 都为空。
- VPS 候选使用临时端口和临时账本重复同一真实联网验证，两条结构化报价均成功，权威报价前后为空；临时服务与账本已清理。

## 部署

- 实现提交 `4259c2f` 已推送 `origin/feat/integration-self-use` 并部署到 VPS。
- VPS 从提交归档使用 Rust 1.97.1 重新执行 Rust 160 项、Agent 33 项、release build 与 production audit。
- 候选二进制先通过生产配置、真实账本与 auth state 离线校验，再执行替换。
- 部署前账本/auth 备份：`/var/backups/finwealth/20260730-213036Z`。
- 部署前 Agent 状态备份：`/var/backups/finwealth-agent/20260730-213037Z`。
- 旧 Rust 与 Agent dist 回滚目录：`/opt/finwealth/rollback-20260730-213105Z`。
- Rust/Agent 服务均为 active，公网 `https://wuwaidut.com` readiness 通过；安装文件与候选逐字节一致。
- VPS 临时源码、上传归档和隔离账本已清理，根分区约 39 GB 可用。
- 未修改 Flutter、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 仍未覆盖

- `other` 类型、港股及其他交易所尚未加入确定性映射；在明确契约前继续逐项失败。
- `public` 仍只提供当前价，不提供历史行情；历史价格继续要求独立 `yahoo` provider。
- 报价候选需要用户在 App 内采用后才进入权威报价并参与估值。
