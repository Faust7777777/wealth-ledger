// Wealth Ledger — 账户表单可单测纯校验。
// 金额一律十进制定点字符串（与服务端一致，最多 8 位小数），绝不经过 double。

/// 期初余额 / 当前欠款输入校验：可留空；非空须为非负十进制、小数 ≤8 位。
/// （负债欠款以正数录入，由表单层转为账本负数。）
String? openingAmountError(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) {
    return '请输入非负金额（如 100 或 100.00）';
  }
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 8) return '小数最多 8 位';
  return null;
}

/// 持仓校准目标数量：必填、非负（0 = 清零）、≤8 位小数，纯字符串不经 double。
String? targetQuantityError(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '请填写目标数量';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '数量格式不正确';
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 8) return '数量最多 8 位小数';
  return null;
}

/// 归一化期初金额：空串、非法或纯零（0、0.00…）→ null。
/// null 表示不发送期初余额（openingBalances: []）；该行为固定并有测试。
String? normalizedOpeningAmount(String raw) {
  final s = raw.trim();
  if (s.isEmpty || openingAmountError(s) != null) return null;
  final hasNonZeroDigit = s.replaceAll(RegExp(r'[0.]'), '').isNotEmpty;
  return hasNonZeroDigit ? s : null;
}
