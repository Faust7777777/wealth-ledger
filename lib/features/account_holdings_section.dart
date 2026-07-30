// Wealth Ledger — 账户的多资产持仓视图。
// 原始数量是主信息；缺报价的资产照常显示数量，不按 0 混进合计。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'valuation_status_sheet.dart';

/// 交易所、钱包以及按持仓记账的账户都按多资产展示。
bool accountIsMultiAsset(AccountVm account) {
  if (account.isLiability) return false;
  return account.accountType == AccountType.exchange ||
      account.accountType == AccountType.wallet ||
      account.balanceMode == 'holdings' ||
      account.balanceMode == 'mixed';
}

/// 账户合计只认账户折算单位的价值：服务端的 accountMarketValue。
/// 本位币 marketValue 属于组合/净资产口径，不能与账户默认单位混算。
ValuedMoney? holdingAccountValue(HoldingVm holding) {
  final value = holding.accountMarketValue;
  if (value == null) return null;
  if (value.quality == ValueQuality.unpriceable ||
      value.quality == ValueQuality.anomaly) {
    return null;
  }
  return value;
}

/// 一项持仓在账户口径下是否缺少可用折算价值。
bool holdingLacksValue(HoldingVm holding) =>
    holdingAccountValue(holding) == null;

/// 账户持仓合计：只累加能折算且币种一致的部分，缺报价的项被排除而不是当 0。
class AccountHoldingsTotal {
  const AccountHoldingsTotal({
    required this.currency,
    required this.amount,
    required this.pricedCount,
    required this.missingQuoteCount,
    required this.otherCurrencyCount,
  });
  final CurrencyCode currency;
  final DecimalString amount;
  final int pricedCount;

  /// 没有任何一项成功计价时不显示 0：合计只能是 —。
  bool get hasAmount => pricedCount > 0;

  /// 缺报价因而无法折算的项数。
  final int missingQuoteCount;

  /// 有价值但币种与账户折算币种不一致、因此没有并入合计的项数。
  final int otherCurrencyCount;

  /// 未计入合计的项数合计（界面据此给低强调入口）。
  int get missingCount => missingQuoteCount + otherCurrencyCount;

  /// 入口文案：全部是缺报价才说"待补报价"，否则只说未计入合计。
  String? get excludedLabel {
    if (missingCount == 0) return null;
    return otherCurrencyCount == 0
        ? '$missingQuoteCount 项待补报价'
        : '$missingCount 项未计入合计';
  }
}

AccountHoldingsTotal accountHoldingsTotal(
  AccountVm account,
  List<HoldingVm> holdings,
) {
  final currency = account.defaultCurrency;
  var total = BigInt.zero;
  var scale = 0;
  var priced = 0;
  var missingQuote = 0;
  var otherCurrency = 0;
  for (final h in holdings) {
    final value = holdingAccountValue(h);
    if (value == null) {
      missingQuote += 1;
      continue;
    }
    if (value.currency != currency) {
      otherCurrency += 1;
      continue;
    }
    final (units, valueScale) = _decimalParts(value.amount);
    if (units == null) {
      missingQuote += 1;
      continue;
    }
    if (valueScale > scale) {
      total *= BigInt.from(10).pow(valueScale - scale);
      scale = valueScale;
    }
    total += units * BigInt.from(10).pow(scale - valueScale);
    priced += 1;
  }
  return AccountHoldingsTotal(
    currency: currency,
    amount: _decimalString(total, scale),
    pricedCount: priced,
    missingQuoteCount: missingQuote,
    otherCurrencyCount: otherCurrency,
  );
}

/// 十进制字符串 → (整数单位, 小数位数)；非法输入返回 (null, 0)。
(BigInt?, int) _decimalParts(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (null, 0);
  final dot = text.indexOf('.');
  final digits = dot < 0 ? text : text.replaceFirst('.', '');
  final units = BigInt.tryParse(digits);
  if (units == null) return (null, 0);
  return (units, dot < 0 ? 0 : text.length - dot - 1);
}

String _decimalString(BigInt units, int scale) {
  if (scale == 0) return units.toString();
  final negative = units.isNegative;
  var digits = units.abs().toString().padLeft(scale + 1, '0');
  final head = digits.substring(0, digits.length - scale);
  final tail = digits.substring(digits.length - scale);
  final text = '$head.$tail';
  return negative ? '-$text' : text;
}

/// 报价状态的用户可见说明；正常报价不加任何标注。
String? holdingQuoteStatusText(QuoteStatus status) => switch (status) {
  QuoteStatus.fresh => null,
  QuoteStatus.stale => '报价偏旧',
  QuoteStatus.offlineCached => '离线缓存',
  QuoteStatus.incomplete => '报价不完整',
  QuoteStatus.unpriceable => '暂无报价',
  QuoteStatus.error => '报价获取失败',
};

/// 账户持仓区：合计 + 逐项数量/报价单位/折算价值/报价状态。
class AccountHoldingsSection extends ConsumerWidget {
  const AccountHoldingsSection({
    super.key,
    required this.account,
    required this.holdings,
    this.onUpdateHoldings,
    this.onAddAsset,
    this.onTapHolding,
  });

  final AccountVm account;
  final List<HoldingVm> holdings;
  final VoidCallback? onUpdateHoldings;
  final VoidCallback? onAddAsset;
  final void Function(HoldingVm holding)? onTapHolding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = accountHoldingsTotal(account, holdings);
    final instruments =
        ref.watch(instrumentsProvider).asData?.value ?? const <InstrumentVm>[];
    final quoteUnitById = {for (final i in instruments) i.id: i.quoteCurrency};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: '持仓',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onUpdateHoldings != null)
                TextButton(
                  key: kAccountUpdateHoldingsKey,
                  onPressed: onUpdateHoldings,
                  child: const Text('更新持仓'),
                ),
              if (onAddAsset != null)
                TextButton.icon(
                  onPressed: onAddAsset,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加资产'),
                ),
            ],
          ),
        ),
        if (holdings.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '合计（${total.currency}）',
                  style: AppType.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                total.hasAmount
                    ? formatMoney(
                        Money(amount: total.amount, currency: total.currency),
                      )
                    : '—',
                style: AppType.moneyRow,
              ),
            ],
          ),
          if (total.excludedLabel case final label?)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: kAccountMissingQuotesKey,
                onPressed: () => showValuationStatusDialog(context),
                child: Text(label),
              ),
            ),
        ],
        if (holdings.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text('暂无持仓', style: AppType.caption),
          )
        else
          for (final h in holdings)
            AccountHoldingRow(
              key: ValueKey('account_holding_${h.id}'),
              holding: h,
              quoteUnit: quoteUnitById[h.instrumentId],
              onTap: onTapHolding == null ? null : () => onTapHolding!(h),
            ),
      ],
    );
  }
}

/// 「更新持仓」与「待补报价」入口的稳定 Key。
const kAccountUpdateHoldingsKey = ValueKey('account_update_holdings');
const kAccountMissingQuotesKey = ValueKey('account_missing_quotes');

class AccountHoldingRow extends StatelessWidget {
  const AccountHoldingRow({
    super.key,
    required this.holding,
    this.quoteUnit,
    this.onTap,
  });

  final HoldingVm holding;
  final CurrencyCode? quoteUnit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 行内折算价值与合计同口径：账户折算单位。
    final value = holdingAccountValue(holding) ?? holding.accountMarketValue;
    final statusText = holdingQuoteStatusText(holding.quoteStatus);
    final unit = quoteUnit;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: LeadingAvatar.mono(holding.symbol),
      title: Text(
        '${holding.displayName} · ${holding.symbol}',
        style: AppType.bodyStrong,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: statusText == null
          ? null
          : Text(statusText, style: AppType.caption),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 原始数量 + 报价单位：数量永远可见，不因缺报价而消失。
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatDecimalThousands(holding.quantity),
                style: AppType.moneyRow,
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit, style: AppType.caption),
              ],
            ],
          ),
          Text(
            value == null ? '暂无估值' : formatValued(value),
            style: AppType.caption,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
