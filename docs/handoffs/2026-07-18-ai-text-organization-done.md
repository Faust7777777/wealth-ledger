# 2026-07-18 AI 文本整理前端 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-18-claude-ai-text-organization.md`。

基线：`origin/feat/subscription-sync-integration @ fde9071`（含 AI provider
后端 `dda91af`）。分支：`feat/ai-text-organization`，独立工作树
`finwealth-ai-text`。纯前端 diff：未改 Rust、OpenAPI、部署脚本或 provider
配置；`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `168153d` | 结构化候选映射与展示、待补全门控、503 重试、刷新范围 |
| `7ba16cd` | 6 条专项测试 + 真实联调入 smoke + 禁语扩展 + 2 张 golden |
| （最后一笔） | 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 前端范围落实（任务单逐条）

1. 文本入口保持简洁（输入框 + 导入 + busy）；成功后 `go('/ai-review')`
   直接进入现有 AI Review，并失效 aiPending 与首页 overview。
2. 结构化候选（`proposedMovements[0]` 映射进 `AiAtomicGroupVm.proposedMovement`）
   在复核卡上显示 标题 / 账户名（按账户列表解析）/ 金额（原币）/ 时间
   （本地日期时分），保留 接受整组 / 编辑 / 拒绝整组。
3. 无结构化 movement（或 `validation.isValid=false`）→ 「待补全」标记 +
   编辑 / 拒绝，**不渲染接受整组**；不显示工程原因、provider 名、schema、
   prompt 或环境变量（有断言）。
4. 503 → 新类型化 `ApiServiceUnavailableException`：文本页就地显示
   「整理失败，请稍后重试。」+ 重试按钮，原文本保留；`openai_responses`、
   上游状态码、配置字段一律不展示（有断言）。
5. `source.modelName` 已映射进 `AiProposalVm.modelName` 仅供诊断，候选主卡
   片不渲染（有断言）。
6. 禁语已加入 defensive_copy_scan 黑名单并全量通过：
   「不会直接写账」「不会猜金额」「仅供参考」「请自行核对」「只是候选」。

刷新范围：创建后失效 aiPending + overview；确认/拒绝后统一失效
aiPending、overview（首页 pending count）、recentMovements、accounts
（快照/构成等账本派生视图仍按 ledgerWrite/snapshotInvalidated 门控）；
编辑走既有 ai_edit 流程失效不变。

## 3. 必测结果

单测/组件（`test/ai_text_organization_test.dart`，6 条全绿）：
结构化/待补全映射、复核卡字段与确认可用、待补全无确认入口、
503 保留文本可重试且重试成功进入复核、成功刷新与跳转。

真实联调（`test/local_server_ai_text_integration_test.dart`，已入 smoke，
provider 默认关闭）：

1. 纯文本「午餐 18 元」→ 待补全候选（无 movement、标题含待补全）；
   approve 被服务端拒绝、余额保持 100.00（必测 3 + 必测 2 的确认前不变）。
2. 结构化路径（from-text 携带 movement 的服务端通道）→ expense 18 CNY
   候选：确认前 100.00 不变，approve 后 82.00（必测 1/2 的服务器侧语义；
   provider 生成结构化候选的展示与门控由组件测试用同形 JSON 覆盖——
   联调环境无法真实调用外部模型）。
3. 同一 Idempotency-Key 重放返回同一 proposal id，pending 集合只新增
   一项（必测 5；重放在服务端于 provider 调用之前短路）。
4. 503 重试为前端行为，组件测试覆盖（必测 4）。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**209 passed / 45 skipped / 0 failed**
  （skipped = 36 golden 预览 + 9 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过（7 文件 9 用例串行）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 5. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

1. `ai_text_review_dark.png`：同屏两卡——结构化候选
   （标题 午餐 / 账户 现金钱包 / 金额 ¥18 / 时间，三个动作齐全，
   无 modelName）与待补全候选（琥珀「待补全」pill，仅 拒绝/编辑）。
2. `ai_text_import_unavailable_dark.png`：503 后原文本保留、
   「整理失败，请稍后重试。」+ 重试，无 provider/状态码字样。

## 6. 未完成项 / 阻塞

无后端阻塞。围栏外未做：真实外部模型的端到端调用（联调环境
provider=none，其行为由服务端契约与同形 JSON 测试覆盖）；转账/投资/
贷款/订阅类文本仍走各自专用表单（后端第一阶段范围即单账户收支）。

本回执不含 token、密码、认证文件内容或真实账本数据。
