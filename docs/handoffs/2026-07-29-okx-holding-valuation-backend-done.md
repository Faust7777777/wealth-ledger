# OKX 多资产持仓与估值修复回执

## 代码

- 集成提交：`95016d4`，已推送 `origin/feat/integration-self-use`。
- 旧 crypto 标的缺少 `symbol` 时，只对 BTC/ETH/USDT 从精确显示名恢复 provider symbol。
- public provider 支持 BTC/ETH/USDT 自计价单位报价 `1`，并用 CoinGecko 生成 crypto FX；BTC→USD→CNY 路径已覆盖。
- `Holding` 新增 `accountMarketValue`：`marketValue` 继续使用账本本位币，账户页可使用账户默认折算单位，不再混币种求和。
- Claude 前端任务单：`2026-07-29-claude-okx-holding-corrections.md`。

## 生产

- 部署前备份：`/var/backups/finwealth/20260729-160144Z`。
- 旧二进制回滚：`/opt/finwealth/rollback-20260729-160245Z`。
- Rust 服务已部署 `95016d4`，systemd active。
- OKX 元数据已修复：BTC 补 symbol，新增 ETH/USDT 标的，账户支持的计价单位扩为 3 项；未修改任何持仓数量。
- 发现现金 BTC 与 BTC holding 数量完全相同。已生成一条“移除重复现金 BTC”的待审核 adjustment；未自动确认、未直接改余额。
- 生产报价刷新结果：success，1 条标的报价、2 条 FX、0 错误；当前持仓同时产出 CNY `marketValue` 与账户单位 `accountMarketValue`。

## 门禁

- Rust：151 passed。
- OpenAPI/contract check：通过。
- `local_ledger_smoke.py`：通过。
- `cargo fmt --check`、`git diff --check`：通过。

## 尚待前端

- Flutter 映射并使用 `accountMarketValue`。
- 全部不可计价时合计显示 `—`，不能显示 0。
- 报价错误不得暴露内部英文。
- 快照确认后精确刷新 `holdingsByAccountProvider(accountId)`。
- 账户表单区分“账户折算单位”和“交易计价单位”。

