# 2026-07-29 Agent 会话管理与报价候选刷新 · 回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-29-claude-agent-conversations-and-quotes.md`。

基线：`origin/feat/integration-self-use @ ac84c20`。
分支：`feat/agent-conversations-quotes`（独立工作树 `finwealth-agent-conv`）。
边界核对：对 `agent-service/**`、`server-rs/**`、`docs/contracts/**` 与部署脚本的
改动为空。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `247ad40` | P0.1 / P0.2 / P0.3 实现 |
| （测试提交） | 15 条回归 + 两组会话 sheet 视觉预览 |
| （最后一笔） | 本回执 |

## 2. P0.1 默认打开最新活跃会话

- 新增纯函数 `agentLatestActive(conversations, {excludeId})`：列表已按
  `updatedAt` 降序返回，取**第一条 `status=active`**，归档会话不参与；
  没有活跃会话时返回 null（面板保持空态，不会误开归档会话）。
- 面板里的 `_openPrimaryOnce` 改为 `_openLatestActiveOnce`，`_opened` 闩锁保留：
  **首次就绪打开一次**，之后 `agentConversationsProvider` 再怎么刷新都不会把用户
  从自己选中的会话上拽走。
- 新建、恢复会话后主动 `open()` 该会话；归档当前会话、删除当前打开的会话后，
  打开剩余活跃会话中最新的一条（都走同一个 `agentLatestActive`）。

## 3. P0.2 归档可见、可恢复、可永久删除

- 会话 sheet 保持「新建 / 重命名 / 归档 / 其他会话」，末尾多一条紧凑的
  **「已归档 N」**入口（`kAgentArchivedEntryKey`）。归档项不再常驻列表。
- 点入口在**同一个 bottom sheet 内**切换到可滚动的归档列表
  （`kAgentArchivedListKey`），不新开路由，返回键层级不变。每项两个动作：
  - 恢复 → `PATCH /v1/agent/conversations/{id}` `status=active`，成功后自动打开；
  - 删除 → 二次确认后 `DELETE /v1/agent/conversations/{id}`。
- 确认框内容只有**会话标题**和「永久删除」/「取消」，没有内部 id、路径、
  session 文件或解释性长文案（有断言）。
- 主会话不出现「归档」动作，归档态的主会话也不进入归档入口；后端同样会拒绝。
- 409 → 只刷新会话列表并给一句「会话状态已变化」，条目保留。
- 仓库新增 `deleteConversation(Id)`，`DevApiClient` 增加真正的 `DELETE`
  分发；写入语义与其他写路径一致（自动 Idempotency-Key、401 刷新后重放复用
  同一个 key，有断言）。**没有用 PATCH 伪装删除。**
  DEMO 与 `real_local` 一律 `UnsupportedError`，不伪造删除成功。

## 4. P0.3 报价候选即时刷新

`agentQuoteCandidatesProvider` 现在在三个时机被 invalidate：

1. `run.completed` 与 `run.failed`（失败的一轮也可能已经写下候选）；
2. 报价类工具的 `tool.completed` 提前刷一次 —— 白名单为
   `finwealth_lookup_quote_candidate` / `finwealth_lookup_fx_candidate` /
   `finwealth_suggest_quote`，其他工具不触发（有断言）；
3. App 回到前台且面板挂载时刷一次。

`WidgetsBindingObserver` 只在 `initState` 注册一次、`dispose` 注销，
**没有轮询、没有后台 timer**；连续 rebuild 与 inactive/hidden/paused 都不产生
请求（有断言）。聊天区仍然只有一条紧凑入口，点击才展开候选 sheet。

## 5. 必测覆盖

新增 `test/agent_conversations_quotes_test.dart`（15 条，全绿）：

| 任务单必测 | 用例 |
| --- | --- |
| 1 新非主会话在前时首次打开它 | `返回顺序为「新非主会话、旧主会话」时打开新会话` |
| 2 刷新不打断用户选择 | `列表刷新不打断用户当前主动选择` |
| 3 「已归档 1」可见、恢复后自动打开 | `归档后出现「已归档 1」，恢复后回到活跃列表并自动打开` |
| 4 二次确认、只发一次 DELETE、幂等键非空 | `永久删除…` + `DELETE 路径带非空 Idempotency-Key…` |
| 5 主会话无删除入口；409 保留并重载 | `主会话没有归档与删除入口`、`409：保留列表并重新加载` |
| 6 10 条归档双尺寸可滚动无 overflow | `10 条归档在 360x640 与 720x1280…` |
| 7 `run.completed` 后立即出现「报价建议 1」 | `run.completed 后无需重启即出现「报价建议 1」` |
| 8 回前台刷新但不产生请求风暴 | `回前台刷新一次；rebuild 与非 resumed 状态不产生请求风暴` |

另有「归档的最新会话不参与默认打开」「确认框取消不发删除」
「报价类工具完成后提前刷新」「无关工具不额外请求」「DEMO/real_local 不伪装删除」。

## 6. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- 新增专项：15 条全绿；既有 Agent 面板/会话菜单/控制器测试同样全绿。
- `flutter test`：**400 passed / 87 skipped / 0 failed**。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过
  （`proxy + conversation delete + attachments + fail-closed`）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。

视觉预览共 77 条通过，新增两组明暗并逐张核验：

- `agent_conversation_sheet_{light,dark}`：主会话打开时没有「归档」动作，
  末尾是紧凑的「已归档 2」；
- `agent_conversation_archived_{light,dark}`：归档列表每项只有标题 +
  「恢复」「删除」，没有 id、时间戳或路径。

## 7. 未验证项

- 未启动 AVD（约定不抢占前台）。归档入口的真机触摸、归档列表在小屏上的滚动
  手感，以及「回前台刷新候选」在真实 Android 生命周期下的表现，
  需要在设备验收里过一遍。
- `run.completed` 后候选出现是用注入的事件流验证的；真实 Grok 一轮跑完后
  入口是否即时出现，仍需 Codex 在真服务上确认一次。
- 本分支改动了 `lib/features/agent_panel.dart` 的会话菜单与面板生命周期，
  与仍未合入的其他前端分支若有重叠，合入时留意冲突。

本回执不含 token、密码、认证文件内容或真实账本数据。
