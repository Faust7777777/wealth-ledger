# 非内置 crypto 的 USDT 计价修复

## 问题

任意 crypto 登记与 OKX 公共报价已经存在，但新标的此前会继承账户默认币种。账户以 CNY、USD 或 BTC 展示时，SOL 可能被登记为 SOL/CNY、SOL/USD 或 SOL/BTC，而结构化 OKX provider 当前只查询 SOL-USDT，导致标的登记成功后仍无法报价。

## 修复

- BTC、ETH、USDT 保持现有行为，可按账户默认币种使用 CoinGecko 直接或交叉报价。
- 其他新登记 crypto 一律以 USDT 作为 `Instrument.quoteCurrency`。
- ensure 自动把 USDT 加入账户 `supportedCurrencies`，但不改变账户 `defaultCurrency`。
- 原始 holding quantity 始终保留；账户汇总继续通过 `crypto/USDT → USDT/USD → USD/CNY` 等最多三跳路径折算。
- 既有已登记标的不被静默改写 quoteCurrency，避免破坏历史报价或 movement 引用。

## 回归

- CNY 默认的 exchange 登记 ETH 与 SOL：ETH 仍可用 CNY，SOL 必须是 USDT，账户支持币种成为 CNY/BTC/USDT 的真实并集。
- CNY 默认的 exchange 登记 SOL、确认持仓后，在 SOL/USDT、USDT/USD、USD/CNY 三段数据齐备时正确汇总为 CNY；缺 Quote 与缺 FX path 分别保持结构化问题状态。
- 待全量门禁、推送与部署后补生产结果。
