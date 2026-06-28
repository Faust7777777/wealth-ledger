# QUOTE_RATE_CONTRACT_V1

状态：草案。  
用途：定义行情、汇率、历史价格、刷新、过期与 UI 估值质量的共同口径。  
非用途：不指定最终数据供应商，不要求第一阶段前端发真实网络请求。

## 0. 范围

MVP 需要覆盖：

- 汇率：CNY / USD / HKD / USDT 等。
- 加密资产：BTC / ETH / USDT 等。
- 美股：例如 AAPL / NVDA 等。
- 后续扩展：基金、港股、链上地址只读查询。

刷新方式：

- 手动刷新。
- 启动刷新。
- 定时刷新。

## 1. Quote

```ts
Quote {
  id: ID;
  instrumentId: ID;
  price: DecimalString;
  currency: CurrencyCode;
  asOf: ISODateTime;
  expiresAt?: ISODateTime;
  source: string;
  sourceUrl?: string;
  status: QuoteStatus;
}
```

## 2. FXRate

```ts
FXRate {
  id: ID;
  baseCurrency: CurrencyCode;
  quoteCurrency: CurrencyCode;
  rate: DecimalString;
  asOf: ISODateTime;
  expiresAt?: ISODateTime;
  source: string;
  sourceUrl?: string;
  status: QuoteStatus;
}
```

## 3. QuoteStatus

```ts
QuoteStatus =
  | "fresh"
  | "stale"
  | "offline_cached"
  | "incomplete"
  | "unpriceable"
  | "error";
```

语义：

- `fresh`：在配置 TTL 内。
- `stale`：有缓存，但超过 TTL。
- `offline_cached`：断网时使用上次缓存。
- `incomplete`：部分标的或汇率缺失。
- `unpriceable`：无法估值，不得按 0 计入。
- `error`：刷新失败，保留错误原因供 UI 展示。

## 4. 刷新请求

```ts
QuoteRefreshRequest {
  mode: "manual" | "startup" | "scheduled";
  requestedAt: ISODateTime;
  instruments: ID[];
  currencyPairs: CurrencyPair[];
  quotes?: Quote[];     // provider / 手动确认 / AI 候选确认后的写入载荷
  fxRates?: FXRate[];   // provider / 手动确认 / AI 候选确认后的写入载荷
}

CurrencyPair {
  baseCurrency: CurrencyCode;
  quoteCurrency: CurrencyCode;
}
```

```ts
QuoteRefreshResult {
  status: "success" | "partial_success" | "failed" | "offline";
  quotes: Quote[];
  fxRates: FXRate[];
  errors: QuoteRefreshError[];
  completedAt: ISODateTime;
}

QuoteRefreshError {
  targetType: "instrument" | "fx_pair";
  targetId?: ID;
  message: string;
  retryable: boolean;
}
```

规则：

- 手动刷新失败时必须给用户可见反馈。
- 启动刷新失败不阻塞 App 使用。
- 定时刷新失败不弹强干扰错误，进入待处理/状态区。
- 如果当前环境没有真实 provider，`quotes` / `fxRates` 可作为手动或外部 provider 已确认结果写入缓存；缺省时不得伪造价格，只能返回 `offline`/`failed` 并继续使用缓存。
- Rust local server 可用 Yahoo provider 作为第一档实现：只对 `Instrument.symbol` 存在，或 `instrumentId` 本身可安全解释为 ticker 的标的自动刷新；内部 ID（如 `inst_*`）缺少 symbol 时必须返回错误并继续使用缓存。
- FX provider 可按 `currencyPairs` 或账本中的非本位币现金自动推导 Yahoo pair（如 `USD/CNY` → `USDCNY=X`）。
- 本地开发可用 `FINWEALTH_QUOTE_PROVIDER=none` 禁用联网 provider，只保留手动/外部 payload 写入与缓存读取。

## 5. TTL 初始建议

TTL 是配置，不是写死业务真理。

```text
crypto: 5 分钟
us_equity: 15 分钟
fx: 24 小时
fund: 24 小时
manual_balance: 用户手动更新时间
```

规则：

- TTL 过期后 UI 显示 stale。
- stale 估值仍可参与净值，但质量为 `estimated`。
- unpriceable 不参与净值。

## 6. 净值估值质量

```ts
QuoteStatusSummary {
  freshCount: number;
  staleCount: number;
  offlineCachedCount: number;
  unpriceableCount: number;
  errorCount: number;
}
```

映射：

- 全 fresh / exact → `ValueQuality.exact`
- 有 stale / offline_cached → `ValueQuality.estimated`
- 有缺失但仍可部分估值 → `ValueQuality.incomplete`
- 关键资产 unpriceable → `ValueQuality.incomplete` 或 `unpriceable`
- 数据矛盾 → `ValueQuality.anomaly`

## 7. 首页展示规则

- exact：显示净值，不加 `≈`。
- estimated：显示 `≈`，并展示 as-of / 过期数量。
- incomplete：显示 `≈` 或“不完整”，待处理区显示报价问题。
- unpriceable：对应资产显示 `—`，待处理区显示无法估值。
- offline_cached：顶栏或状态区显示离线缓存。

首页涨跌：

- 默认显示“较上次快照”。
- 只有全 fresh 时才可显示“今日涨跌”。

## 8. 历史价格

MVP 口径：

- 不做很久以前的历史补录。
- 以今天作为基线。
- 历史价格最多固定近一年，用于曲线/走势/估值回看。

```ts
HistoricalPricePoint {
  instrumentId: ID;
  price: DecimalString;
  currency: CurrencyCode;
  date: ISODate;
  source: string;
  sourceUrl?: string;
}
```

规则：

- 接口优先。
- 接口不能覆盖时，AI 可以提出来源链接和候选数据，用户确认后才采用。
- AI 搜索结果不得静默写入价格库。
