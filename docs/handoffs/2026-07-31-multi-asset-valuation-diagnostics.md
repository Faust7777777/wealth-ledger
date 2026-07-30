# 多资产账户报价诊断与 Agent 部署回执

## 问题

结构化报价接口会对每个标的和 FX 目标返回独立错误，但持仓快照后的 sidecar 只向模型报告候选总数。`partial_success`、`offline` 和完整成功无法区分；例如 BTC 成功、SOL 与 USDT/CNY 失败时，模型看不到具体缺口。

## 修复

- 持仓快照报价结果新增请求标的数、请求 FX 数、实际候选数、lookup 状态与逐目标 errors。
- 成功项仍生成独立 `suggested` 候选；失败项不生成价格、不按 0 估值，也不撤销已经持久化的持仓审核组。
- 单目标交互式报价工具同步返回 lookup 状态与错误；只有没有结构化候选时才允许网页 fallback。
- sidecar 对 lookup errors 做结构化校验和边界限制，保留 target type、target ID、message 与 retryable。

## 真实多资产验收

新增 `tools/public_multi_asset_account_smoke.ps1`，使用临时服务和临时账本完成：

1. 创建 CNY 展示的 OKX holdings 账户。
2. 确定性登记 BTC、ETH、USDT、SOL；SOL 保留 USDT 市场计价单位。
3. 真实请求 CoinGecko、OKX 与 FX provider，取得四条标的报价及 USDT→CNY 的直接或两跳路径。
4. 确认 lookup 前权威报价仍为空。
5. 仅在测试明确写入报价并确认持仓组后，验证四项原始数量不变且分别形成 CNY `accountMarketValue`。

真实 smoke 通过：`BTC/ETH/USDT/SOL quantities retained and valued in CNY`。

## 门禁与部署

- 实现提交：`3e36375`，已推送 `origin/feat/integration-self-use`。
- Rust：`163 passed`。
- Agent：`39 passed`；TypeScript check/build 与 `npm audit --omit=dev` 通过。
- 契约检查、Python compile、`git diff --check` 通过。
- Agent state 备份：`/var/backups/finwealth-agent/20260730-232657Z`。
- 旧 Agent dist：`/opt/finwealth/rollback-agent-20260730-232657Z`。
- 新 dist 与 Linux 构建候选逐字节一致；Rust、Agent active，公网 readiness 通过。
- 本批未重启 Rust，未修改生产账本内容、Agent state、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。
