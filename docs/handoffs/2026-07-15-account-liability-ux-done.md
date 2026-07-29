# 2026-07-15 账户创建与负债展示可用性收尾 · 完成回执

执行对象：Claude（前端线）。对应任务单
`C:/tmp/2026-07-15-claude-account-liability-ux-handoff.md`。

基线：`origin/feat/subscription-sync-integration @ b3d68ef`。分支：
`fix/account-liability-ux`，工作树 `C:\Users\15892\projects\finwealth-account-ux`。
只改 Flutter 前端/映射/前端测试与 smoke 工具的测试清单；未修改 `server-rs/**`、
`docs/contracts/**`、部署脚本、认证状态、生产数据、wire enum 或账本 schema。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `0ef55d0` | 分组类型选择器、余额模式派生、期初余额/当前欠款、负债展示语义、12 项回归 |
| `95a93a8` | 真实 local-server 账户联调 + smoke 串行跑订阅/账户两个联调文件 |
| `008b7a6` | 负债/表单/选择器 4 张 golden 预览（PNG 不入库） |

最终提交为本回执 docs 提交。远端分支：`origin/fix/account-liability-ux`。
集成与生产部署归 Codex。

## 2. P0 落地对照

**账户类型选择器（§3）**：`AccountTypePickerDialog`（新文件
`lib/features/account_type_picker.dart`）——4 组（日常资金/投资资产/负债/其他）
×11 类型，每项显示新名称+示例；内容宽 400、列表高约束 240–420 内部滚动；
不显示 wire enum/balanceMode/实现解释。表单字段（`kAccountTypeFieldKey`）显示
「名称 · 示例」。平铺巨型下拉已移除。

**余额模式自动派生（§4）**：表单不再有「余额模式」字段。
`defaultBalanceModeFor()`：creditCard/loan→`liability`，brokerage/exchange/
wallet/socialSecurity→`holdings`，其余→`cash_balance`。编辑不改类型 → 保留服务端
原值（含历史 `mixed`）；改类型 → 切新默认。无高级模式选择器。

**期初余额与当前欠款（§5）**：`CreateAccountInput.openingBalance`（Money?）+
`LocalServerAccountRepository.createAccount()` 映射
`openingBalances: [{currency, amount, quality: 'exact'}]`；空值发送 `[]`。
资产表单「期初余额（可选）」原样发送；信用卡/贷款表单「当前欠款（可选）」正数
录入 → 前端发送 `-金额`；**输入 0 固定发送空数组（已测试）**。金额校验为十进制
定点字符串 ≤8 位小数（`account_form_validation.dart` 纯函数），全程无浮点。
编辑（PATCH）不发送 `openingBalances`、不覆盖既有余额。页面无「负数是正常的」
类说明。

**负债展示（§6）**：空态「暂无负债账户」+「添加信用卡或贷款」→
`/accounts/new?type=creditCard`（默认选中信用卡）；整句「信用卡、贷款等负债会
显示在这里；负债余额为负是正常的。」已删除。金额语义（`account_visuals.dart`，
仅展示层，不动 mapping/API 原值）：`<0` 显示绝对值+「当前欠款」；`=0`
「¥0.00 已还清」；`>0` 显示原值+「溢缴款」，不展示成欠款；全程无负号。
账户详情页 `isLiability` 时 Hero 与分币种行（段题改「欠款明细」）同规则；
资产账户维持原符号展示。

**P1 文案（§7）**：银行→银行账户、钱包→数字资产钱包、平台余额→支付平台余额、
券商→证券账户、交易所→数字资产交易所、社保→社保/养老金、虚拟卡→虚拟卡/预付卡、
其他→其他账户。表单保留名称/类型/默认币种/机构名称/计入净资产；无 MVP/能力/
负数约定类常驻文案。

## 3. 测试（任务单 §8 的 12 项 → `test/account_liability_ux_test.dart`，全绿）

1 空态无「负债余额为负」；2 空态按钮→全应用路由→新建页默认信用卡+「当前欠款」；
3 选择器分组+新名称、11 enum 全可选且不暴露内部概念；4 信用卡→`liability`；
5 贷款→`liability`；6 银行→`cash_balance`；7 欠款 2000.00→POST
`-2000.00 CNY`（真实 MockClient 捕获 POST body）；7b 欠款 0→空数组（固定行为）；
8 期初 100.00→原样；9 编辑 mixed 不改类型→PATCH 仍 `mixed` 且无 openingBalances
键；10 `-2000.00` 显示 `¥2,000.00` 无负号（另 10b：0 显示已还清）；11 正余额显示
溢缴款不显示欠款；12 1200×800 与 1440×900 下选择器表面 ≤480 宽、≤75% 屏高、无
overflow。4–9 经由「表单交互 → LocalServerAccountRepository → MockClient」全链路
断言真实 HTTP body。

## 4. 门禁实际结果（任务单 §8 全部运行）

- `dart format --output=none --set-exit-if-changed lib test`：通过（0 处需改）。
- `flutter analyze`：No issues found。
- `flutter test`：**119 passed / 21 skipped / 0 failed**（skipped = 18 golden
  预览[仅 PREVIEW_GOLDENS=1] + 3 真实联调[仅 smoke 注入 env]）。
- `pwsh tools/frontend_local_server_smoke.ps1`：**通过**，
  `OK: Flutter local-server integration smoke passed (subscriptions + accounts)`。
  账户场景按任务单：真实服务上创建期初 100.00 的银行账户（`cashBalances=100.00`）
  与欠款 2000.00（账本 `-2000.00`）的信用卡（`isLiability=true`），读取 overview
  快照做前后差值核对：总资产 +100.00、净资产 −1900.00、总负债变化幅度 2000.00
  （差值法与账本既有数据解耦）。smoke 现以 `--concurrency=1` 串行跑订阅+账户两个
  联调文件，避免同账本写入交错。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：**通过**，
  `Windows self-use package readiness passed`。

## 5. 真实 Windows 截图核验结论（如实说明）

本轮**未能**完成真机交互截图：执行时桌面正被用户实际使用——`CopyFromScreen`
截到前台浏览器覆盖内容；出于不抢用户焦点/不注入鼠标键盘的原则放弃驱动真实输入；
改试 `PrintWindow(PW_RENDERFULLCONTENT)` 无焦点抓取，但只能抓到标题栏，Flutter
的 DirectX 合成内容抓不到。

替代视觉证据（已逐张肉眼核验，PNG 走 gitignore）：真实主题+真实 Noto 字体的
离屏渲染 4 张——负债三态行（¥2,000.00 当前欠款 / ¥0.00 已还清 / ¥500.00 溢缴款 /
¥9,620.00 当前欠款，全部无负号）、负债空态（新标题+新按钮、无解释句）、信用卡
新建表单（类型字段带示例、「当前欠款（可选）」、无余额模式字段）、类型选择器
（分组+示例、受限尺寸内滚动）。尺寸/不占整屏另有 widget 断言（测试 12）。
建议用户下次启动自用包时顺手目验一次；桌面空闲时可用上一轮的
GetDpiForWindow+MoveWindow+CopyFromScreen 流程补真机截图。

本回执不含 token、密码、认证文件内容或真实账本数据。
