# 2026-07-18 公共报价 Provider 实测回执

执行分支：`feat/subscription-sync-integration`

## 结论

默认仍为 `FINWEALTH_QUOTE_PROVIDER=none`。新增显式 `public` provider：

- CoinGecko：BTC、ETH、USDT 最新价格；
- Frankfurter/ECB：传统法币汇率；
- Yahoo：继续保留股票、传统行情和历史价格，但当前本机出口实测受到 Yahoo HTTP 429 限制。

未知加密标的、缺字段、非正价格、超过账本精度且无法规范化的数据都会逐项失败，不生成价格。

## 临时账本真实探针

探针只使用新建临时空账本，未读取生产或个人账本。流程：

1. 新建 OKX holdings 账户；
2. 新建 `BTC-USDT` 标的；
3. 通过持仓调整候选确认 `0.0001 BTC`；
4. 显式配置 `FINWEALTH_QUOTE_PROVIDER=public`；
5. 调用 `POST /v1/quotes/refresh`；
6. 读取 holdings 与 `GET /v1/portfolio/valuation-issues`。

实际结果：

```text
refresh status: success
quotes: 1
fxRates: 2
errors: 0
quote source: coingecko
USDT/USD source: coingecko
USD/CNY source: frankfurter_ecb
holding quantity: 0.0001
holding market value: 43.4180205 CNY
holding quote status: fresh
valuation issues: 0
```

探针结束后服务进程和临时目录均已删除。

## 精度修复

首次 public 探针成功取得两段 FX，但 BTC/USDT 除法结果超过本地账本最多 8 位小数，被账本校验拒绝。修复在 provider 边界把外部浮点值规范化为最多 8 位 decimal string；账本核心精度没有放宽。低于账本最小精度的正数仍拒绝。

## 部署边界

- `public` 和 `yahoo` 都必须显式开启；默认不发送 ticker 或货币对。
- `public` 当前不提供历史价格；历史价格端点在 public 配置下返回明确的不支持错误。
- 上线切换 provider 前仍需备份生产账本、验证生产配置并做一次生产只读刷新验收。
