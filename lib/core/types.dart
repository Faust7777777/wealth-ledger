// Wealth Ledger — shared value types (frontend_contract_v1 §1).
// TODO(DATA_SCHEMA_V1): 正式类型/精度由 Codex 数据契约冻结；此处为前端临时基线。
// 约束：金额/数量/价格一律 DecimalString，前端层不得用 double 参与金额运算。

typedef Id = String; // UUID/ULID，前端不关心算法
typedef IsoDate = String; // YYYY-MM-DD
typedef IsoDateTime = String; // ISO 8601 with timezone
typedef DecimalString = String; // 金额/数量/价格
typedef CurrencyCode = String; // CNY/USD/HKD/USDT/BTC/ETH...

/// 估值质量（frontend_contract_v1 §1）。
enum ValueQuality { exact, estimated, incomplete, unpriceable, anomaly }

/// 报价/汇率状态（frontend_contract_v1 §1/§10）。
enum QuoteStatus { fresh, stale, offlineCached, incomplete, unpriceable, error }

/// 金额（DecimalString + 币种）。
class Money {
  const Money({required this.amount, required this.currency});
  final DecimalString amount;
  final CurrencyCode currency;
}

/// 带时间口径与质量的金额。
class ValuedMoney {
  const ValuedMoney({
    required this.amount,
    required this.currency,
    required this.asOf,
    required this.quality,
  });
  final DecimalString amount;
  final CurrencyCode currency;
  final IsoDateTime asOf;
  final ValueQuality quality;
}
