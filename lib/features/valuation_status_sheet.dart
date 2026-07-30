// Wealth Ledger — 估值状态面板（低强调入口点开的受限宽度说明）。
// 只罗列服务端读模型给出的事实：原始数量 + 缺失/较旧/缓存的估值依据；
// 前端不猜价格、不猜汇率、不做跨资产换算。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'quote_refresh_messages.dart';

/// 面板里的一行：某账户下某资产的原始数量与估值状态说明。
class ValuationIssueVm {
  const ValuationIssueVm({
    required this.accountName,
    required this.assetLabel,
    required this.quantity,
    required this.message,
  });
  final String accountName;
  final String assetLabel; // 符号或币种代码
  final DecimalString quantity;
  final String message;
}

String? _holdingIssue(HoldingVm h) => switch (h.quoteStatus) {
  QuoteStatus.stale => '报价较旧',
  QuoteStatus.offlineCached => '使用缓存报价',
  QuoteStatus.incomplete => '估值不完整',
  QuoteStatus.error => '报价获取失败',
  QuoteStatus.unpriceable => '缺少 ${h.symbol} → CNY 的估值路径',
  QuoteStatus.fresh => h.marketValue == null ? '暂未估值' : null,
};

/// 组合估值问题清单（可单测的纯函数）。
/// 持仓按 quoteStatus 判断；外币现金按是否存在到本位币的汇率及其状态判断。
List<ValuationIssueVm> composeValuationIssues({
  required List<AccountVm> accounts,
  required List<HoldingVm> holdings,
  required List<FxRateVm> fxRates,
  String baseCurrency = 'CNY',
}) {
  final nameById = {for (final a in accounts) a.id: a.displayName};
  final issues = <ValuationIssueVm>[];

  for (final h in holdings) {
    final message = _holdingIssue(h);
    if (message == null) continue;
    issues.add(
      ValuationIssueVm(
        accountName: nameById[h.accountId] ?? h.accountId,
        assetLabel: h.symbol.isEmpty ? h.displayName : h.symbol,
        quantity: h.quantity,
        message: message,
      ),
    );
  }

  FxRateVm? rateFor(String currency) {
    for (final r in fxRates) {
      if ((r.baseCurrency == currency && r.quoteCurrency == baseCurrency) ||
          (r.baseCurrency == baseCurrency && r.quoteCurrency == currency)) {
        return r;
      }
    }
    return null;
  }

  for (final a in accounts) {
    for (final entry in a.cashBalances.entries) {
      final currency = entry.key;
      if (currency == baseCurrency) continue;
      if (decimalSign(entry.value) == 0) continue;
      final rate = rateFor(currency);
      final message = rate == null
          ? '缺少 $currency → $baseCurrency 的估值路径'
          : switch (rate.status) {
              QuoteStatus.stale => '汇率较旧',
              QuoteStatus.offlineCached => '使用缓存汇率',
              QuoteStatus.error => '汇率获取失败',
              QuoteStatus.incomplete => '估值不完整',
              QuoteStatus.unpriceable => '缺少 $currency → $baseCurrency 的估值路径',
              QuoteStatus.fresh => '',
            };
      if (message.isEmpty) continue;
      issues.add(
        ValuationIssueVm(
          accountName: a.displayName,
          assetLabel: currency,
          quantity: entry.value,
          message: message,
        ),
      );
    }
  }
  return issues;
}

/// 低强调「详情」入口的稳定 Key。
const kValuationErrorDetailsKey = ValueKey('valuation_error_details');

Future<void> showValuationStatusDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (_) => const ValuationStatusDialog(),
    );

class ValuationStatusDialog extends ConsumerStatefulWidget {
  const ValuationStatusDialog({super.key});

  @override
  ConsumerState<ValuationStatusDialog> createState() =>
      _ValuationStatusDialogState();
}

class _ValuationStatusDialogState extends ConsumerState<ValuationStatusDialog> {
  bool _busy = false;

  /// 上一次刷新的失败项：只在低强调「详情」里展开，主界面不出现英文。
  List<QuoteRefreshErrorVm> _lastErrors = const [];
  bool _showDetails = false;

  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(quoteRepositoryProvider)
          .refreshQuotes(mode: 'manual');
      ref.invalidate(fxRatesProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(holdingsProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(allocationProvider);
      if (mounted) {
        setState(() {
          _lastErrors = result.errorDetails;
          if (result.errorDetails.isEmpty) _showDetails = false;
        });
      }
      if (result.hasProblems) {
        // 刷新有问题：面板保持打开，列表会随新数据重算。
        messenger.showSnackBar(
          SnackBar(content: Text(quoteRefreshResultText(result))),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(kQuoteRefreshFailureText)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      240.0,
      480.0,
    );
    final accountsAsync = ref.watch(accountsProvider);
    final holdingsAsync = ref.watch(holdingsProvider);
    final fxAsync = ref.watch(fxRatesProvider);

    Widget body;
    if (accountsAsync.isLoading ||
        holdingsAsync.isLoading ||
        fxAsync.isLoading) {
      body = const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (accountsAsync.hasError ||
        holdingsAsync.hasError ||
        fxAsync.hasError) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状态加载失败，请重试。'),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              onPressed: () {
                ref.invalidate(accountsProvider);
                ref.invalidate(holdingsProvider);
                ref.invalidate(fxRatesProvider);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    } else {
      final issues = composeValuationIssues(
        accounts: accountsAsync.value ?? const [],
        holdings: holdingsAsync.value ?? const [],
        fxRates: fxAsync.value ?? const [],
      );
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (issues.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.base),
              child: Text('当前所有资产都已计入总值。'),
            )
          else
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.base,
                  vertical: AppSpacing.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${issue.accountName} · ${issue.assetLabel} '
                      '${formatDecimalThousands(issue.quantity)}',
                      style: AppType.bodyStrong,
                    ),
                    Text(issue.message, style: AppType.caption),
                  ],
                ),
              ),
          if (_lastErrors.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: kValuationErrorDetailsKey,
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                  child: Text(_showDetails ? '收起详情' : '详情'),
                ),
              ),
            ),
            if (_showDetails)
              for (final error in _lastErrors)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.xxs,
                  ),
                  child: Text(
                    quoteRefreshErrorDetailText(error),
                    style: AppType.caption,
                  ),
                ),
          ],
        ],
      );
    }

    return AlertDialog(
      title: const Text('部分资产暂未计入总值'),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(child: body),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _busy ? null : _refresh,
          child: Text(_busy ? '刷新中…' : '刷新估值'),
        ),
      ],
    );
  }
}
