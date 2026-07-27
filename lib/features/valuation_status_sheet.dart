// Wealth Ledger — 估值状态面板（低强调入口点开的受限宽度说明）。
// 全部内容来自服务端 GET /v1/portfolio/valuation-issues：
// 逐账户逐资产的原始数量与判定原因；前端不组合汇率、不做任何估值推断。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 服务端 reason → 面板上的一行短状态。
String valuationIssueMessage(ValuationIssueVm issue) => switch (issue.reason) {
  ValuationIssueReason.missingQuote => '暂无报价',
  ValuationIssueReason.missingFxPath =>
    '缺少 ${issue.sourceCurrency} → ${issue.targetCurrency} 的估值路径',
  ValuationIssueReason.staleQuote => '报价较旧',
  ValuationIssueReason.staleFx => '汇率较旧',
  ValuationIssueReason.offlineCachedQuote => '使用缓存报价',
  ValuationIssueReason.offlineCachedFx => '使用缓存汇率',
  ValuationIssueReason.quoteError => '报价获取失败',
  ValuationIssueReason.fxError => '汇率获取失败',
};

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

  /// 报价刷新后，所有由报价/汇率派生的读模型一并失效。
  void _invalidateValuationViews() {
    ref.invalidate(valuationIssuesProvider);
    ref.invalidate(overviewProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(allocationProvider);
  }

  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(quoteRepositoryProvider)
          .refreshQuotes(mode: 'manual');
      _invalidateValuationViews();
      if (result.hasProblems) {
        // 刷新有问题：面板保持打开，列表会随服务端新结果重建。
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.errors.isEmpty
                  ? '部分估值仍未刷新'
                  : '刷新失败：${result.errors.first}',
            ),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('刷新失败：$e')));
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
    final issuesAsync = ref.watch(valuationIssuesProvider);

    final body = issuesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      // 加载失败不回退到本地推断，只给短错误和重试。
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状态加载失败，请重试。'),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              onPressed: () => ref.invalidate(valuationIssuesProvider),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
      data: (issues) => Column(
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
                    Text(valuationIssueMessage(issue), style: AppType.caption),
                  ],
                ),
              ),
        ],
      ),
    );

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
