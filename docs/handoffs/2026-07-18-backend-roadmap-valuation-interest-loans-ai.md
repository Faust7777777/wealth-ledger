# Finwealth 后端路线：估值、收益、贷款利息与 AI 整理

日期：2026-07-18  
执行分支：`feat/subscription-sync-integration`

## 当前真实缺口

### 1. 多币种与多资产估值

现有账本已经有 `Account + Instrument + Holding + Quote + FXRate`，但缺少完整的用户录入和报价路径：

- 交易所账户无法方便地录入 USDT、BTC、ETH 等多个当前持仓；
- 目前只能通过真实买卖成交生成 holding，不适合导入已有资产；
- 生产没有 BTC/ETH/USDT 到 CNY 的完整报价与汇率路径；
- 缺失估值时首页只给计数，不能说明具体账户和资产；
- 不允许猜价、按 0 计入或覆盖原始数量。

目标模型：账户是容器；每个资产保留独立原始数量；本位币总值是带 `asOf` 和质量状态的派生投影。

### 2. 有明确利率的投资产品

适用对象：定期存款、现金管理、固定收益理财、债券等。股票、基金和加密资产的市场涨跌不建模为“利率”。

需要：

- principal、币种、年化利率、起息日、到期日；
- simple/compound、计息基准与复利周期；
- 已计提利息、预计到期收益和下一结息日；
- 利息只生成候选，确认后才成为收入 movement；
- 修改条款不回写已经确认的历史利息。

### 3. 贷款利息与还款计划

需要：

- 当前本金、年利率、期限、放款日；
- 等额本息、等额本金、先息后本和自定义计划；
- 每期本金/利息拆分、剩余本金和下一还款日；
- 还款候选确认后才同时减少现金和贷款本金；
- 提前还款、利率调整和计划变更保留历史，不覆盖原 movement。

### 4. 真实 AI 整理

现有 proposal、atomic group、审核、确认和证据引用基础设施已实现；缺少真实模型 provider。

需要：

- 文本、CSV、截图/OCR 结构化；
- 账户、分类、对手方、币种和金额候选；
- 低置信度字段、冲突和证据定位；
- 模型只创建 pending proposal，永不直接确认写账；
- 发送模型前做敏感数据最小化，并提供明确 provider 开关。

## 排期与依赖

| 阶段 | 后端内容 | 预计 |
| --- | --- | ---: |
| P0-A | 修复估值状态计数；前端弱化提示任务单 | 0.5 天 |
| P0-B | 持仓导入/数量调整 API、幂等与审计 movement | 1.5–2 天 |
| P0-C | BTC/ETH/USDT 报价路径、缓存、质量与缺失详情 | 1.5–2 天 |
| P1-A | 固收产品利率、计提与收益候选 | 2–3 天 |
| P1-B | 贷款计息、还款计划与确认入账 | 3–5 天 |
| P2 | AI provider、结构化导入、安全与联调 | 4–7 天 |

前后端并行时，四项达到可用状态预计 2–3 周。第一阶段“OKX 多资产录入并可靠显示本位币总值”预计 3–5 个工作日。

## 第一阶段接口方向

建议新增持仓导入命令，而不是伪造 buy movement：

```text
POST /v1/accounts/{accountId}/holding-adjustment-proposals
```

输入包含 instrument、目标 quantity、可选成本基础、asOf 和 note。服务端根据现有 holding 生成完整 adjustment proposal；确认前不改变持仓，确认后形成可追溯 movement 和 sync change。重复请求必须由幂等键保护。

估值继续使用：

```text
原始 quantity × instrument quote
quote currency × FX path → ledger base currency
```

任何路径缺失时保留原始数量、标记 incomplete，并从总值中排除；不得写成 0。
