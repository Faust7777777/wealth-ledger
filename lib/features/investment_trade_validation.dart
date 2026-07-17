// Wealth Ledger — 投资成交表单纯校验（可单测，不依赖 Widget）。
// 金额与数量一律十进制定点字符串，绝不经过 double；服务端仍是权威。
import '../core/format.dart';

/// 必填正数（数量 / 成交价款 / 毛回款）：必填、纯数字、>0、≤8 位小数。
String? requiredDecimalError(String raw, String field) {
  final s = raw.trim();
  if (s.isEmpty) return '请填写$field';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '$field格式不正确';
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 8) return '$field最多 8 位小数';
  if (decimalSign(s) <= 0) return '$field必须大于 0';
  return null;
}

/// 可选非负（手续费 / 税费）：空视为不填；填了须为非负、≤8 位小数。
/// 0 合法，但调用方不应为 0 生成费用腿。
String? optionalNonNegativeError(String raw, String field) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '$field格式不正确';
  final dot = s.indexOf('.');
  if (dot >= 0 && s.length - dot - 1 > 8) return '$field最多 8 位小数';
  return null;
}

/// 空串安全的十进制取值：空 → '0'（仅用于合计/比较，不用于发请求）。
String _orZero(String raw) => raw.trim().isEmpty ? '0' : raw.trim();

/// 卖出：手续费 + 税费不得超过毛回款（同币种字符串精确比较）。
String? sellFeeTaxError({
  required String grossProceeds,
  required String fee,
  required String tax,
}) {
  final total = addDecimal(_orZero(fee), _orZero(tax));
  if (compareDecimal(total, _orZero(grossProceeds)) > 0) {
    return '手续费与税费合计不能超过卖出毛回款';
  }
  return null;
}

/// 卖出：数量不得超过当前持仓数量。
String? sellQuantityError({
  required String quantity,
  required String heldQuantity,
}) {
  if (compareDecimal(_orZero(quantity), _orZero(heldQuantity)) > 0) {
    return '卖出数量不能超过当前持仓（$heldQuantity）';
  }
  return null;
}

/// 现金合计支出（买入 = 价款 + 手续费 + 税费）；同币种字符串精确相加。
String buyTotalCashOut({
  required String principal,
  required String fee,
  required String tax,
}) => addDecimal(addDecimal(_orZero(principal), _orZero(fee)), _orZero(tax));

/// 现金净入账（卖出 = 毛回款 − 手续费 − 税费）。
String sellNetCashIn({
  required String gross,
  required String fee,
  required String tax,
}) => subtractDecimal(
  subtractDecimal(_orZero(gross), _orZero(fee)),
  _orZero(tax),
);
