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
- 真实模型联调与终态兼容修复：`38936d3` 至 `258b589`。
- 隔离文档读取：`ededc1f`、`ffcf560`、`ec60f41`（PDF/XLSX 在模型运行前确定性提取）。
- 调度与取消恢复：`81de050`、`8846108`。
- 生产公网报价 smoke：`12e6391`；跨重启自动任务 smoke：`3aa9f70`。
- 公网路由与部署恢复：`3130234`、`90be932`、`74f3656`、`ea60b12`。
- 后端功能提交未直接修改 Flutter；Claude 的自动任务/通知 UI 已通过 `a5cd42c` 合入本集成线。
- Claude 的报价候选紧凑化与非图片附件前端分支 `feat/pi-agent-frontend-followup@6d34fc3` 也是当前集成线祖先，无需再次合并。

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
13. 自动任务与通知：持久化结构化报价、订阅到期扫描、DCA 到期检查和周期财务总结，失败一小时重试；订阅只生成待审核候选，DCA 不执行交易。财务总结等待模型终态后才记成功，进程重启会把中断运行落为可重试失败，通知仅保存在 App 内。
14. 文档解码：PDF 原文件固定经 bubblewrap + `pdftotext`，XLSX 固定经 bubblewrap + Python 标准库 `zipfile`/XML 提取单元格；提取结果作为不可信上下文交给模型理解。原文件仍保存在用户专属 Agent 工作区，没有固定账单字段 parser。

## 验证结果

- 最新集成线 `69640fd` 全量复跑：Flutter 289 passed / 67 skipped，format 105 files / 0 changed，analyze 0 issues；Rust 145 passed；Node TypeScript check/build 与 24 passed 全绿。
- Node production audit：0 vulnerabilities。
- `python tools/contract_check.py`：通过，OpenAPI 93 paths / 168 schemas。
- `git diff --check`、`cargo fmt --check`：通过。
- `tools/agent_local_smoke.ps1`：真实启动 Rust 与 Node；状态、会话、附件上传/安全元数据/原图响应头与字节、空模型 503 fail-closed 通过。
- `tools/agent_workspace_sandbox_smoke.sh`：WSL bubblewrap 边界通过，workspace 可写、宿主外部路径不可见。
- 新增 shell 脚本 `bash -n`：通过。
- 变更文件 credential-shaped literal 扫描：无命中；生产秘密未写入仓库。
- `tools/agent_real_model_smoke.ps1`：使用临时账本、临时 Pi 目录和环境变量引用的模型凭据，真实验证 Rust 代理、LORE OpenAI-compatible 模型、`finwealth_query` 工具、SSE delta/tool/completion 事件及周期财务总结；通过后删除全部临时状态。脚本不输出模型回答、密钥、模型 ID或端点。
- 同一 smoke 的 `-IncludeTextAttachment` 已真实上传 CSV，经工作区相对路径交给模型；模型调用 `read` 后返回只存在于文件内的随机标记，同时继续调用 `finwealth_query`。这验证的是“原文件进入 Agent 工作区，由模型选工具读取”，不是固定账单解析器。
- 同一 smoke 的 `-IncludeVisionAttachment -CreateVisionDraft` 已真实生成并上传含商户、时间和 CNY 88.20 的测试票据图。模型原生读取图片、查询临时账户并调用 `finwealth_propose_movement`；最终恰好生成 1 条 pending proposal，账户确认余额保持 100.00，测试全程不调用 approve/confirm。
- 真实视觉联调发现模型会给纯现金 expense 分录附带多余 `instrumentId`。sidecar 现在只对 expense/fee/income/dividend/interest 这类纯现金提案确定性移除该可选字段；账户、金额、币种、方向、角色和时间继续由账本严格校验，buy/sell 等持仓腿不做此归一化。
- 真实联调发现并修复 Pi 终态兼容问题：provider 只在最终 `message_end` 给出文本时会补齐缺失 delta；中间自动重试的 `stopReason=error` 不再覆盖后续成功终态；真正最终的模型错误和取消分别落为 `agent_model_request_failed` / `agent_run_aborted`，不再产生“成功但正文为空”的消息。
- 生产 VPS Agent 运行代码已部署到 `8846108`，服务器源码同步到 `3aa9f70`。`tools/agent_vps_document_smoke.py` 使用生产配置的真实模型验证 PDF 与 XLSX：两者均从隔离工作区确定性提取，模型返回只存在于合成文件中的随机标记，工具事件分别为 `finwealth_read_pdf_text` 和 `finwealth_read_xlsx_text` 且无错误。
- `tools/agent_vps_web_quote_smoke.py` 验证真实模型经隔离 `bash` 读取公开 USD/CNY 报价并生成恰好一条 `suggested` 候选；权威报价摘要前后相同，临时用户状态已清除。
- `tools/agent_vps_automation_restart_smoke.py` 用独立端口和 `/tmp` 状态验证：计划在 sidecar 停机期间到期，重启后真实模型完成总结、推进下次时间并生成 `action=agent` 通知；临时状态已清除。
- 合并 Claude 自动任务 UI 后，Flutter format/analyze 与全量测试、Rust 145 条、Node 24 条、契约检查、两套真实本地 smoke 和 Windows readiness 均通过。
- 通用服务器客户端已从干净的 `e41b4d1` 重新构建，运行时 endpoint/auth readiness 18 条与包完整性检查通过。Windows zip 为 `dist/finwealth-1.0.0+1-20260728-163344-windows-server-client-x64.zip`（SHA-256 `278b919c3cb41eb814e97dc1501aa8003b2c5096115ef207f1a41c1c79604701`）；Android debug APK 为 `dist/finwealth-1.0.0+1-20260728-163454-android-server-client-debug.apk`（SHA-256 `1f6e12096870cf6adb2795ce07e538d75c7cedd9466e0348a6c51d9363b2a329`）。两者启动时填写 `https://wuwaidut.com`。
- VPS 源码与 Agent 已部署到 `ea60b12`。完整安装脚本在人工构造的“socket inactive、proxy service active”状态下能自行恢复 `finwealth-docker-proxy@172.19.0.1:8791.socket`，bridge `/v1/health` 返回 200。
- 共享 Caddyfile 仅在根域 `@finwealth` matcher 中增加 `/v1/agent/*`，原子更新备份为 `/home/opc/sub2api-deploy/Caddyfile.before-finwealth-agent-20260728T082624Z`。工具会验证候选配置、重启单文件 bind mount 的 Caddy 容器并核对实际加载内容；失败会恢复备份。`sub2api.wuwaidut.com`、Cloudflare Access/2FA 与中转站容器配置均未修改。
- 公网无凭据反馈环：`/v1/health` 为 200，`/v1/agent/status` 为 Rust 401（不再落到中转站 404），`/v1/models` 继续返回中转站既有 401。VPS 上 `finwealth-server`、`finwealth-agent` 和 bridge socket 均正常；Agent 状态最新备份为 `/var/backups/finwealth-agent/20260728-081043Z`，归档和 manifest 校验通过。
- 使用本机 App 的 DPAPI 加密既有会话完成公网只读验收；过期时沿正式 `/v1/auth/refresh` 旋转并重新加密保存，全程不输出 token 或响应内容。`/v1/agent/status`、`/v1/agent/automations`、`/v1/agent/notifications` 均返回 200。
- VPS `tools/check_vps_readiness.sh --public-base-url https://wuwaidut.com` 通过，覆盖 loopback bind、required auth、Host allow-list、持久化与公网 health。

## 尚未完成 / 不应误报

- 生产模型已配置在服务器受限环境文件中，但任何模型凭据、模型端点和模型 ID 都没有写入仓库或回执。
- PDF、CSV、XLSX、ZIP 与 TXT 均原样上传到 Agent 工作区。PDF/XLSX 的格式解码现在由 sidecar 确定性完成，语义理解仍由模型完成；没有固定账单字段 parser。
- 网页搜索、候选生成和“建议不改变权威估值”已在生产真实模型验证；不同网站的长期可用性仍取决于外部站点。
- App 内自动任务、通知和周期模型报告的前后端均已合入；系统级 push、插件提议/审批/安装不在当前用户需求范围，尚未实现。
- Android 36.1 AVD 已完成生产连接、过期会话五态、重新登录、主账本、历史 XLSX chip、输入法 resize、返回键与 CSV 草稿附件的真实交互验收。最终 APK 为 `dist/finwealth-1.0.0+1-20260728-194850-android-server-client-debug.apk`（SHA-256 `4edba008b27cd98da961154ebacf96fd9d100b9e82ff9338d890dc81785151c3`）。
- Android 会话菜单发布阻断已由 `fix/agent-session-menu-touch@24142fb` 修复并合入。Android 36.1 AVD 设备版 integration test 9/9 通过：真实 overlay 触摸能够切换会话及其快照，菜单事件不进入 composer，返回键、新建、模型选择、长列表和窄屏 `41 B` 均通过。
- 断线 cursor 续接和正文去重已有专项自动化；本次 AVD 飞行模式没有让既有 SSE TCP 及时失败，故真机断线/恢复仍未验收通过。Windows 右栏、自动任务/通知页面也仍待最终人工目验。
