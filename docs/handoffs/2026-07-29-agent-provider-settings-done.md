# 2026-07-29 模型连接（Grok OAuth）前端 · 回执

执行对象：Claude（前端线）。对应任务单
`projects/finwealth-pi-agent/docs/handoffs/2026-07-29-claude-agent-provider-settings.md`。
后端基线：`feat/agent-provider-oauth @ fea3511`。

前端基线：`origin/feat/pi-agent-control-center @ 4cd3e17`。
分支：`feat/agent-provider-settings`（独立工作树 `finwealth-agent-provider`）。
边界核对：对 `agent-service/**`、`server-rs/**`、`docs/contracts/**`、
部署脚本与 OAuth 后端的改动为空。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `e8687b0` | 数据层（VM/仓库/provider）、设置入口与路由、模型不可用提示 |
| `cbe1360` | 与本次无关的既有失效用例修正（见 §7） |
| `b2fa24f` | 连接流程加固 + 回归测试 + 三组视觉预览 |
| （最后一笔） | 本回执 |

## 2. 接口与映射

新增仓库方法（只经既有 `/v1/agent/**`）：

| 方法 | 请求 |
| --- | --- |
| `listProviders()` | `GET /v1/agent/providers` |
| `startProviderOAuth(id)` | `POST /v1/agent/providers/{id}/oauth/start`（202） |
| `getProviderOAuthAttempt(id)` | `GET /v1/agent/provider-oauth/{attemptId}` |
| `disconnectProvider(id)` | `POST /v1/agent/providers/{id}/disconnect` |

两个写路径的 `Idempotency-Key` 由 `DevApiClient` 统一生成，401 刷新后重放复用
同一个 key（有断言）。VM 为 `AgentProviderVm` 与
`AgentProviderOAuthAttemptVm`，只承载 URL、用户码、状态与到期时间；
令牌类字段在契约里就不存在，前端也没有任何字段去接。

DEMO（`FixtureAgentRepository`）与 `real_local` 返回空 provider 列表，
发起/断开一律 `UnsupportedError`，不伪造连接成功。

## 3. 交互

- 设置新增「模型连接」行 → `/agent/providers`。
- 页面按接口返回渲染，**没有任何硬编码厂商卡片**；当前结果就是一行 `Grok` +
  连接状态。未连接 → 「连接」；已连接 → 「断开连接」（一次简短确认）；
  `connecting` → 「刷新」；不支持 OAuth 的来源显示「暂不支持」，不给假动作。
- 发起授权后弹出设备码面板：授权码（大号 + 复制）、授权页地址（打开 + 复制）、
  倒计时、取消。可见期间每 2 秒轮询一次；`connected` 自行关闭并刷新
  providers / models / status，之后 `xai/grok-4.5` 才会出现在既有模型选择里。
- 打开授权页只接受 https 且 host 非空的地址，交给系统浏览器；
  打不开时提示复制链接。Android 侧只增加了 https VIEW 的 `<queries>` 意图，
  **没有新增任何权限**。
- 失败停在 Grok 这一行：`failed` → 「授权未完成，请重试」，
  `cancelled` → 「授权已取消」，本地过期 → 面板显示「授权已过期，请重新发起」
  并停止轮询，关闭后行上是「重试」。上游错误原文、scope、payload 一律不显示。
- 会话选中的模型不在可用列表里时，面板顶部出现「模型当前不可用 / 重新连接」，
  **不会替用户改选任何其他模型或 provider**。模型列表处于加载中或请求失败时
  不做这个判定（`agentSelectedModelUnavailable` 只认成功返回的数据）。

## 4. 依赖

新增 `url_launcher: ^6.3.2`（BSD-3-Clause，Flutter 官方维护），用于把授权页交给
系统浏览器。随之带入 `url_launcher_*` 各平台实现。

`android/app/src/main/AndroidManifest.xml` 在既有 `<queries>` 内追加一个
https `ACTION_VIEW` 意图（Android 11+ 包可见性要求），未改动权限、导出组件或
FileProvider。

## 5. 测试

| 任务单条目 | 覆盖 |
| --- | --- |
| 未连接 → 发起 → 设备码 → 已连接 | `agent_providers_test` 连接流程 |
| 401 重放复用同一 Idempotency-Key | 同上，start 与 disconnect 各一遍 |
| failed / cancelled / 过期彼此可分 | 三条独立用例（含"过期后不再请求服务端"） |
| 断开后 Grok 不再可选 | 断开确认后模型列表清空 |
| 选中 Grok 不可用不切换 provider | 面板用例 + 纯函数用例（含 loading/error） |
| 360 与桌面无 overflow | 360x640 / 1200x800，列表与授权面板各一次 |
| 文案不含令牌字段/原始 provider 标识/自动切换 | 扫描全部可见 Text/SelectableText |

`agent_providers_test` 14 条、`agent_provider_settings_test` 4 条、
`agent_mapping_test`（含新增的 provider 路径断言）合计 39 条全绿。

## 6. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- 模型连接专项：39 条全绿。
- `flutter test`：**332 passed / 75 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。

视觉预览（`PREVIEW_GOLDENS=1 ... --update-goldens`，共 65 条通过）新增三组明暗：
`agent_providers_disconnected_{light,dark}`、
`agent_providers_connected_{light,dark}`、
`agent_provider_oauth_{light,dark}`。逐张核验：只出现显示名与状态，
没有 provider 原始 id、令牌字段或路径；授权面板在 420 宽下不裁切。

## 7. 与本次无关的既有失效

`test/subscription_next_charge_test.dart` 的
`本月已续费：手动改下次扣费日为更晚日期并提交` 写死当月 28 日，
过了 28 号日期选择器不允许回选。已按当月推导修正（`cbe1360`）。
同一处修正也在 `fix/agent-chat-ui` 与 `fix/android-self-update-corrections`
上出现过，合入时取任一侧即可。

## 8. 未验证项

- **真实 OAuth 未在本地跑通**：设备码需要账号所有者在浏览器里点确认，
  按约定本批没有配置真实模型 key、也没有对生产发起授权。
  端到端授权、断开、重新连接需要 Codex 在真机/真服务上过一遍。
- 未启动 AVD：Android 上「打开授权页」是否真的拉起浏览器（`<queries>` 是否足够）
  只能在真机验收里确认；打不开时的兜底是复制链接，已实现并有提示。
- 本分支与 `fix/agent-chat-ui` 都改了 `lib/features/agent_panel.dart`
  的下半段（一个加模型不可用提示，一个换对话渲染），合入时会有一处小冲突。

本回执不含 token、密码、认证文件内容或真实账本数据。
