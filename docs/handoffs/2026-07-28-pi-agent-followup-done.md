# 2026-07-28 Pi Agent 前端后续（A.1 + B）· 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-28-claude-pi-agent-followup.md`。

基线：`origin/feat/pi-agent-control-center @ 080dfb5`（含报价候选后端 `ad371ae`）。
分支：`feat/pi-agent-frontend-followup`，独立工作树 `finwealth-pi-followup`。
边界核对：对 `server-rs`、`agent-service`、`docs/contracts`、`deploy` 的改动为空；
只改 Flutter `lib/**`、`test/**`、golden 与本回执。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `7f282ae` | 选图接缝 + 草稿区组件测试 + 待发送图片 golden（A.1） |
| `8c9ed07` | 报价候选紧凑卡片、采用/忽略、映射与测试、golden（B） |
| （最后一笔） | 本回执 |

## 2. A.1 待发送图片草稿区

新增 `agentImagePickerProvider` 作为选图接缝：默认弹系统选择器，测试与 golden
注入假实现，**不再需要在测试里驱动真实文件对话框**。

- 4 条组件测试：选图后缩略图 + 文件名 + 可移除；不支持扩展名不上传且给一句中文；
  413 不进草稿区、显示可重试短提示、选图按钮保持可用；取消选择无副作用。
  另断言草稿区不出现 MIME、Base64 或哈希。
- 新增 golden `agent_panel_draft_image_{dark,light}`。
- **顺手修了一个 golden harness 问题**：`Image.memory` 的解码是异步的，
  之前只 `pumpAndSettle` 会把缩略图画成空位。现在 golden 里先 `precacheImage`
  再 pump，草稿区缩略图才真实出现。

## 3. B 报价候选审核

1. **只对 `suggested` 显示紧凑卡片**（`_QuoteCandidates`），放在会话区上方，
   不常驻占满聊天区；`applied`/`rejected` 不渲染。
2. **卡片内容**：标的用 `instrumentsProvider` 解析成可读名称（`Bitcoin · BTC`），
   汇率用币对（`USD / CNY`）；数值带计价单位（`61234.50 USDT` / `7.1832 CNY`）；
   本地时区的报价时间 + 来源名称；单独一行可点的来源域名。
   有断言：不出现内部 ID（`inst_`/`qc_`）、tool 名（`finwealth_`）或存储字段。
3. **采用 / 忽略**：采用发 `{"decision":"apply"}`，成功后刷新
   `holdings`、`accounts`、`overview`、`allocation` 并提示「已采用这条报价」；
   忽略发 `reject`，候选消失且**不刷新任何估值视图**（有计数断言）。
4. **失败处理**：一般失败保留候选并显示「操作失败，请重试」；
   409 显示「这条建议已被处理，已重新加载」并重新拉列表；
   同一候选重复点击只产生一次请求（有并发点击断言）。
5. **无防御性文案**：断言卡片上不出现「仅供参考」「自行核」「可能不准」。
6. `finwealth_suggest_quote` → 活动行「正在整理报价…」。

新增 golden `agent_panel_quote_candidate_{dark,light}`。

### 一处需要你或 Codex 拍板的偏差

任务单要求「可点击来源 URL」。本仓库没有 `url_launcher` 依赖，而边界只允许我改
`lib/**`、`test/**`、smoke、golden 与回执，**加依赖要动 `pubspec.yaml`**，
超出授权。因此当前实现是：点击来源域名把完整 URL 复制到剪贴板并提示
「已复制来源链接」。如果希望点击直接打开浏览器，请授权我加 `url_launcher`，
改动很小。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**259 passed / 57 skipped / 0 failed**
  （本批新增 12 条：草稿区 4、报价候选 7 组件/纯函数 + 3 映射）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

真实联调新增断言（经 Rust origin，非直连 sidecar）：未运行模型时候选列表为空；
审核不存在的候选会失败；**前后 `quotes/summary` 的 fresh/stale/unpriceable
计数完全一致**，即建议与失败审核都没有改动估值。

## 5. 未完成项 / 说明

- **「采用后才更新报价」这条端到端仍未实测**：候选只能由模型调用
  `finwealth_suggest_quote` 生成，而任务单禁止我配置模型凭据，
  smoke 以 `configured=false` 运行，因此没有可采用的候选。
  已覆盖的是「没有候选 → 估值不变」与「审核失败 → 估值不变」这两半，
  以及采用/忽略各自的刷新范围（组件测试用计数断言）。
  Codex 在配好模型的环境值得补「采用后 quotes 真的多了一条」。
- **A.2 实机目验尚未进行**：需要你在方便时自己运行一次 App。
  我按约定没有抢占前台、没有自动截图。建议目验清单：
  Windows 右栏开/关与切换会话、Android 全屏页的输入法顶起与返回键、
  历史图片缩略图加载、断线后「重连」。把结果告诉我，我补进回执。
- **历史消息缩略图的 golden 仍未覆盖**：该路径在离屏 golden 里解码不稳定，
  已从记忆卡 golden 里移除以免呈现误导性的空白块；
  其渲染与失败重试由组件测试断言（`Image` 存在、失败给重试、点击重试会再读一次）。
- 非图片附件、定时任务、插件、真实模型配置与生产部署仍在前端范围之外，
  本批没有做任何假按钮或 fixture 成功路径。

本回执不含 token、密码、认证文件内容或真实账本数据。
