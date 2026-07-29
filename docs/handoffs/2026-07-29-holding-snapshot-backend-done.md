# 多资产持仓快照后端回执

## 实现

- 新增 `POST /v1/accounts/{accountId}/holding-snapshot-proposals`。
- 同一请求的全部变化项共用一个 atomic group，每项保存 previous/target/delta movement。
- 未变化项进入 `skippedPositions`；全部未变化返回冲突，不制造空候选。
- 输入、账户、标的、计价币种、pending adjustment 和 pending interest 在落盘前统一校验。
- 整组沿用既有确认/拒绝机制；确认前不改变 holdings，确认失败不会部分落盘。
- 新增 Agent 工具 `finwealth_propose_holding_snapshot`。它要求先查真实账户和标的，只能生成待审核组，没有确认或报价采用能力。

## 边界

- 没有重做 Account/Holding/Instrument 模型。
- 没有自动创建标的、自动采用报价或自动确认持仓。
- 没有修改 Flutter 前端和生产账本数据。

## 验证与部署

- Rust 全量 150 条通过；Node 全量 29 条通过；TypeScript check/build、OpenAPI 契约门禁和 `git diff --check` 通过。
- 已部署提交 `6a4c7e2` 的 Rust 服务与 Agent sidecar；loopback、公网 health 及两个 systemd unit 正常。
- 生产只做了不存在账户的无写入路由探针，返回 404；已核实 Agent 构建包含 `finwealth_propose_holding_snapshot`。
- 部署前账本备份：`/var/backups/finwealth/20260729-112016Z`。
- 部署前 Agent 状态备份：`/var/backups/finwealth-agent/20260729-112016Z`。
- 代码回滚副本：`/opt/finwealth/rollback-20260729-112016Z`。
- 未修改 Caddy、Cloudflare、sub2api、中转站配置或生产账本内容。
