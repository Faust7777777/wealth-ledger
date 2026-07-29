# 多资产账户与持仓快照前端任务单

基线以 Codex 合入并推送的 `feat/integration-self-use` 最新远端提交为准。Claude 只修改 Flutter 前端、前端测试、golden 和自己的回执，不改 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、部署与发布脚本。

## 目标

让 OKX、交易所和钱包账户真正按多资产账户使用：用户看到 BTC、ETH、USDT 的原始数量、逐项折算价值和账户合计；Pi Agent 从账单、CSV、XLSX 或截图整理出的多项数量，以一个审核组呈现并整体确认或拒绝。

## 后端契约

```http
POST /v1/accounts/{accountId}/holding-snapshot-proposals
Idempotency-Key: <required>
Content-Type: application/json
```

```json
{
  "asOf": "2026-07-29T10:00:00Z",
  "positions": [
    {"instrumentId": "inst_btc_usdt", "targetQuantity": "0.25"},
    {"instrumentId": "inst_eth_usdt", "targetQuantity": "3.2"},
    {"instrumentId": "inst_usdt", "targetQuantity": "1250"}
  ],
  "note": "OKX 持仓快照"
}
```

- `positions` 为 1–100 项；同一 instrument 不得重复；数量为非负十进制字符串。
- 响应仍是现有 `AiAtomicGroup`，`proposedMovements` 包含每个发生变化的标的。
- `skippedPositions` 报告数量未变化的标的，当前 `reason` 只有 `unchanged`。
- 全部数量未变化返回 409；任一标的无效、币种不受支持或已有待审核调整时整次失败。
- 确认前 holdings、overview 和 allocation 不变化；确认/拒绝沿用现有 atomic-group 接口。
- Pi 工具名为 `finwealth_propose_holding_snapshot`，只生成审核组，不会自动确认或采用报价。

## P0 界面

1. 账户详情对 `exchange`、`wallet`、`holdings` 和 `mixed` 账户展示多资产列表。
2. 每行显示标的名称/代码、原始 quantity、报价单位、折算价值与报价状态；不得只剩一个推算后的总余额。
3. 顶部显示账户统一折算币种的合计。缺报价的资产仍显示原始 quantity，不把它按 0 混入合计。
4. 报价问题只做低强调的小入口，例如“2 项待补报价”；点开后复用现有 valuation issue sheet。不要放常驻解释性段落。
5. 待审核区把带 `holding_snapshot` tag 且 atomicGroupId 相同的 movements 合成一张“持仓快照”卡片。默认展示变化数量，展开后逐项显示 previous → target；只提供整组采用/忽略。
6. Agent 面板在工具完成或 run 完成后刷新 pending review。创建成功后给“前往审核”动作，不能宣称持仓已更新。
7. 账户编辑允许维护多个 supportedCurrencies；默认折算币种与支持币种分开。不要把“期初余额”表单伪装成多资产持仓编辑器。

## P1 更新持仓入口

- 账户详情放一个紧凑“更新持仓”入口，支持一次编辑现有多项 quantity，并通过批量接口提交。
- 可搜索并添加真实 instrument；不要由前端生成 instrumentId。
- 同一请求复用一个 Idempotency-Key，401 刷新重放仍用原 key。
- 409 后刷新账户持仓与待审核列表，保留用户输入供重新核对。

## 必测

1. 360 宽和 Windows 矮窗口下，多资产列表与审核组不溢出。
2. BTC、ETH、USDT 三项只出现一张审核卡；确认请求只发一次 atomic group confirm。
3. suggested/pending 时账户数量与 overview 不变，确认后一起刷新。
4. 某项清零可提交并在确认后消失。
5. unchanged 项不渲染成变化 movement；全部 unchanged 的 409 显示简短状态。
6. 缺 BTC 报价时 BTC quantity 可见，账户合计不把其价值当 0。
7. 401 重放幂等键不变；重复点击只发一次请求。
8. golden 至少覆盖交易所多资产详情与批量审核卡，明暗和窄屏各一组。

## 文案边界

不要出现“这是资产统计应用”“不会猜测价格”“仅供参考”“请自行核实”等防御性说明。界面只报告事实状态和可执行动作。
