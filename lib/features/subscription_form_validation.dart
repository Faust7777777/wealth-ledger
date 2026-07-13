// Wealth Ledger — 订阅表单纯校验（可单测，不依赖 Widget）。
// 客户端只做可用性校验，服务端仍是权威。金额一律字符串处理，绝不经 double。

/// 金额：必填、正数、最多 8 位小数。返回错误文案或 null。
String? amountError(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '请填写金额';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '金额格式不正确';
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 8) return '金额最多 8 位小数';
  // 正数：去掉所有 0 和小数点后仍有数字即 > 0。
  if (s.replaceAll(RegExp(r'[0.]'), '').isEmpty) return '金额必须大于 0';
  return null;
}

/// 正整数（≥1），如计费 interval、duration count。
String? positiveIntError(String raw, String field) {
  final n = int.tryParse(raw.trim());
  if (n == null || n < 1) return '$field必须为正整数';
  return null;
}

/// 非负整数（≥0），如提前提醒天数。
String? nonNegativeIntError(String raw, String field) {
  final n = int.tryParse(raw.trim());
  if (n == null || n < 0) return '$field必须为非负整数';
  return null;
}

/// 结束日期必须晚于开始日期（YYYY-MM-DD 字典序比较即可）。
String? endDateAfterStartError(String? endDate, String startDate) {
  if (endDate == null || endDate.isEmpty) return '请选择结束日期';
  if (endDate.compareTo(startDate) <= 0) return '结束日期须晚于开始日期';
  return null;
}
