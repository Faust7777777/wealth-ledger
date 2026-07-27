// Wealth Ledger — 固定收益条款纯校验（可单测，不依赖 Widget）。
// 年利率的百分比 ↔ wire 小数换算复用贷款条款那一份实现（纯字符串移位，
// 绝不经过 double），避免出现第二套换算规则。
import '../core/types.dart';
import '../data/view_models.dart';

export 'liability_terms_validation.dart'
    show
        annualRatePercentError,
        maturityAfterStartError,
        percentToWireRate,
        wireRateToPercent;

/// 单利必须 none；复利必须选择月/季/年。
String? compoundingFrequencyError(
  YieldInterestMethod method,
  YieldCompoundingFrequency frequency,
) {
  if (method == YieldInterestMethod.simple &&
      frequency != YieldCompoundingFrequency.none) {
    return '单利不设复利周期';
  }
  if (method == YieldInterestMethod.compound &&
      frequency == YieldCompoundingFrequency.none) {
    return '请选择复利周期';
  }
  return null;
}

/// 计息截止日期必须晚于上次应计日期（YYYY-MM-DD 字典序）。
String? throughDateAfterAccruedError(
  IsoDate throughDate,
  IsoDate lastAccruedThrough,
) => throughDate.compareTo(lastAccruedThrough) <= 0
    ? '计息截止日期须晚于上次应计日期 $lastAccruedThrough'
    : null;
