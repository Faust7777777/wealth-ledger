// Wealth Ledger — 账户类型的展示文案 / 占位图标。
// TODO(icons): 占位 Material 图标；最终换 §5.1 自定义图标集（禁 emoji）。
import 'package:flutter/material.dart';
import '../data/view_models.dart';

String accountTypeLabel(AccountType t) => switch (t) {
      AccountType.bank => '银行',
      AccountType.brokerage => '券商',
      AccountType.exchange => '交易所',
      AccountType.wallet => '钱包',
      AccountType.platformWallet => '平台余额',
      AccountType.virtualCard => '虚拟卡',
      AccountType.socialSecurity => '社保',
      AccountType.creditCard => '信用卡',
      AccountType.loan => '贷款',
      AccountType.cash => '现金',
      AccountType.other => '其他',
    };

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
