// Wealth Ledger — 账户类型的展示文案 / 分组 / 占位图标 + 负债金额展示语义。
// 用户界面不暴露 wire enum、balanceMode 或账本符号约定。
// TODO(icons): 占位 Material 图标；最终换 §5.1 自定义图标集（禁 emoji）。
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/view_models.dart';

String accountTypeLabel(AccountType t) => switch (t) {
  AccountType.bank => '银行账户',
  AccountType.brokerage => '证券账户',
  AccountType.exchange => '数字资产交易所',
  AccountType.wallet => '数字资产钱包',
  AccountType.platformWallet => '支付平台余额',
  AccountType.virtualCard => '虚拟卡/预付卡',
  AccountType.socialSecurity => '社保/养老金',
  AccountType.creditCard => '信用卡',
  AccountType.loan => '贷款',
  AccountType.cash => '现金',
  AccountType.other => '其他账户',
};

/// 每个类型一条简短示例，帮助用户在选择器里判断归属。
String accountTypeExample(AccountType t) => switch (t) {
  AccountType.bank => '储蓄卡、活期账户',
  AccountType.brokerage => '股票、基金账户',
  AccountType.exchange => '加密货币交易所',
  AccountType.wallet => '链上钱包',
  AccountType.platformWallet => '支付宝、微信支付',
  AccountType.virtualCard => '网络虚拟卡',
  AccountType.socialSecurity => '社保、养老金账户',
  AccountType.creditCard => '信用卡当前欠款',
  AccountType.loan => '房贷、车贷、助学贷款',
  AccountType.cash => '随身现金',
  AccountType.other => '无法归类的账户',
};

typedef AccountTypeGroup = ({String label, List<AccountType> types});

/// 类型选择器分组（覆盖全部 11 个 enum，wire 值不变）。
const List<AccountTypeGroup> kAccountTypeGroups = [
  (
    label: '日常资金',
    types: [
      AccountType.bank,
      AccountType.cash,
      AccountType.platformWallet,
      AccountType.virtualCard,
    ],
  ),
  (
    label: '投资资产',
    types: [
      AccountType.brokerage,
      AccountType.exchange,
      AccountType.wallet,
      AccountType.socialSecurity,
    ],
  ),
  (label: '负债', types: [AccountType.creditCard, AccountType.loan]),
  (label: '其他', types: [AccountType.other]),
];

/// 余额模式是内部概念，由账户类型自动派生，普通表单不暴露。
String defaultBalanceModeFor(AccountType t) => switch (t) {
  AccountType.creditCard || AccountType.loan => 'liability',
  AccountType.brokerage ||
  AccountType.exchange ||
  AccountType.wallet ||
  AccountType.socialSecurity => 'holdings',
  AccountType.bank ||
  AccountType.cash ||
  AccountType.platformWallet ||
  AccountType.virtualCard ||
  AccountType.other => 'cash_balance',
};

/// 负债类型（欠款以正数录入，账本内为负）。
bool isLiabilityAccountType(AccountType t) =>
    t == AccountType.creditCard || t == AccountType.loan;

// ———— 负债金额展示语义 ————
// 账本内欠款为负、还款向零靠拢；界面绝不要求用户理解该符号约定。
// 只在展示层转换，不修改 API 原始金额、不在 mapping 层抹符号。

/// 负债语义标签：<0 当前欠款；=0 已还清；>0 溢缴款（不得展示成欠款）。
String liabilityAmountLabel(DecimalString raw) => switch (decimalSign(raw)) {
  -1 => '当前欠款',
  0 => '已还清',
  _ => '溢缴款',
};

/// 负债金额文本：一律显示绝对值（不出现负号），估值质量前缀沿用 formatValued。
String liabilityValuedText(ValuedMoney v) => formatValued(
  ValuedMoney(
    amount: absDecimal(v.amount),
    currency: v.currency,
    asOf: v.asOf,
    quality: v.quality,
  ),
);

/// 负债单币种余额文本（账户详情的分币种行）：绝对值，不出现负号。
String liabilityBalanceText(DecimalString raw, CurrencyCode currency) =>
    formatMoney(Money(amount: absDecimal(raw), currency: currency));

IconData accountTypeIcon(AccountType t) => switch (t) {
  AccountType.bank => Icons.account_balance,
  AccountType.brokerage => Icons.trending_up,
  AccountType.exchange => Icons.currency_bitcoin,
  AccountType.wallet => Icons.account_balance_wallet,
  AccountType.platformWallet => Icons.account_balance_wallet_outlined,
  AccountType.virtualCard => Icons.credit_card,
  AccountType.socialSecurity => Icons.health_and_safety_outlined,
  AccountType.creditCard => Icons.credit_card,
  AccountType.loan => Icons.request_quote_outlined,
  AccountType.cash => Icons.payments_outlined,
  AccountType.other => Icons.category_outlined,
};
