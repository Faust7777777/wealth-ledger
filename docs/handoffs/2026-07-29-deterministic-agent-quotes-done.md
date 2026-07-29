# Pi Agent 确定性报价链路后端回执

日期：2026-07-29

## 已交付

1. Rust 新增只读 `POST /v1/quotes/lookup`。它复用显式配置的结构化 provider，只接受 `instruments` 与 `currencyPairs`，返回报价、汇率和逐项错误，不写账本、不改变估值、不要求 `Idempotency-Key`。
2. lookup 拒绝调用方夹带 `quotes`、`fxRates` 或其他字段，不能把手工值伪装成结构化查询结果。
3. Pi 新增 `finwealth_lookup_quote_candidate`：标的报价走已配置行情源，法币汇率走结构化汇率源；成功结果统一保存为 `suggested` 候选。
4. `finwealth_suggest_quote` 网页来源被收紧为显式 fallback：同一目标必须先经过结构化 lookup，且 lookup 无结果或失败后才可调用。
5. Agent 不再暴露可直接写账的 `finwealth_refresh_quotes` 工具。用户采用候选仍通过既有、幂等的审核入口写入权威报价。
6. `quote_refresh` 定时任务改为只读 lookup，并把结果保存成候选；测试确认不会调用报价 writer。
7. Flutter 仅增加结构化查询工具的活动文案 `正在查询报价…`，没有新增页面或常驻说明。

## 固定边界

- USD/CNY 等法币汇率优先使用结构化 provider。
- BTC、ETH、USDT 等已支持标的优先使用结构化行情源。
- 网页检索只允许在同目标结构化查询明确失败后发生。
- 结构化与网页两条路径都只生成 `suggested`；采用前权威报价与估值不变。
- Grok 是当前唯一模型选择；本轮没有增加模型 fallback。

## 验证

- `python tools/contract_check.py`：通过，96 paths / 171 schemas。
- Rust：`cargo fmt --check` 通过，149 passed / 0 failed。
- Agent：TypeScript build 通过，27 passed / 0 failed。
- Flutter：analyze 无问题，385 passed / 85 skipped / 0 failed。
- `tools/frontend_local_server_smoke.ps1`：9 条真实 Rust 联调通过。
- `tools/frontend_agent_smoke.ps1`：Rust + Node 真实进程联调通过。
- `git diff --check`：通过。

## 生产验收

- Rust 与 Agent sidecar 已从 `c9688c5` 部署；部署前分别备份了账本/认证状态与 Agent 状态，并保留旧二进制和旧 Agent dist。
- 生产原配置仍为 `FINWEALTH_QUOTE_PROVIDER=none`，已窄改为 `public`；未修改 sub2api、Cloudflare、Caddy 或同机中转服务。
- `check_vps_readiness.sh --public-base-url https://wuwaidut.com`：通过。
- `tools/agent_vps_web_quote_smoke.py`：真实 Grok 调用结构化 USD/CNY 工具，不调用 bash 或网页候选工具，只生成一条待审核候选；候选前后权威报价摘要完全不变。
