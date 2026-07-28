# Pi Agent 控制中枢后端完成回执

日期：2026-07-28

## 分支与边界

- 分支：`feat/pi-agent-control-center`
- 基线：`0c55498`（`origin/feat/subscription-sync-integration`）
- 功能提交：`70553d0 feat(agent): add Pi control center backend`
- 契约补全：`b4a8745 fix(agent): formalize SSE and attachment retrieval`
- 网页报价候选：`ad371ae feat(agent): add reviewed web quote candidates`
- 工作区文档附件：`ddfdb54 feat(agent): support workspace document attachments`
- 自动任务与通知：`142951b feat(agent): schedule reminders and in-app notifications`
- 周期财务总结：`ebe1be9 feat(agent): schedule periodic financial summaries`
- 未修改 Flutter `lib/**`、Flutter `test/**` 或平台客户端。
- Claude 最新可见前端成果仍是 `origin/feat/ai-image-organization-ui @ 6abb256`；Pi Agent 前端任务另见 `2026-07-28-claude-pi-agent-frontend.md`。

## 已交付

1. Rust 公网网关：复用现有设备 bearer auth，代理 `/v1/agent/**` 到 loopback sidecar，注入 owner/ledger/device principal，不向 sidecar转发客户端 Authorization，支持 SSE。
2. 内部调用：sidecar 用 constant-time 校验的内部 token 调 Rust；Rust 将其绑定为 owner principal。Agent 不能用内部 token递归调用 Agent 代理。
3. Pi sidecar：真实 `@earendil-works/pi-coding-agent 0.82.1`、模型列表、主会话/多会话、归档、模型选择、JSONL session、排队运行、取消和可恢复 SSE cursor。
4. 财务 tools：读取 overview/accounts/movements/holdings/liabilities/subscriptions/DCA/pending review/quotes；刷新服务器已配置的结构化报价；账务写入只调用 draft 加 submit-review，没有 confirm/approve/direct-write tool。
5. 图片账单：multipart PNG/JPEG/WEBP，15 MiB；校验 MIME 与 magic，归档原件及工作副本，按账号隔离，原生传为 Pi `ImageContent`。
6. 幂等：Agent 所有 POST/PATCH 要求 `Idempotency-Key`，结果持久化；同 key 同请求重放原结果，不同请求返回 409。
7. 记忆：模型只能创建 `suggested` 通用记忆；用户经 API 批准后才成为 `active` 并注入后续提示。已明确禁止商户到账户映射和秘密记忆。
8. 工作区：替换 Pi 不受限的内置文件/shell tools。读写路径做 canonical containment；Linux shell 经 bubblewrap，仅挂载专属 workspace，并使用环境变量 allow-list。Windows 不做不安全降级。
9. 部署与备份：Node 22 systemd unit、环境样例、安装脚本、工作区 sandbox smoke、独立 Agent state/附件/session/模型凭据备份脚本和 VPS 文档。
10. 附件回读：提供归属校验后的安全元数据与原图接口，元数据不暴露存储路径；原图响应包含正确 MIME、SHA-256 ETag、private/no-store 与 nosniff，供历史消息和 App 重启后恢复预览。
11. SSE 正式契约：OpenAPI 明确 `run.queued`、`run.started`、`message.delta`、tool 与结束事件字段，并规定 `after` / `Last-Event-ID` 的 cursor 续接语义。
12. 网页报价候选：Agent 可把有来源和时间的网页报价/汇率保存为 `suggested`，只有用户调用审核接口 `apply` 后才经权威 `/v1/quotes/refresh` 写入；拒绝、提议和失败均不改变估值。
13. 自动任务与通知：持久化结构化报价、订阅到期扫描、DCA 到期检查和周期财务总结，失败一小时重试；订阅只生成待审核候选，DCA 不执行交易，总结只在主会话排队只读请求，通知仅保存在 App 内。

## 验证结果

- Rust：`cargo test`，145 passed / 0 failed。
- Node：TypeScript check/build；19 passed / 0 failed。
- Node production audit：0 vulnerabilities。
- `python tools/contract_check.py`：通过，OpenAPI 93 paths / 168 schemas。
- `git diff --check`、`cargo fmt --check`：通过。
- `tools/agent_local_smoke.ps1`：真实启动 Rust 与 Node；状态、会话、附件上传/安全元数据/原图响应头与字节、空模型 503 fail-closed 通过。
- `tools/agent_workspace_sandbox_smoke.sh`：WSL bubblewrap 边界通过，workspace 可写、宿主外部路径不可见。
- 新增 shell 脚本 `bash -n`：通过。
- 变更文件 credential-shaped literal 扫描：无命中；生产秘密未写入仓库。

## 尚未完成 / 不应误报

- 未在生产 VPS 安装、配置模型或重启现有服务；未读取或修改生产账本。
- 尚未配置真实 Pi `auth.json` / `models.json`，因此未调用真实付费模型完成端到端账单识别。
- PDF、CSV、XLSX、ZIP 与 TXT 已支持原样上传到 Agent 工作区，由 Agent 选择对应读取工具并交给模型理解；未另做固定账单解析器。真实模型端到端仍待生产配置后验证。
- 网页搜索可在隔离 shell 内完成，并已支持候选报价审核入库；真实模型在目标网站上的可访问性与端到端来源质量仍待生产配置后验证。
- App 内定时任务与通知已实现；系统级 push、模型周期报告、插件提议/审批/安装尚未实现。
- Flutter Agent 入口、Windows 右栏、Android 全屏、SSE UI、图片选择和记忆审批仍由 Claude 按任务单实现。
