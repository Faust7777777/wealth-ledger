# 2026-07-28 报价紧凑修正 + Agent 非图片附件 · 完成回执

执行对象：Claude（前端线）。对应两份任务单：
`2026-07-28-claude-pi-agent-followup-correction.md`（P0 紧凑修正）与
`2026-07-28-claude-pi-agent-file-attachments.md`（非图片附件）。

基线：`origin/feat/pi-agent-control-center @ 3e34dbc`（含附件后端 `ddfdb54`）。
分支：`feat/pi-agent-frontend-followup`（已在该基线上 rebase）。
边界核对：对 `server-rs`、`agent-service`、`docs/contracts`、`deploy` 的改动为空；
只改 Flutter `lib/**`、`test/**`、golden 与回执。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `3f395b1` | 附件选择接缝 + 草稿区测试 + 待发送 golden（原 A.1） |
| `9b444d6` | 报价候选接入与审核（原 B） |
| `85bf861` | 上一轮回执 |
| `d187c1d` | **本轮**：报价紧凑入口 + 非图片附件 |
| （最后一笔） | 本回执 |

## 2. 修正单：报价候选保持紧凑

1. 面板外层现在只有**一条固定高度的低强调入口**「报价建议 N」，
   候选不再纵向铺开。
2. 点击进入 `AgentQuoteCandidateSheet`：`maxHeight = 屏高 70%`（钳在 200–560），
   内部 `ListView` 可滚动。处理完最后一条自动收起，不留空 sheet。
3. **多候选回归**：10 条 `suggested` 在 `360×560` 与 `1200×520` 两种矮窗口下，
   断言入口态与 sheet 态都无异常、聊天消息仍可见、聊天区
   `ListView` 高度 > 120px（不被挤压），并实际滚动 sheet 一次。
4. 采用/忽略、409 重载、重复点击门控与来源复制行为原样保留，
   对应测试全部沿用并通过。

P1 的「点击直接拉起浏览器」按你的意见暂不做，仍是复制完整链接。

## 3. 非图片附件

1. **接缝泛化**：`agentImagePickerProvider` → `agentAttachmentPickerProvider`，
   白名单扩为 PNG/JPEG/WEBP + TXT/CSV/PDF/XLSX/ZIP，按扩展名发准确 MIME
   （`.xlsx` → `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`）。
   入口图标从「选择图片」改为「添加文件」。
2. **草稿区**：图片仍是缩略图 chip；其他文件是**类型图标 + 文件名 + 大小**的
   紧凑 chip（PDF/CSV/XLSX/ZIP/TXT 各有图标）。有断言确认不读取也不展示文件正文、
   不出现「已解析」字样。
3. **历史消息先读元数据**：新增 `agentAttachmentMetaProvider`；
   只有 `mimeType` 是图片才继续取字节走 `Image.memory`，
   其余直接渲染文件 chip。有断言确认 PDF 消息的 `getAttachmentContent`
   调用次数为 **0**——PDF/ZIP 字节不会交给图片解码器。
4. **失败处理**：413 →「文件超过 15 MiB，请压缩后再试。」；
   不支持类型 →「只支持图片、TXT、CSV、PDF、XLSX 与 ZIP。」；
   内容与扩展名不符 →「文件内容与扩展名不一致，请重新选择。」；
   文本非 UTF-8 →「文本内容不是有效的 UTF-8，请另存后再试。」。
   失败后草稿区不加入该文件，选择按钮保持可用可重选。
   有断言确认这些文案里不含下划线英文标识，界面上也不出现 MIME、哈希、
   工作区路径或解析实现。

### 一处实现说明

服务端把「内容与扩展名不符」和「文本非 UTF-8」都归到
`attachment_mime_mismatch` 一个 code。为了给出任务单要求的两句不同中文，
前端按**用户所选文件的扩展名**区分：`.txt`/`.csv` 走 UTF-8 那句，其余走格式那句。
如果后端以后拆出独立 code，这里改一行即可。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**264 passed / 61 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

真实联调（经 Rust origin，非直连 sidecar）新增并实测通过：
**CSV、TXT、PDF、XLSX、ZIP 逐个上传后原样回读，断言字节完全一致**，
元数据里没有服务端存储路径；用 PNG 字节冒充 PDF 会被拒绝；
`configured=false` 时发送消息仍 fail-closed 为 503，界面不声称模型读过内容。

## 5. 视觉证据（真实主题 + Noto 字体，逐张肉眼核验）

本轮新增/更新：
`agent_panel_quote_candidate_{dark,light}`（同屏可见紧凑入口 +
带高度上限的 sheet 与候选卡）、
`agent_panel_draft_document_{dark,light}`（CSV chip：表格图标 + 文件名 + 29 B + 移除）、
`agent_panel_history_document_{dark,light}`（历史消息里的 PDF chip）。
既有 `agent_panel_draft_image_*` 等保持覆盖。

## 6. 未完成项

- **真实模型读取 PDF/XLSX 的端到端仍未验证**：与后端回执一致，
  需要模型配置后由 Codex 复跑。前端只验证到「上传成功 + 原样回读 + 已附加」，
  界面上没有任何「已解析」表述。
- **A.2 实机目验仍待你运行一次 App**：Windows 右栏开关与切会话、
  Android 全屏页输入法顶起与返回键、历史图片/文件 chip、断线重连。
  按约定我没有抢占前台，结果告诉我即可补进回执。
- 历史图片缩略图在离屏 golden 里解码不稳定，未做 golden；其渲染与
  失败重试由组件测试断言（本轮又补了「元数据失败给重试」一条）。

本回执不含 token、密码、认证文件内容或真实账本数据。
