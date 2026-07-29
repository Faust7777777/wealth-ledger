# 2026-07-28 Pi Agent 控制中枢前端 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-28-claude-pi-agent-frontend.md`。

基线：`origin/feat/pi-agent-control-center @ 4c9d3af`（含附件/SSE 契约 `b4a8745`）。
分支：`feat/pi-agent-frontend`，独立工作树 `finwealth-pi-frontend`。
边界核对：`git status`/`git diff` 对 `server-rs`、`agent-service`、
`docs/contracts`、`deploy` 全为空；只改 Flutter `lib/**`、`test/**`、
新增一个前端专用 smoke 脚本与本回执。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `8b7153d` | Agent 仓库、SSE/multipart/二进制传输、会话控制器、面板与全局入口 |
| `1aaa70f` | 35 条专项测试 + 真实 Rust+Node 联调 + 前端 Agent smoke |
| `fa5d71b` | 面板 golden 预览（明暗各一组） |
| （最后一笔） | 本回执 |

合并与部署归 Codex；未合集成线、未建 Release、未配置任何模型凭据。

## 2. P0 全局入口与会话

1. **全局低强调悬浮入口**（`kAgentEntryKey`）：宽屏切换右栏，窄屏 `context.push('/agent')`
   进全屏页。右栏排在内容之后、宽 360px——测试断言展开前后
   `NavigationRail` 的矩形完全一致，且面板左边界大于 Rail 右边界。
   移动端返回键由 go_router 正常出栈（`handlePopRoute` 有断言）。
2. **主会话与多会话**：首次可用时进入 `isPrimary=true` 的会话；
   菜单提供新建、重命名、归档（主会话不可归档）与切换。
3. **模型**：只列服务端允许的模型并按会话切换；界面不出现 API key、
   provider 配置路径或环境变量（`GET /v1/agent/models` 的响应本身也不含凭据）。
4. **事件消费完整**：`run.queued`、`run.started`、`message.delta`、
   `tool.started`、`tool.completed`、`run.completed`、`run.failed` 全部处理；
   发送后本地立即建立 queued 占位，`run.completed` 后刷新 AI pending 与首页计数。
5. **重连与重开不重复拼接**——这是本批最需要 review 的一处：
   - 页面重开先拉消息快照。快照里**已结束**的助手消息以快照文本为准，
     其后重放的 `message.delta` 一律丢弃；**未结束**的消息正文清空，
     完全由 delta 重建（服务端在完成前不落 text，所以这是无损的）。
   - 断线后按已应用的最大 cursor 续接（`after` 查询 + `Last-Event-ID` 头同时发）。
   - 两条路径都有专项测试：重放场景断言最终文本是「你好，我在」而不是翻倍；
     断线场景断言第二次订阅带 `after=2` 且最终拼成 `ABCD`。
6. **发送与停止**：飞行中的请求不会被同一次点击重复触发（`sending` 门控，
   有并发点击断言）；busy 时仍可继续排队发送；活动运行提供停止按钮。

## 3. P0 图片账单

1. 输入区只接受 PNG/JPEG/WEBP（HEIC 不在白名单，有断言）；先
   `POST /v1/agent/attachments` 拿 `attachment.id`，再随消息发 `attachmentIds`。
2. 默认界面只有缩略图、文件名与移除；不出现 Base64、MIME、哈希或路径。
3. 历史/已发送消息的缩略图走 `GET /v1/agent/attachments/{id}/content`，
   Flutter 侧不持久化图片字节；回读失败给重试而不是空白。
4. Agent 产出只经既有 AI 待审核列表：面板在有待审核时提供低强调「前往审核」，
   面板内没有任何直接确认入账的入口。

## 4. P1 记忆审批

建议记忆以小卡片显示内容与原因，提供批准/拒绝；只渲染 `suggested` 状态，
批准前 UI 不出现任何「已生效」表述，审批后即从建议区消失。
未做商户→账户映射编辑器。

## 5. 状态与错误

- `configured=false`：输入框禁用、发送按钮禁用、显示「服务器尚未配置模型」，
  不伪造任何回复（有断言）。
- 401：走既有 token refresh，且**重放复用原 Idempotency-Key**（有断言比较两次
  请求头的 key 相等）。403 / 409 / 400 / 413 / 503 各有一句中文短提示；
  413 与 400 统一映射成带 `code` 的 `ApiValidationException`。
- 503 与附件失败都保留草稿与已选附件，可直接重试。
- 工具事件只显示中文活动行（读取数据/整理记录/刷新估值/整理偏好），
  未知工具统一「正在处理…」；测试断言映射结果里不含下划线英文标识。
  sidecar、loopback、session path、内部 token、bubblewrap、原始 tool payload
  与隐藏推理均不出现在任何用户可见字符串里。

## 6. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**244 passed / 53 skipped / 0 failed**
  （skipped = 43 golden 预览 + 10 真实联调）。新增 35 条 Agent 测试。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过（既有 7 文件 9 用例）。
- `pwsh tools/frontend_agent_smoke.ps1`（**新增**）：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

真实 Rust + Node 联调（`test/local_server_agent_integration_test.dart`）实测：
代理可达且 `configured=false`、`modelCount=0`；新建会话后能在列表读回并改名
（会话持久化）；附件上传返回合法 sha256 元数据、原图回读字节与上传完全一致；
无模型时发送消息 fail-closed 为 503 且消息列表仍为空。全程只经
`http://127.0.0.1:<ServerPort>/v1/agent/**`，未直连 sidecar 端口。

## 7. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

`agent_panel_empty_{dark,light}`、`agent_panel_streaming_{dark,light}`、
`agent_panel_unconfigured_dark`、`agent_panel_memory_{dark,light}`。
流式那张同屏可见：用户气泡、正在生成的助手气泡、「正在读取数据…」活动行
与停止按钮；记忆那张同屏可见：建议卡片（批准/拒绝）与历史图片缩略图。

## 8. 未完成项 / Codex 集成注意事项

- **未跑真实模型**：`tools/frontend_agent_smoke.ps1` 与后端 smoke 一样清空
  `*_API_KEY/_AUTH_TOKEN/_OAUTH_TOKEN` 并以 `configured=false` 运行，
  因为任务单禁止配置模型凭据。因此「一张微信账单经视觉模型产出待审核记录」
  这条端到端未实测；SSE 帧解析、流式合并、续接、工具活动行由同形事件的
  单测与组件测试覆盖。Codex 在配好模型的环境值得补这一条。
- **待发送附件的 golden 缺一张**：组件测试无法弹系统文件选择器，
  草稿区的附件 chip 没有 golden；已发送/历史图片的缩略图有 golden 覆盖。
  该路径的逻辑（白名单、上传、失败保留）有单测。
- `tools/frontend_agent_smoke.ps1` 在 `agent-service/node_modules` 缺失时
  会先跑一次 `npm ci`（新工作树首次运行需要网络），随后 `npm run build`；
  不修改 `tools/agent_local_smoke.ps1`。
- `ApiValidationException` 新增可选 `code` 字段并接管 413；
  `DevApiClient` 新增 `postMultipart` / `getBytes` / `streamEvents`。
  multipart 是手写的（part 需要真实图片 MIME，而 `http` 包的 `MultipartFile`
  需要额外依赖 `http_parser`，加依赖会超出本次边界）。
- `desktop_density_test` 里手机 FAB 的断言改为按「记录」文案定位——
  同屏现在多了一枚 Agent 入口 FAB。

本回执不含 token、密码、认证文件内容或真实账本数据。
