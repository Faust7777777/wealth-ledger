// Wealth Ledger — 贷款条款纯校验与利率换算（可单测，不依赖 Widget）。
// 年利率界面按百分比输入，wire 发送十进制小数（3.65% → '0.0365'）；
// 换算为纯字符串移位，绝不经过 double。

/// 百分比字符串 → wire 小数：小数点左移两位（'3.65' → '0.0365'）。
/// 输入须先通过 [annualRatePercentError]。
String percentToWireRate(String percent) {
  final s = percent.trim();
  final dot = s.indexOf('.');
  final intPart = dot < 0 ? s : s.substring(0, dot);
  final fracPart = dot < 0 ? '' : s.substring(dot + 1);
  final digits = intPart + fracPart;
  final pointPos = intPart.length - 2;
  String result;
  if (pointPos <= 0) {
    result = '0.${'0' * (-pointPos)}$digits';
  } else if (pointPos >= digits.length) {
    result = digits;
  } else {
    result = '${digits.substring(0, pointPos)}.${digits.substring(pointPos)}';
  }
  return _normalize(result);
}

/// wire 小数 → 百分比字符串：小数点右移两位（'0.0365' → '3.65'）。
String wireRateToPercent(String wire) {
  final s = wire.trim();
  final dot = s.indexOf('.');
  final intPart = dot < 0 ? s : s.substring(0, dot);
  final fracPart = dot < 0 ? '' : s.substring(dot + 1);
  final paddedFrac = fracPart.padRight(2, '0');
  final digits = intPart + paddedFrac;
  final pointPos = intPart.length + 2;
  final result = pointPos >= digits.length
      ? digits
      : '${digits.substring(0, pointPos)}.${digits.substring(pointPos)}';
  return _normalize(result);
}

/// 去掉多余前导零与小数点尾零（'003.650' → '3.65'；'000.5' → '0.5'）。
String _normalize(String raw) {
  var s = raw;
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  s = s.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  return s.isEmpty ? '0' : s;
}

/// 年利率（百分比输入）：必填、正数、最多 6 位小数（换算后 wire ≤8 位）。
String? annualRatePercentError(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '请填写年利率';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '年利率格式不正确';
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 6) return '年利率最多 6 位小数';
  if (s.replaceAll(RegExp(r'[0.]'), '').isEmpty) return '年利率必须大于 0';
  return null;
}

/// 到期日必须晚于起息日（YYYY-MM-DD 字典序）。
String? maturityAfterStartError(String maturityDate, String interestStartDate) {
  if (maturityDate.compareTo(interestStartDate) <= 0) {
    return '到期日须晚于起息日';
  }
  return null;
}
