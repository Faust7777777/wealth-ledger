# Claude 前端后续：改用权威估值问题接口

日期：2026-07-18  
基线：等待 Codex 推送包含 `GET /v1/portfolio/valuation-issues` 的集成提交后，从最新 `origin/feat/subscription-sync-integration` 派生。

## 发现的问题

当前 `lib/features/valuation_status_sheet.dart` 的 `composeValuationIssues` 在客户端组合 accounts、holdings 和 fx-rates，并且现金部分只识别直接汇率：

```text
USDT/CNY
或 CNY/USDT
```

后端现在支持最多三跳的 FX 路径，例如：

```text
USDT → USD → CNY
```

因此当前客户端可能把已经能够估值的 USDT 错误显示成“缺少 USDT → CNY 的估值路径”。客户端也无法可靠区分持仓究竟缺报价、缺 FX、报价过期还是路径中某段汇率过期。

## 新接口

```text
GET /v1/portfolio/valuation-issues
```

返回逐账户、逐资产的权威问题列表。主要字段：

```json
{
  "id": "valuation_holding_acct_okx_inst_btc",
  "accountId": "acct_okx",
  "accountName": "OKX",
  "assetKind": "holding",
  "assetId": "inst_btc",
  "assetLabel": "BTC",
  "quantity": "0.00076078",
  "quantityUnit": "BTC",
  "status": "unpriceable",
  "reason": "missing_fx_path",
  "sourceCurrency": "USDT",
  "targetCurrency": "CNY",
  "asOf": "2026-07-18T03:30:00Z"
}
```

`reason`：

- `missing_quote`
- `missing_fx_path`
- `stale_quote`
- `stale_fx`
- `offline_cached_quote`
- `offline_cached_fx`
- `quote_error`
- `fx_error`

## 前端修改要求

1. Repository 新增只读 `listValuationIssues()`，映射上述字段；GET 不带幂等键。
2. 新增 provider，估值面板直接消费该列表，不再读取 accounts + holdings + fx-rates 后调用 `composeValuationIssues`。
3. 删除生产代码中的直连汇率推断；纯函数若仅供旧 fixture 测试也应删除，避免形成第二套估值规则。
4. `reason` 只映射成简短状态：
   - `missing_quote` → `暂无报价`
   - `missing_fx_path` → `缺少 {sourceCurrency} → {targetCurrency} 的估值路径`
   - `stale_quote` → `报价较旧`
   - `stale_fx` → `汇率较旧`
   - `offline_cached_quote` → `使用缓存报价`
   - `offline_cached_fx` → `使用缓存汇率`
   - `quote_error` → `报价获取失败`
   - `fx_error` → `汇率获取失败`
5. 不增加产品边界、换算算法或“不猜价”等解释文案。
6. 刷新后失效 valuation issues、overview、accounts、holdings、quotes 和 fx-rates。
7. fixture 可提供结构化 issue；`real_local`/不支持的数据源不得伪造成功结果。

## 必测场景

1. USDT 只有 `USDT/USD + USD/CNY` 且两段 fresh：接口不返回问题，前端不得显示“缺少路径”。
2. BTC/USDT 有报价但无任何 USDT→CNY 路径：显示原始 BTC 数量和 `missing_fx_path`。
3. 无 BTC 报价：显示 `missing_quote`，不是 `missing_fx_path`。
4. 外币现金使用 stale FX：显示 `stale_fx`。
5. 问题列表为空：入口应与 overview 的 `quoteProblemCount=0` 一致并隐藏。
6. 列表加载失败：保留小入口，打开后显示短错误和重试，不回退到客户端猜测。

## 边界

- 只改 Flutter、Flutter 测试和前端 smoke；不改 Rust、OpenAPI、账本格式或部署。
- 独立分支交回 Codex 集成；提供 format、analyze、全量测试、真实 Rust 联调和视觉证据。
