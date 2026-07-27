# 2026-07-27 权威估值问题接口 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-18-claude-authoritative-valuation-issues.md`
（清单 §1）。

基线：`origin/feat/subscription-sync-integration @ 0c55498`。
分支：`fix/authoritative-valuation-ui`，独立工作树 `finwealth-valuation-issues`。
纯前端 diff：`git diff 0c55498..HEAD -- server-rs docs/contracts deploy
tools/contract_check.py` 零输出；`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `3c47011` | 接入权威估值问题读模型，删除客户端第二套估值规则 |
| `7d3ebef` | 单测/组件测试 + 真实 Rust 联调 + smoke 增列 + golden |
| （最后一笔） | 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 逐项完成情况

1. **Repository 新增映射与 provider**：`PortfolioRepository.listValuationIssues()`
   → `GET /v1/portfolio/valuation-issues`（GET 不带幂等键）；新增
   `ValuationIssueVm` 与 `ValuationAssetKind` / `ValuationIssueStatus` /
   `ValuationIssueReason` 三个枚举，映射 id、accountId、accountName、
   assetKind、assetId、assetLabel、quantity、quantityUnit、status、reason、
   sourceCurrency、targetCurrency 与可选 asOf；新增 `valuationIssuesProvider`。
2. **删除第二套估值规则**：`composeValuationIssues`、`_holdingIssue`、`FxRateVm`、
   `QuoteRepository.listFxRates()`、`fxRatesProvider` 及其 fixture/real_local
   实现全部移除。生产代码中已不存在任何客户端汇率推断；面板不再读取
   accounts/holdings/fx-rates。
3. **八种 reason 全支持**，各映射一句短状态：
   `missing_quote`→暂无报价、`missing_fx_path`→缺少 {source} → {target} 的估值路径、
   `stale_quote`→报价较旧、`stale_fx`→汇率较旧、`offline_cached_quote`→使用缓存报价、
   `offline_cached_fx`→使用缓存汇率、`quote_error`→报价获取失败、`fx_error`→汇率获取失败。
4. **空/失败态**：入口继续由 overview 的 `quoteProblemCount` 驱动，为 0 时隐藏；
   问题列表加载失败时入口仍在，面板内显示「状态加载失败，请重试。」+ 重试，
   不回退到客户端猜测。
5. **刷新失效范围**：`valuationIssuesProvider`、`overviewProvider`、
   `accountsProvider`、`holdingsProvider`、`allocationProvider`——即全部由
   报价/汇率派生的读模型。原 `fxRatesProvider` 已随 `listFxRates` 一并删除，
   故不再单列（quotes/fx-rates 的前端表现全部收敛到上述读模型）。
6. **无解释文案**：未新增任何算法说明、边界或「不猜价 / 仅供参考」类文案；
   `defensive_copy_scan_test` 全绿。
7. **数据源边界**：fixture 提供 2 条结构化 issue（与 DEMO 概览
   `quoteProblemCount=2` 一致）；`real_local` 直接
   `throw UnsupportedError`，不伪造「没有问题」。

### 一处需 Codex 知会的实现决定

`valuationIssuesProvider` 显式关闭了 Riverpod 3 的默认自动退避重试
（`retry: (_, _) => null`）。默认策略会在最多 10 次退避（累计约 30 s）内
把状态保持在 loading，面板只会一直转圈，与任务单第 4 条「加载失败时
面板内提供短错误和重试」冲突。关闭后失败即刻可见，恢复路径是用户点「重试」。
仅作用于该 provider，其他 provider 行为不变。

## 3. 必测结果

组件/单测（`test/valuation_status_test.dart`，10 条全绿）：
八种 reason 短状态、完整字段映射（含可选 asOf 与 cash 类型）、
空列表隐藏入口、只有估值问题时不出大卡、大卡不含报价问题行、
多跳可用时不误报路径、缺报价与缺路径区分、stale FX、
加载失败保留入口且重试成功、刷新失败不关闭面板。

真实联调（`test/local_server_valuation_issues_integration_test.dart`，已入
smoke）——汇率/报价经公开的 `POST /v1/quotes/refresh` 载荷种入，不改后端：

1. **必测 1**：USDT 只有 `USDT/USD + USD/CNY` 两段 fresh → 该账户现金不返回
   任何问题；补齐 BTC/USDT 报价后整个账户问题清空，证明多跳路径真实生效。
2. **必测 3**：BTC 无报价 → `missing_quote`（不是 `missing_fx_path`），
   原始数量 `0.00076078` 原样返回。
3. **必测 2**：XAU 计价标的有 fresh 报价但无任何到 CNY 的路径 →
   `missing_fx_path`，`sourceCurrency=XAU`、`targetCurrency=CNY`、数量 `2`。
4. **必测 4**：JPY 现金 + stale `JPY/CNY` → `stale_fx`，
   status=`stale`，数量 `1000.00`。
5. **必测 5**：空列表与入口一致性由组件测试覆盖（入口读 overview
   `quoteProblemCount`）；联调侧另核对存在问题时 `quoteProblemCount > 0`。
6. **必测 6**：加载失败保留入口 + 面板短错误 + 重试，由组件测试覆盖。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**210 passed / 48 skipped / 0 failed**
  （skipped = 38 golden 预览 + 10 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过
  （8 文件 10 用例串行，含新增估值联调）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 5. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

1. `valuation_status_dialog_dark.png` / `valuation_status_dialog_light.png`：
   同屏三行——ETH「暂无报价」、BTC「缺少 USDT → CNY 的估值路径」、
   USDT 现金「汇率较旧」；均保留原始数量，无解释性文案。
2. `valuation_status_dialog_error_dark.png`：加载失败态只有
   「状态加载失败，请重试。」+ 重试按钮，无技术细节、无客户端猜测结果。

## 6. 未完成项 / Codex 集成注意事项

- 无后端阻塞。
- `FxRateVm` / `QuoteRepository.listFxRates()` / `fxRatesProvider` 已删除：
  若集成线其他分支引用过它们，合并时需一并改为消费 valuation-issues。
- 联调测试会向临时账本写入 `USDT/USD`、`USD/CNY`、`JPY/CNY` 三条汇率，
  故在 smoke 中排在最后，避免影响先跑的联调文件。

本回执不含 token、密码、认证文件内容或真实账本数据。
