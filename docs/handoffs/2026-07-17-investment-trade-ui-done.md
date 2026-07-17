# 2026-07-17 手动投资成交 UI · 完成回执

执行对象：Claude（前端线）。对应任务单
`C:/tmp/2026-07-17-claude-frontend-continuation-handoff.md` 与后续修正单
`docs/handoffs/2026-07-17-claude-investment-trade-ui-followup.md`。

基线：`origin/feat/subscription-sync-integration @ dc8c36c`（≥ 修正单要求的
`d30d78d`）。分支：`feat/investment-trade-ui`，独立工作树
`C:\Users\15892\projects\finwealth-investment-trade-ui`。
`git diff dc8c36c..HEAD -- server-rs docs/contracts tools/contract_check.py
tools/local_ledger_smoke.py` 为空（后端投资成交 replacement correction 与
`InvestmentReplacement` 契约完整保留，未回退）；`git diff --check` 零输出；
`fixture_repositories.dart` 已恢复 LF，分支 diff 仅 42 行真实修改。

## 1. 提交列表（基线之上，回执提交另计）

| commit | 用途 |
| --- | --- |
| `4e958a6` | instrument / trade VM 与 Repository 映射（含 saleResult/costBasisFx 只读映射、supportedCurrencies、instrumentId） |
| `ac9a8fc` | 手动买入/卖出表单、多腿请求映射、入口与路由 |
| `aee4f5d` | 成交详情：saleResult / costBasisFx 展示 |
| `891b4b0` | mapping / validation / widget 测试 + 真实 Rust smoke |
| `3ba3c93` | fixture 与新测试文件行尾恢复 LF |
| `2564538` | 修正单 P0/P1：文案收敛、录入体验、错误状态用户化 |
| `26b81dc` | 8 张成交视觉预览（golden） |

合并、重新打包与生产部署归 Codex；未合并集成线、未创建 Release、未动生产数据。

## 2. 数据层

- `InstrumentVm` / `CreateInstrumentInput` + `InstrumentRepository`
  （GET/POST `/v1/instruments`；fixture/real_local 不伪造写入）。
- `InvestmentTradeInput` → `MovementRepository.createInvestmentTrade`：
  沿用真实流水线 drafts → submit-review → confirm；买入现金腿 out/source、
  持仓腿 in/destination 带 `instrumentId`，卖出方向反转；fee/tax 空或纯零
  不发腿，发腿时与主腿同资金账户、同现金币种。持仓腿币种 = 所选标的
  `quoteCurrency`（买入前端另做持仓账户支持币种校验，避免撞服务端 400）。
- Movement 响应新增 `saleResult` / `costBasisFx` 只读映射（缺失兼容，
  未知盈亏状态兜底为"暂不可计算"，绝不给出错误盈亏）。
- `DevApiClient`：400 → `ApiValidationException`（携带服务端 message 与
  details.errors）；其余 4xx 错误带上服务端 message。幂等键与 401 单飞重放
  复用既有路径（有测试）。

## 3. UI（含修正单 P0/P1 全部要求）

- 入口：「记录」面板新增「投资成交」+ 投资页主要操作区按钮，均受
  `canRecordMovement` 门控；路由 `/investment/trade/new`。
- 表单：买入/卖出分段控件；资金账户（active、cash_balance|mixed）与持仓账户
  （active、holdings|mixed）用受限尺寸选择弹窗；标的弹窗内置加载态/失败重试/
  真空态三态，买入从服务端标的中选（附紧凑「添加标的」），卖出只列所选账户
  数量>0 的持仓——全程不手填 wire ID。
- 成交币种限于资金账户 supportedCurrencies；数量/价款与手续费/税费在
  <480 逻辑宽纵向排列，宽屏两列；桌面表单主体 ≤720。
- 摘要可选，留空自动生成「买入/卖出 <标的名称>」；成交时间默认「现在」，
  日期+时间选择器（本地显示，RFC3339 UTC 发送，未修改时省略由服务端取时）。
- 校验（纯字符串定点，不经 double）：数量/价款必填正数 ≤8 位小数；fee/tax
  非负 ≤8 位小数；卖出 fee+tax ≤ 毛回款、数量 ≤ 当前持仓；确认摘要显示
  价款/费/税/现金合计支出（买）或净入账（卖）/数量。
- 结果语义：仅 `ledgerWrite=true` 显示「已入账」并返回；false 时留在表单，
  提示待确认候选并提供「前往审核」。400 显示服务端校验原因；403 提示无记账
  权限；409 提示数据已变化并提供「重新加载」；网络错误保留表单提示重试。
- 成交详情：毛回款/手续费与税费/现金净入账/「本次成本」（平均成本法说明收进
  tooltip）/已实现盈亏（盈利收益色、亏损亏损色、零中性；金额只用服务端固化
  结果，不以当前汇率重算历史）；`calculated_with_fx` 另显折算净回款 + 可展开
  「换算依据」（汇率/时间/来源，不展示内部 rate ID）；`cost_basis_unavailable`
  →「盈亏暂不可计算」、`currency_mismatch` →「缺少成交时汇率」；旧记录缺字段
  正常渲染。已删除「非投资建议」等常驻解释文案；界面无 wire enum/实现说明。

## 4. 测试

`test/investment_trade_test.dart` 22 条，覆盖任务单 §11 全部 16 项 +
持仓账户币种校验、403/网络错误留表单。要点：买入 100+2+1 四腿逐字段断言、
卖出方向与 role、fee/tax 空零不发腿、401 重放同幂等键、400/403/409 不伪造
成功（400 收紧为 ApiValidationException）、ledgerWrite=false 不显示已入账且
表单保留、saleResult 四状态映射+展示、fx 结果只用服务端值、旧记录兼容、
360/1200/1440 无 overflow 且桌面宽度受限。

全量：`flutter test` **157 passed / 32 skipped / 0 failed**
（skipped = 27 golden 预览[仅 PREVIEW_GOLDENS=1] + 5 真实联调[仅 smoke 注入 env]）。

## 5. 真实 Rust 联调（`test/local_server_investment_trade_integration_test.dart`）

从同步后的当前源码 cargo 构建起服（smoke 全程临时账本）：

1. 创建现金账户（期初 1000.00 CNY）、持仓账户、标的；
2. 草稿与提交复核阶段现金/持仓/成本全部不变；
3. 确认买入（价款 100 + fee 2 + tax 1、数量 10）→ 现金 897.00、数量 10、
   成本 103.00；
4. 确认卖出（数量 4、毛回款 40、fee+tax 2）→ 现金 935.00、剩 6、成本按平均
   成本释放为 61.80；movement 详情映射 saleResult：released 41.20、
   realizedPnl −3.20、status calculated；
5. 跨币种：USD 成本持仓（50.00 USD/5 股）→ 注入两条 CNY→USD 汇率
   （0.14 @07-15、0.20 @07-17）→ 07-16 卖 2 股回款 20.00 CNY →
   `calculated_with_fx`，fxBasis.rate=0.14、asOf=07-15（历史汇率，未用未来
   0.20），折算净回款 2.80 USD、realizedPnl −17.20 USD。

`pwsh tools/frontend_local_server_smoke.ps1`：**通过**（订阅 + 账户 + DCA +
投资成交共 5 条联调串行全绿）。

## 6. 门禁实际结果（修正单清单全部运行）

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：157 passed / 32 skipped / 0 failed。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过（当前源码构建）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 7. 视觉证据（真实主题 + Noto 真实字体离屏渲染，已逐张肉眼核验）

`test/goldens/`（gitignore，本机可复现：`PREVIEW_GOLDENS=1 flutter test
--update-goldens test/preview_golden_test.dart`）：

1. `trade_form_buy_phone_dark.png`（360×800 买入，字段纵向、无拥挤）；
2. `trade_form_sell_error_phone_dark.png`（360×800 卖出，数量超限红字 +
   按钮禁用）；
3. `trade_form_buy_desktop_light.png`（1200×800，两列、主体 ≤720 居中）；
4. `trade_confirm_buy_light.png` / `trade_confirm_sell_dark.png`
   （确认摘要：合计支出 4,130.00 / 净入账 1,657.34，弹窗宽度受限）；
5. `trade_detail_profit_dark.png`（同币种盈利 +¥6.14 收益色、「本次成本」
   tooltip 图标）；
6. `trade_detail_fx_loss_dark.png` + `trade_detail_fx_loss_desktop_light.png`
   （跨币种亏损 −$17.20 亏损色、展开换算依据 1 CNY = 0.14 USD，无内部 ID）。

明暗主题均有覆盖；界面无 wire enum/内部 ID/实现说明文案。真机交互截图仍
受"用户使用桌面时不抢焦点"约束，未截取；离屏渲染 + 尺寸断言（测试 16）替代。

## 8. 未完成项 / 阻塞

无后端阻塞。围栏内未做（任务单 §16 明确暂不做）：投资 movement 更正 UI、
券商连接/下单/自动同步、自动确认与后台 timer、客户端成本基础算法、
DCA totalCost 语义变更。

本回执不含 token、密码、认证文件内容或真实账本数据。
