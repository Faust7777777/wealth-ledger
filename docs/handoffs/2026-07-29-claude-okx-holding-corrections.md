# Claude 前端任务：OKX 多资产持仓修正

基线待 Codex 后端分支合入后确定。只改 Flutter 与前端测试；不要修改 `server-rs/**`、`agent-service/**`、契约和部署。

## P0.1 账户内合计使用正确币种

后端 `Holding` 新增可选 `accountMarketValue`：

- `marketValue`：账本本位币（当前生产为 CNY），用于组合/净资产。
- `accountMarketValue`：账户 `defaultCurrency`，用于该账户详情中的持仓合计。

更新 `HoldingVm` 和 HTTP 映射。`AccountHoldingsSection` 必须用 `accountMarketValue` 求和，不能拿 CNY `marketValue` 与账户默认币种混算。

当 `pricedCount == 0` 时，合计显示 `—`，不能显示 `0`。只有至少一项成功计价才显示部分合计；未计入项仍保留低强调入口。

## P0.2 刷新失败不得显示内部英文

截图中的 `instrument has no public-provider symbol` 不得原样显示给用户。后端会修复 BTC/ETH/USDT 的旧标的识别；前端仍需把报价刷新错误映射成短中文：

- 缺标的代码：`无法识别该资产`
- 缺报价：`暂时没有可用报价`
- 缺 FX：`暂时无法换算为 CNY`（目标币种取接口值，不硬编码）
- 其他失败：`刷新失败，请重试`

错误详情可在低强调详情中查看，不在首页 Snackbar 暴露服务端英文。

## P0.3 快照审核后精确刷新账户详情

接受/拒绝 holding snapshot/adjustment 组后，除现有全局 provider 外，精确失效涉及账户的：

- `accountByIdProvider(accountId)`
- `holdingsByAccountProvider(accountId)`

账户 ID 从组内 movement 的 `holdingAdjustment.accountId` 或 entry 推导。测试必须先保持账户详情打开，再在审核动作后断言数量原地更新，不依赖退出重进。

## P0.4 账户表单术语与默认值

现有“支持币种”容易被理解为“这个账户持有哪些币”，这是本次生产错误数据的直接诱因。改成：

- `defaultCurrency`：标签“账户折算单位”；交易所账户新建时默认 USDT。
- `supportedCurrencies`：标签“交易计价单位”；说明只在字段帮助入口中出现，正文不加解释段落。
- BTC、ETH、USDT 资产由持仓/标的选择器管理，不由这个多选字段表示。

编辑现有账户时不得静默改默认单位；由用户明确保存。

## P1 标的缺失流程

“添加资产”找不到 BTC/ETH/USDT 时，提供“登记资产”动作，走后端后续提供的确定性 crypto 标的登记接口。不能由 Flutter 生成 `instrumentId`，也不能仅凭显示名伪造成功。

## 必测

1. 账户默认 USDT、后端 `marketValue=CNY`、`accountMarketValue=USDT`：合计只显示 USDT 正确值。
2. 全部持仓不可计价：合计为 `—`，不是 0。
3. 一项可计价、一项缺报价：显示部分合计与 1 项入口。
4. 报价接口返回内部英文：主界面和 Snackbar 均不出现英文实现错误。
5. 快照组确认时账户详情保持挂载，数量立即刷新。
6. 360 宽多资产列表、估值问题弹层与错误态无 overflow。

