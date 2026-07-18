# 2026-07-18 前端可用性批 · 完成回执

执行对象：Claude（前端线）。对应三份任务单：

- `docs/handoffs/2026-07-18-claude-remove-defensive-copy.md`
- `docs/handoffs/2026-07-18-claude-subscription-next-charge-date-fix.md`
- `docs/handoffs/2026-07-18-claude-compact-valuation-status-and-multi-asset-account.md`
  （含用户点名的 P0：多资产账户界面 + `holding-adjustment-proposals`）

基线：`origin/feat/subscription-sync-integration @ cadaf04`。分支：
`feat/frontend-usability-0718`，独立工作树 `finwealth-usability-0718`。
纯前端 diff：未改 `server-rs/**`、`docs/contracts/**`、`tools/contract_check.py`、
`tools/local_ledger_smoke.py`、部署与生产数据。`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `fb0a698` | 全局删除防御性/实现边界文案 + 可见字符串静态扫描测试 |
| `271de08` | 订阅开始日期与下次扣费日分离（VM/body/表单/校验/400 用户化） |
| `971f973` | 首页估值状态降级 + 估值面板（新增 GET /v1/fx-rates 只读映射） |
| `16dc177` | 多资产账户详情 + 持仓导入/校准（新端点接入） |
| （最后一笔） | 真实联调 ×2 入 smoke + 4 张新 golden + 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 防御性文案清理（任务单 1）

- 清理任务单列出的全部 14 处 + `lib/features/**` 全文复查追加命中
  （订阅取消 SnackBar、DEMO/数据源工程命名、`kReadOnlyHint` 工具路径、
  连接失败页脚本名等）。
- 成功反馈收敛为「已加入待确认 / 已入账 / 已保存」等状态短句；按钮改
  「导入 / 提交更正 / 提交合并 / 保存」；无新「了解更多」卡片。
- 新增门禁 `test/defensive_copy_scan_test.dart`：扫描 lib/features、lib/app、
  lib/shared 的字符串字面量（注释不受限），禁用短语含 本应用/不代表/只生成/
  确认后才/候选/复核/账本/真实退订/MVP/local_server/Rust/后端 等；
  依赖旧文案的 6 个测试文件全部更新。

## 3. 订阅日期分离（任务单 2）

- `CreateSubscriptionInput`/`UpdateSubscriptionInput` 增加 `nextChargeDate`，
  `_createSubBody`/`_updateSubBody` 显式映射（null 省略 → 交给服务端
  startDate 顺延规则）。
- 表单同时显示「订阅开始日期」「下次扣费日」；新建默认相等并联动，
  用户手动改过后不再联动但提交前校验不得早于开始日期
  （`nextChargeDateError`，中文文案）；编辑用服务端值初始化，不按今天猜。
- 服务端 400（nextChargeDate 冲突）转「下次扣费日不能早于订阅开始日期」，
  不暴露 `subscriptions[0]`/wire 字段/英文校验文本。
- 顺带修掉新测试暴露的两个存量 360 宽溢出（期限分段控件、币种下拉）。
- 测试 9 条（`subscription_next_charge_test.dart`）：body 断言 create/update
  携带与省略、默认联动、手动保留、更早阻止、编辑初始化、400 转译、
  360/1200 无溢出。真实联调见 §6。

## 4. 首页估值状态降级（任务单 3 §2/§3）

- 「待处理」大卡剔除报价问题行；只剩估值问题时整卡隐藏。
- 净资产旁只留一个低强调入口「估值待完善 N」（N = stale+offline+
  unpriceable+error 之和，服务端口径）；无问题完全隐藏；不再常驻
  「N 项报价过期 · 本地缓存」，净资产不因估值不完整变警告色，≈ 保留。
- 点击开受限宽度面板：标题「部分资产暂未计入总值」+ 保留原始数量的简短
  说明 + 按账户/资产列原始数量与真实原因——缺路径「缺少 X → CNY 的估值
  路径」、stale「报价较旧/汇率较旧」、仅 offline cached 才写「使用缓存」；
  「刷新估值」失败不关面板。组合逻辑为纯函数 `composeValuationIssues`
  （accounts + holdings + 新增 `GET /v1/fx-rates` 只读映射，不猜价格）。
- 测试 9 条（`valuation_status_test.dart`）覆盖任务单 §5 场景 1–4。

## 5. 多资产账户 + 持仓校准（任务单 3 §4 + 用户 P0）

- 账户详情分组：「现金与稳定币」（各币种原始数量，不折算不加符号）与
  「持仓」（原始数量为主、折算金额次要；缺报价显示「暂无估值」，绝不显示
  0 元）；账户总值带质量前缀与「截至 <as-of>」。
- 点持仓行 →「校准持仓」（带当前数量）；「添加资产」→ 从服务端标的选择
  （加载/失败重试/空态齐全，前端先拦不被账户支持的报价币种）。两者提交
  `POST /v1/accounts/{id}/holding-adjustment-proposals`
  （新 `HoldingAdjustmentInput` + `PortfolioRepository.proposeHoldingAdjustment`；
  fixture/real_local 抛 UnsupportedError 不伪造成功），成功「已加入待确认 +
  前往审核」，失效 aiPending/overview。
- 409 →「数据已发生变化或已有待确认调整」+ 重新加载；400 显示服务端校验
  原因；网络错误保留弹窗；busy 防重复提交。
- 测试 11 条（`holding_adjustment_test.dart`）：增/减/清零 body 断言、
  409/400 不伪造成功、目标数量校验（0 合法）、多资产展示与「暂无估值」、
  币种不支持拦截、重复提交、360/1200 无溢出。

## 6. 真实 Rust 联调（当前源码 cargo 构建，临时账本）

`tools/frontend_local_server_smoke.ps1` 现串行 5 个文件 7 条用例，全绿：

- `local_server_holding_adjustment_integration_test.dart`（新）：
  交易所账户 + USDT 计价标的 → 提案后确认前持仓不变 → 同持仓重复提案
  409 → 确认后 0.00076078 → 依次校准 10 → 6 → 0（清零生效）→ BTC 计价
  标的在 USDT 账户提案 400。
- `local_server_subscription_integration_test.dart`（追加用例）：本月已付、
  下月 17 日再扣创建成功；编辑仅把开始日期移过旧扣费日 → 服务端顺延到新
  开始日期；显式更晚日期保留。
- 既有订阅/账户/DCA/投资成交联调不受影响。

## 7. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**187 passed / 38 skipped / 0 failed**
  （skipped = 31 golden 预览 + 7 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过（5 文件 7 用例）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 8. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

`test/goldens/`（31 张全部重生成，含文案清理后的首页/订阅列表/订阅详情/
AI 审核）；新增：

1. `overview_dark_phone.png`：大待处理卡无报价行，净资产旁低强调
   「估值待完善 2」，无「报价过期/本地缓存」。
2. `account_multi_asset_dark/light.png`：OKX 下 USDT 123.45 /
   BTC 0.00076078 ≈¥380.00 / ETH 0.25「暂无估值」，「添加资产」入口，
   总值 ≈¥890.00 + 截至时间。
3. `valuation_status_dialog_dark.png`：面板列 OKX·ETH 0.25 与
   OKX·USDT 123.45 及各自「缺少 X → CNY 的估值路径」。
4. `subscription_form_dual_dates_dark.png`：订阅开始日期 + 下次扣费日
   双字段（默认同日），自动续订无防御性副标题。

## 9. 未完成项 / 阻塞

无后端阻塞。围栏外未做：后端 valuation issue DTO 出来前，面板原因由前端
读模型组合（已按任务单授权）；stale/offline 的逐资产真机截图未取
（不抢用户桌面焦点，离屏渲染替代）。

本回执不含 token、密码、认证文件内容或真实账本数据。
