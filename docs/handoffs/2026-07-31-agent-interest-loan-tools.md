# Agent 固定收益与贷款工具部署回执

## 现状审计

Rust 后端已有真实实现：固定收益支持单利、月/季/年复利、360/365 日计数、起息与到期日；贷款支持未偿本金应计、计划还款的本金/利息拆分、负摊销、到期气球款以及审核确认后的原子更新。缺口是 Pi Agent 无法访问这些专用查询和 proposal 入口。

## 新增工具

- `finwealth_query_interest_positions`：按日期查询固定收益或贷款应计结果。
- `finwealth_query_loan_schedule`：查询 1–360 期还款投影。
- `finwealth_propose_yield_interest`：按 holding 已配置条款生成收益利息审核组。
- `finwealth_propose_loan_interest`：按负债 account 已配置条款生成贷款利息审核组。
- `finwealth_propose_loan_payment`：把付款日前利息与本次还款生成同一原子审核组；金额省略时使用计划还款额。

Agent 不能提交本金、年利率、计息方法或自算利息。写工具只调用 proposal 端点，工具集合中没有确认/批准接口；确认前不改变现金、持仓或负债余额。条款未配置时由 Rust 返回具体错误，模型不得猜测。

## 验证与部署

- 实现提交：`a13d495`，已推送 `origin/feat/integration-self-use`。
- Rust 全量：`163 passed`，覆盖真实计息、审核、拒绝、确认、还款拆分和会计恒等式。
- Agent 全量：`40 passed`；新增测试逐个验证五个工具的 URL、body、编码、幂等键，并确认没有 `/confirm` 请求。
- TypeScript check/build、`npm audit --omit=dev`、契约检查、Python compile 与 `git diff --check` 通过。
- Agent state 备份：`/var/backups/finwealth-agent/20260730-233749Z`。
- 旧 Agent dist：`/opt/finwealth/rollback-agent-20260730-233749Z`。
- 新 dist 与 Linux 构建候选逐字节一致；Rust、Agent active，公网 readiness 通过。
- 本批未重启 Rust，未修改生产账本内容、Agent state、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 前端配合

Flutter 仍需提供固定收益条款与贷款条款的编辑入口，并把上述五个 tool activity 名称映射成低强调中文活动行；在此之前可通过已有 HTTP API 配置条款，Agent 负责查询和生成审核记录。
