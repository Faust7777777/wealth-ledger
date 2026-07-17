# Claude 前端续作：投资成交 UI 修正与交付要求

日期：2026-07-17  
前端工作树：`C:\Users\15892\projects\finwealth-investment-trade-ui`  
前端分支：`feat/investment-trade-ui @ 613aece`  
最低集成基线：`d30d78d12d04922b1b68f2ad71e798407b20ece2`；实际恢复时必须同步 `origin/feat/subscription-sync-integration` 的最新提交

## 当前结论

现有 4 个提交已经打通投资成交的数据层、买卖表单、多腿账本映射、成交详情和真实 Rust smoke，功能方向正确，应保留：

```text
947be8a instrument / trade VM 与 Repository 映射
c2e4ff5 手动买入/卖出表单及多腿请求映射
309ba8f saleResult / costBasisFx 成交详情展示
613aece mapping、validation、widget 与真实 Rust smoke
```

当前尚不满足集成条件，主要问题是基线落后、fixture 文件行尾噪声、录入体验偏工程化、加载和错误状态不完整，以及缺少视觉证据。Claude 恢复工作后按下面顺序处理。

## P0：同步正确基线且不回退后端

当前实际 merge-base 是 `b5146e4`，必须把纯前端提交放到最新集成基线上，且不得早于 `d30d78d`。

完成后确认：

- `server-rs/**` 保留投资成交 replacement correction；
- `docs/contracts/**` 保留 `InvestmentReplacement`；
- 不修改或回退 `tools/contract_check.py`、`tools/local_ledger_smoke.py`；
- `git diff <集成基线>..HEAD -- server-rs docs/contracts tools/contract_check.py tools/local_ledger_smoke.py` 为空；
- 不用旧工作树整仓覆盖新基线。

## P0：消除无关 diff

`lib/data/fixture_repositories.dart` 被整文件 CRLF 重写，普通 diff 约 1300 行，忽略行尾后真实修改约 42 行。

要求：

- 恢复仓库既有 LF；
- 只保留 instrument fixture、`instrumentId` 和只读 trade 行为等真实修改；
- `git diff --check` 零输出；
- 普通 diff stat 不再与忽略行尾后的 stat 出现数量级差异。

## P0：收敛界面文案与录入流程

1. 删除常驻解释文案“这里只展示事实统计，非投资建议。”空态只保留简短操作引导，例如“记录第一笔成交，或创建定投计划。”
2. 不出现“后端已支持”“真实 API”“多腿账本”“MVP”“不会下单”等实现边界说明。
3. 摘要不再必填。默认自动生成“买入 <标的名称>”或“卖出 <标的名称>”，用户可选覆盖。
4. 成交时间默认现在，使用日期/时间选择器；界面显示本地时间，请求转换为 RFC3339 UTC，不要求手填 `YYYY-MM-DD`。
5. 360 宽下“数量/价款”和“手续费/税费”改为纵向；宽屏可两列。校验文案不得挤压相邻字段。
6. instruments 加载中显示加载态；只有成功且为空才显示空态；加载失败提供重试。

## P1：错误、完成和详情状态

- 400：显示字段或成交校验错误；
- 403：显示当前账号无记录权限；
- 409：提示数据已变化并提供重新加载；
- 网络错误：保留表单并提供重试；
- 仅 `ledgerWrite=true` 显示“已入账”；
- `ledgerWrite=false` 不得直接表现为完成，应保留页面或提供“前往审核/重新加载”；
- “释放成本（平均成本法）”简化为“本次成本”，算法说明放 tooltip 或折叠区；
- `costBasisFx` / `fxBasis` 保持只读折叠展示，不展示 `sourceRateId`；
- 盈亏币种使用服务端结果，不以当前汇率重算历史。

## 视觉验收

至少提供以下真机截图或真实主题、真实字体的 golden/离屏渲染：

1. 360×800 买入表单；
2. 360×800 卖出表单及数量超限错误；
3. 1200×800 桌面买入表单；
4. 买入和卖出确认摘要；
5. 同币种盈利详情；
6. 跨币种亏损详情及折叠换算依据；
7. 明暗主题各至少一张。

肉眼确认：手机字段不拥挤、弹窗宽度受限、没有 wire enum/内部 ID/技术说明、盈利/亏损/零值颜色语义正确。

## 回归门禁

```text
git diff --check
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
pwsh -NoProfile -File tools/frontend_local_server_smoke.ps1
pwsh -NoProfile -File tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly
```

真实 smoke 必须从同步后的当前 Rust 源码构建，不能复用旧后端。

## 交付边界

- 推送独立分支 `feat/investment-trade-ui`；
- 在 `docs/handoffs/2026-07-17-investment-trade-ui-done.md` 写完成回执；
- 回执包含最终 commit、提交列表、全量测试数、真实 Rust smoke、视觉证据和 `git diff --check` 结果；
- 不合并集成线、不创建 Release、不修改生产数据；
- 集成、重新打包和部署交回 Codex。

Codex 接收条件：前端分支已推送、基于最新集成线、纯前端 diff、全部门禁通过、视觉核验完成。任何一项缺失都先留在前端分支修正，不进入集成线。
