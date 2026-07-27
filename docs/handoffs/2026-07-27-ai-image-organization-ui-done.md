# 2026-07-27 AI 图片整理页面 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-19-claude-ai-image-organization.md`（清单 §3）。

基线：`origin/feat/subscription-sync-integration @ 0c55498`。
分支：`feat/ai-image-organization-ui`，独立工作树 `finwealth-ai-image`。
纯前端 diff：`git diff 0c55498..HEAD -- server-rs docs/contracts deploy
tools/contract_check.py` 零输出；未改 provider 配置；`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `edbf05d` | 选图优先的图片整理页、本地化 400/503 处理 |
| `af82a26` | 8 条专项测试 + 真实 Rust 联调 + smoke 增列 + 禁语扩展 |
| （golden 提交） | 选图默认态与 503 态 golden 预览 |
| `3ce56a0` | 统一可用性回归（§4）与两处窄屏溢出修复 |
| （最后一笔） | 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 逐项完成情况

1. **格式白名单**：选择器与 MIME 判定只保留 `png/jpg/jpeg/webp`，
   HEIC 已从 `XTypeGroup` 与 MIME 表中删除（有断言确认
   `kSupportedImageMimeTypes` 不含 `image/heic`）。
2. **默认页面只剩主路径**：选择图片 → 缩略预览 + 文件名 + 「重新选择」→
   「整理」。原先常驻的大块 Base64 文本域、data URL 示例、`MIME：…`
   与 10MB 说明全部移除（测试断言默认页面 `TextField` 数为 0）。
3. **粘贴兜底保留但低强调**：收进默认收起的「粘贴图片数据」折叠项，
   展开后可粘贴 Base64 / data URL 并「使用这张图片」，走与选图完全相同的
   预览与提交路径。
4. **400 一句中文原因且保留图片**：新增 `ApiValidationException.code`，
   按服务端 `error.code` 映射：
   `ai_image_input_mime_invalid` → 只支持 PNG、JPEG、WEBP 图片。
   `ai_image_input_data_invalid` → 图片内容与格式不一致，请重新选择。
   `ai_image_input_too_large` → 图片超过 10 MiB，请压缩后再试。
   `ai_image_input_file_name_invalid` → 文件名无效，请重新选择图片。
   其他 → 图片未通过校验，请重新选择。
   英文 message、错误码本身、HTTP 状态与 provider 一律不展示（有断言）。
5. **503 保留状态并可重试**：就地显示「整理失败，请稍后重试。」+ 重试按钮，
   预览、文件名、粘贴内容全部保留；重试成功后进入 AI Review。
6. **复核展示沿用现有实现**：基线 `0c55498` 已含 AI 文本整理批的结构化/
   待补全门控——结构化候选显示标题、账户、金额、币种与时间；待补全候选
   只提供编辑与拒绝，不渲染「接受整组」。本批未改动该页逻辑。
7. **刷新范围**：创建成功后失效 AI pending 与首页 overview；
   确认/拒绝/编辑沿用 `ai_review_page` 既有失效集合（AI pending、overview、
   movements、accounts，账本派生视图按 ledgerWrite/snapshotInvalidated 门控）。
8. **文案边界**：未新增「AI 不会直接写账」「仅供参考」「请自行核对」
   「图片只作为证据」类解释；后三者与「data URL」已加入
   `defensive_copy_scan_test` 黑名单并全量通过。

## 3. 必测结果

组件/单测（`test/ai_image_organization_test.dart`，8 条全绿）：
格式白名单与 HEIC 不可选、错误码→中文映射（并断言映射结果不含
下划线英文标识）、默认页面无 Base64/data URL/MIME/大小说明、
预览与「重新选择」、成功提交的 fileName/mimeType/base64 载荷、
400 保留图片、503 保留状态并重试成功、360 与 1200 宽无 overflow。

真实联调（`test/local_server_ai_image_integration_test.dart`，已入 smoke）：

1. 合法 1×1 PNG（magic 与 IHDR 合法）→ 200 生成候选；
   provider 关闭时是待补全候选，`approve` 被服务端拒绝，余额保持 `100.00`。
2. **必测 3**：`fileName=receipt.jpg` + `mimeType=image/jpeg` 但内容是 PNG →
   400 且 `error.code=ai_image_input_data_invalid`；余额不变。
3. HEIC（`mimeType=image/heic`）→ 400 且
   `error.code=ai_image_input_mime_invalid`；余额不变。
4. 同一 Idempotency-Key 重放返回同一 proposal，pending 只新增一项。

## 3b. 统一可用性回归（清单 §4，按要求并入最后一项前端分支）

新增 `test/responsive_regression_test.dart`：首页、账户详情（含多资产持仓行）、
AI 导入（文本 / 图片 / CSV）、AI Review 六个页面，各自在
**360 / 1200 / 1440** 宽度下断言无布局异常。

扫出并修掉两处既有窄屏溢出（都不在本批三项范围内，属回归扫描的产物）：

1. `overview_page.dart` 资产构成图例：金额文本改为可省略的 `Flexible`，
   360 宽下不再把整行撑破 52–66 px。
2. `ai_import_csv_page.dart` 默认账户下拉：补 `isExpanded: true` 与省略号，
   长账户名不再溢出 164 px。

两处修改后重新生成全部 golden，**PNG 逐字节无变化**——说明真实字体下的排版
未被改动，改的只是极窄场景下的降级行为。

其余 §4 条目：可见字符串扫描由 `defensive_copy_scan_test` 覆盖
（`lib/features`、`lib/app`、`lib/shared`，本批新增 3 条禁语）；
真实写路径一律以 Rust local-server smoke 为准，fixture/mock 不冒充写入成功。

**给 Codex 的提醒**：本分支只含图片批的改动，因此这份回归跑不到
`fix/authoritative-valuation-ui` 的估值面板与 `feat/fixed-yield-ui` 的
收益条款/收益区。三项合入集成线后建议原样复跑该测试文件，
并把这两个页面加进 `pages` 表。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**223 passed / 49 skipped / 0 failed**
  （skipped = 39 golden 预览 + 10 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过
  （8 文件 10 用例串行，含新增图片联调）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 5. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

1. `ai_image_import_default_dark.png` / `ai_image_import_default_light.png`：
   默认页面只有「选择图片」、禁用态「整理」与收起的「粘贴图片数据」；
   无 Base64 输入框、无 data URL / MIME / 大小说明。
2. `ai_image_import_unavailable_dark.png`：503 后文件名、「重新选择」、
   预览位与「整理失败，请稍后重试。」+ 重试同屏保留，无 provider 与状态码。
   （预览区看似空白是因为示例图是 1×1 全透明 PNG，非布局问题。）

## 6. 未完成项 / Codex 集成注意事项

- **真实 provider 的端到端未跑**：联调环境 `FINWEALTH_AI_PROVIDER` 关闭，
  而任务单边界明确禁止改 provider 配置与部署脚本，因此
  「一张收据经 provider 返回 expense 候选、确认后才扣款」这条
  无法在本分支的 smoke 内执行。已覆盖的是同一路径上服务器可验证的部分
  （上传校验、候选生成、确认前余额不变、幂等），以及复核页对结构化/
  待补全候选的展示与门控（沿用 AI 文本批的同形 JSON 组件测试）。
  Codex 若在配好 provider 的环境复跑，建议补这一条。
- `ApiValidationException` 新增了可选 `code` 字段（位置参数不变，
  其余调用点无需修改）。
- 图片联调只在临时账本里新建一个现金账户并生成/拒绝候选，不留残留待办。

本回执不含 token、密码、认证文件内容或真实账本数据。
