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

/// 精确十进制相减(a - b)，走 BigInt 缩放整数，绝不经过 double。保留两者中较多的小数位。
DecimalString subtractDecimal(DecimalString a, DecimalString b) {
  (BigInt, int) parse(String s) {
    var t = s.trim();
    var neg = false;
    if (t.startsWith('-')) {
      neg = true;
      t = t.substring(1);
    } else if (t.startsWith('+')) {
      t = t.substring(1);
    }
    final dot = t.indexOf('.');
    final frac = dot < 0 ? 0 : t.length - dot - 1;
    final digits = t.replaceFirst('.', '');
    var v = BigInt.parse(digits.isEmpty ? '0' : digits);
    if (neg) v = -v;
    return (v, frac);
  }

  final pa = parse(a);
  final pb = parse(b);
  final scale = pa.$2 > pb.$2 ? pa.$2 : pb.$2;
  final av = pa.$1 * BigInt.from(10).pow(scale - pa.$2);
  final bv = pb.$1 * BigInt.from(10).pow(scale - pb.$2);
  var diff = av - bv;
  final neg = diff.isNegative;
  if (neg) diff = -diff;
  var s = diff.toString();
  if (scale > 0) {
    if (s.length <= scale) s = s.padLeft(scale + 1, '0');
    final cut = s.length - scale;
    s = '${s.substring(0, cut)}.${s.substring(cut)}';
  }
  return neg ? '-$s' : s;
}
