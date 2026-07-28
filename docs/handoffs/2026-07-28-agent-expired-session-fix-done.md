# 2026-07-28 P0 · Agent 登录失效不再显示成模型未配置 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-28-claude-agent-expired-session-fix.md`。

基线：`origin/feat/pi-agent-control-center @ 3aa9f70`。
分支：`fix/agent-expired-session`，独立工作树 `finwealth-agent-session`。
边界核对：对 `server-rs`、`agent-service`、`docs/contracts`、`deploy` 的改动为空；
只改 Flutter `lib/**`、`test/**`、golden 与本回执。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `46f0f53` | 面板五态门控 + refresh 明确 401 才判定会话失效 |
| `9193e17` | 14 条专项测试 + 旧断言按新契约更新 + needs-login golden |
| （最后一笔） | 本回执 |

## 2. 根因与修法

原因确如任务单所述：`configured` 由 `statusAsync.asData?.value.configured ?? false`
得出，于是 loading、401、网络错误、5xx 全被折叠成「未配置模型」；
会话列表出错又回落成空列表，叠加出「还没有对话」。

现在引入纯函数 `agentPanelGate(statusAsync, conversationsAsync)`，
把面板主体分成五个互斥状态：

| 状态 | 触发条件 | 呈现 |
| --- | --- | --- |
| `needsLogin` | status 或会话列表抛 `ApiUnauthorizedException` | 「需要登录」+「去登录」（进设置） |
| `failed` | 其他任意错误（网络 / 503 / 5xx） | 「加载失败，请重试。」+ 重试 |
| `loading` | 两者尚未返回 | 只有进度指示 |
| `notConfigured` | **仅** status 200 且 `configured=false` | 「服务器尚未配置模型」 |
| `ready` | status 200 且 `configured=true` | 正常会话 |

401 优先级最高，因此不会与「未配置模型」同屏；未就绪时也不再显示
「连接已断开」。另外把「服务器尚未配置模型」从输入区移除，只在正文区居中显示一次，
避免同一句话出现两遍。

## 3. 会话失效的判定收紧

`DevApiClient` 新增 `onSessionExpired` 回调：

- **只有** refresh 自身返回 401/403 才算会话确定失效 → 清除本地 token 并回调一次；
- **网络失败、超时与 5xx 不清除**登录态，按普通错误交给调用方；
- refresh 本来就是单飞（`_refreshing`），并发 401 因此只刷新一次、只失效一次；
  token 清空后再来的请求在 `store.read()` 处直接返回，不会重复回调。

`AuthController.markSessionExpired()` 负责把登录态同步为未登录并重取能力；
`devApiClientProvider` 用**延迟 read** 接线，避免与 `authRepositoryProvider`
形成构建期循环依赖。

## 4. 必测结果（全部通过）

| 任务单要求 | 覆盖 |
| --- | --- |
| 1. status 200 + `configured=false` 才显示未配置 | 门控单测 + 组件测试各一 |
| 2. GET 401 + refresh 401：清 token、显示需要登录 | 客户端测试断言 `store.read()==null`；组件测试断言无「未配置」「还没有对话」 |
| 3. GET 401 + refresh 成功：复用新会话重放 | 断言第二次请求带 `Bearer new`、未触发失效回调 |
| 4. 网络失败 / 503：保留 token、显示重试 | 客户端测试两种失败各一轮；组件测试断言「加载失败，请重试。」且无未配置 |
| 5. 两个并发 401 | 断言 refresh 一次、失效回调一次 |
| 6. Android 360×640 / 720×1280 错误态无 overflow | 两种尺寸 × 两种错误态 |

返回键仍先关闭 Agent 页这一项由既有 `agent_panel_test` 的
「窄屏：入口进全屏页，返回可退回」继续覆盖，本次未改动该路径。

### 一处需要 Codex 知会的既有断言变更

`test/auth_client_test.dart` 里原有一条
「refresh 失败不得破坏本地会话」的断言，与任务单第 4 条直接冲突。
按任务单为准改成：refresh **明确 401** 时必须清除失效会话；
网络失败/5xx 保留登录态则由新测试单独覆盖。

## 5. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**303 passed / 69 skipped / 0 failed**（本批新增 14 条）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 6. 视觉证据

`agent_panel_needs_login_{dark,light}`（360×640）：只有「需要登录」与「去登录」，
没有「服务器尚未配置模型」「还没有对话」「连接已断开」。
`agent_panel_unconfigured_dark` 已重生成：正文区居中一句，输入区不再重复。

## 7. 复验提示

合入后重建 APK，在同一 AVD 上应能看到：保留失效会话时 Agent 全屏页显示
「需要登录」并可跳设置；重新登录后回到 Agent 即进入正常会话。
其余待验项（输入法顶起、会话切换、历史附件 chip、断线重连）本批未触碰。

本回执不含 token、密码、认证文件内容或真实账本数据。
