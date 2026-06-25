// Wealth Ledger — string-based money formatting.
// 约束：金额一律 DecimalString，格式化全程字符串处理，绝不经过 double。
import 'types.dart';

/// 给十进制字符串的整数部分加千分位（不经过 double）。
String formatDecimalThousands(DecimalString value) {
  var s = value.trim();
  var sign = '';
  if (s.startsWith('-')) {
    sign = '-';
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  final dot = s.indexOf('.');
  final intPart = dot >= 0 ? s.substring(0, dot) : s;
  final fracPart = dot >= 0 ? s.substring(dot) : '';
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '$sign$buf$fracPart';
}

const Map<String, String> _symbols = {'CNY': '¥', 'USD': r'$', 'HKD': r'HK$'};

String formatMoney(Money m, {bool withCode = false}) {
  final sym = _symbols[m.currency];
  final n = formatDecimalThousands(m.amount);
  if (sym != null) return '$sym$n';
  return withCode ? '$n ${m.currency}' : n;
}

/// 估值金额展示：estimated/incomplete → 前缀 ≈；unpriceable/anomaly → —。
String formatValued(ValuedMoney v) {
  switch (v.quality) {
    case ValueQuality.unpriceable:
    case ValueQuality.anomaly:
      return '—';
    case ValueQuality.estimated:
    case ValueQuality.incomplete:
      return '≈ ${formatMoney(Money(amount: v.amount, currency: v.currency))}';
    case ValueQuality.exact:
      return formatMoney(Money(amount: v.amount, currency: v.currency));
  }
}
