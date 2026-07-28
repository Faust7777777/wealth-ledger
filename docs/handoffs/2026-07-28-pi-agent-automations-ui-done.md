# 2026-07-28 Agent 自动任务与通知 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-28-claude-pi-agent-automations.md`。

基线：`origin/feat/pi-agent-control-center @ ab52bcb`（含自动任务 `142951b`、
周期总结 `ebe1be9`，以及我上一批已被合入的 `08ffe67`）。
分支：`feat/pi-agent-automations-ui`，独立工作树 `finwealth-pi-automations`。
边界核对：对 `server-rs`、`agent-service`、`docs/contracts`、`deploy` 的改动为空；
只改 Flutter `lib/**`、`test/**`、golden 与本回执。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `0c4deb1` | 自动任务设置页、通知入口与 sheet、五个接口接入 |
| `d66b454` | 20 条专项测试 + 映射测试 + 真实调度联调 + 6 张 golden |
| （最后一笔） | 本回执 |

## 2. 逐条落实

1. **通知入口低强调**：Agent 面板上只有一行「通知 N」（无未读时只显示「通知」，
   无通知则整行不渲染）。任务实现说明一概不常驻。
2. **通知列表**：sheet 有高度上限（屏高 70%，钳 200–560）、可滚动，
   newest-first 直接采用服务端顺序，显示标题、正文与本地时间；
   未读是实心点、已读是勾。打开一条先幂等标记已读（已读的不再重复调用），
   再按 `action` 跳转：`review`→AI 审核、`dca`→投资页、
   `quotes`→打开报价建议 sheet、`agent`→回到主会话。
3. **设置四行任务**：新增「设置 → Agent 自动任务」页，四类各一行，
   只有开关、频率、下次时间、上次结果、「立即运行」。
   未创建的类型也占一行，开关关着；打开开关即创建该类型（默认 24 小时）。
4. **频率与首次时间**：预设「每小时 / 每 6 小时 / 每天 / 每周」+ 自定义小时，
   范围 1–720（越界时保存禁用并提示）；下次运行时间用日期 + 时间选择器。
   界面上没有 cron、sidecar、timer 或内部错误码（有断言）。
5. **失败与防抖**：失败只显示「上次未完成 · 将在 <时间> 重试」，
   `lastErrorCode` 只映射进 VM 供诊断、不渲染；「立即运行」busy 时按钮禁用，
   同一次点击只发一个请求（并发点击断言），409 提示「这项任务正在运行，请稍后再试」。
6. **财务总结**：`action=agent` 只是收起 sheet 回到主会话；
   断言界面不出现「报告已完成」「排队」这类把状态写成结论的措辞。
7. **不提供**自动采用网页报价 / 自动确认订阅扣费 / 自动执行定投的开关，
   有断言确认页面上不出现「自动采用 / 自动确认 / 自动执行」。
8. **数据源边界**：`real_local` 与 DEMO 的写方法直接 `UnsupportedError`，
   读方法返回空，不伪造权威写入成功。
9. **响应式**：设置页与通知列表在 360 / 1200 / 1440 三档宽度下均无 overflow。

## 3. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**289 passed / 67 skipped / 0 failed**（本批新增 20 + 5 条）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过。
- `pwsh tools/frontend_agent_smoke.ps1`：通过。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

真实联调（经 Rust origin，非直连 sidecar）实测通过：
创建计划 → 关闭 → 重开后**计划仍存在且频率不丢**；
**「立即运行」前后 `nextRunAt` 完全一致**且写入了 `lastRunAt`；
同一类型重复创建返回 409；通知列表可读。

## 4. 视觉证据（真实主题 + Noto 字体，逐张肉眼核验）

- `agent_automations_empty_{dark,light}`：四行任务、开关全关、无运行入口。
- `agent_automations_configured_{dark,light}`：四行分别是成功、
  **上次未完成 + 重试时间**、已关闭且「尚未运行」、每周成功。
- `agent_notifications_{dark,light}`：面板上的「通知 1」入口 + 打开后的列表
  （未读实心点 vs 已读勾、标题/正文/本地时间）。

## 5. 未完成项

- **跨重启到期任务生成通知**这条没能在 smoke 内验证：需要让 sidecar 停机、
  等到期时间再起，超出前端 smoke 能安排的范围（而且任务单禁止我改后端 smoke）。
  已验证的是同一进程内的调度状态持久化（关闭/重开后计划仍在）与手动运行不改期。
  Codex 那边的 Node 测试更适合覆盖跨重启这一段。
- **A.2 实机目验仍待你运行一次 App**：Windows 右栏、Android 全屏页与返回键、
  历史图片/文件 chip、断线重连，外加本批的通知入口与自动任务页。
  按约定我没有抢占前台，结果给我即可补进回执。
- 真实模型驱动的自动任务产出（例如财务总结正文）未在前端验证，
  与既有约定一致由 Codex 在配好模型的环境复跑。

本回执不含 token、密码、认证文件内容或真实账本数据。
