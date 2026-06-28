// Wealth Ledger — 行情 / 汇率（查看 + 手动录入；写真实账本，仅 local_server）。
// 手动录入走 POST /v1/quotes/refresh(mode:manual)；写入后刷新持仓/净值估值。不连真实行情源。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

({String label, Color color}) _statusChip(QuoteStatus s) => switch (s) {
      QuoteStatus.fresh => (label: '新鲜', color: Colors.green),
      QuoteStatus.stale => (label: '过期', color: Colors.orange),
      QuoteStatus.offlineCached => (label: '离线缓存', color: Colors.orange),
      QuoteStatus.incomplete => (label: '不完整', color: Colors.orange),
      QuoteStatus.unpriceable => (label: '无法估值', color: Colors.red),
      QuoteStatus.error => (label: '错误', color: Colors.red),
    };

class QuotesPage extends ConsumerWidget {
  const QuotesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotes = ref.watch(quotesProvider);
    final fx = ref.watch(fxRatesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('行情 / 汇率'),
        actions: [
          IconButton(
            tooltip: '刷新行情',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refreshFromSource(context, ref),
          ),
        ],
      ),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            Row(
              children: [
                const Expanded(child: SectionHeader(title: '行情')),
                TextButton.icon(
                  onPressed: () => _addQuote(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('录入行情'),
                ),
              ],
            ),
            quotes.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.base),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ErrorStateView(
                message: '$e',
                onRetry: () => ref.invalidate(quotesProvider),
              ),
              data: (list) => list.isEmpty
                  ? Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text('暂无行情，点「录入行情」手动添加。',
                          style: AppType.caption),
                    )
                  : Column(children: [for (final q in list) _QuoteTile(q: q)]),
            ),
            const SizedBox(height: AppSpacing.base),
            Row(
              children: [
                const Expanded(child: SectionHeader(title: '汇率')),
                TextButton.icon(
                  onPressed: () => _addFx(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('录入汇率'),
                ),
              ],
            ),
            fx.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.base),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ErrorStateView(
                message: '$e',
                onRetry: () => ref.invalidate(fxRatesProvider),
              ),
              data: (list) => list.isEmpty
                  ? Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text('暂无汇率，点「录入汇率」手动添加。',
                          style: AppType.caption),
                    )
                  : Column(children: [for (final r in list) _FxTile(r: r)]),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '手动录入会写入本地账本并刷新持仓/净值估值；不连真实行情源。',
              style: AppType.caption,
            ),
          ],
        ),
      ),
    );
  }

  void _invalidateAll(WidgetRef ref) {
    ref.invalidate(quotesProvider);
    ref.invalidate(fxRatesProvider);
    ref.invalidate(overviewProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(allocationProvider);
  }

  String _refreshMessage(QuoteRefreshResultVm r) {
    final s = '${r.quoteCount} 行情 / ${r.fxRateCount} 汇率';
    final err = r.errors.isEmpty ? '' : '：${r.errors.first}';
    return switch (r.status) {
      'success' => '已刷新：$s',
      'partial_success' => '部分刷新失败，保留缓存$err',
      'offline' => '离线或无行情源$err',
      'failed' => '刷新失败$err',
      _ => r.hasProblems ? '刷新完成但有问题$err' : '已刷新：$s',
    };
  }

  // 触发后端刷新（local_server 会尝试 Yahoo provider 拉取有 symbol 的标的），再回拉列表。
  Future<void> _refreshFromSource(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r =
          await ref.read(quoteRepositoryProvider).refreshQuotes(mode: 'manual');
      _invalidateAll(ref);
      messenger.showSnackBar(SnackBar(content: Text(_refreshMessage(r))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('刷新失败：$e')));
    }
  }

  Future<void> _addQuote(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final input = await showDialog<ManualQuoteInput>(
      context: context,
      builder: (_) => const _QuoteEntryDialog(),
    );
    if (input == null) return;
    try {
      final r = await ref
          .read(quoteRepositoryProvider)
          .refreshQuotes(mode: 'manual', quotes: [input]);
      _invalidateAll(ref);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.hasProblems
                ? '已录入但有问题：${r.errors.isEmpty ? r.status : r.errors.first}'
                : '行情已录入',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addFx(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final input = await showDialog<ManualFxRateInput>(
      context: context,
      builder: (_) => const _FxEntryDialog(),
    );
    if (input == null) return;
    try {
      final r = await ref
          .read(quoteRepositoryProvider)
          .refreshQuotes(mode: 'manual', fxRates: [input]);
      _invalidateAll(ref);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.hasProblems
                ? '已录入但有问题：${r.errors.isEmpty ? r.status : r.errors.first}'
                : '汇率已录入',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _QuoteTile extends StatelessWidget {
  const _QuoteTile({required this.q});
  final QuoteVm q;

  @override
  Widget build(BuildContext context) {
    final chip = _statusChip(q.status);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(q.instrumentId, style: AppType.bodyStrong),
      subtitle: Row(
        children: [
          _Dot(color: chip.color),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '${chip.label} · ${q.asOf.split('T').first}'
              '${q.source == null ? '' : ' · ${q.source}'}',
              style: AppType.caption,
            ),
          ),
        ],
      ),
      trailing: Text(
        formatMoney(Money(amount: q.price, currency: q.currency)),
        style: AppType.moneyRow,
      ),
    );
  }
}

class _FxTile extends StatelessWidget {
  const _FxTile({required this.r});
  final FxRateVm r;

  @override
  Widget build(BuildContext context) {
    final chip = _statusChip(r.status);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${r.baseCurrency} → ${r.quoteCurrency}', style: AppType.bodyStrong),
      subtitle: Row(
        children: [
          _Dot(color: chip.color),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '${chip.label} · ${r.asOf.split('T').first}'
              '${r.source == null ? '' : ' · ${r.source}'}',
              style: AppType.caption,
            ),
          ),
        ],
      ),
      trailing: Text(r.rate, style: AppType.moneyRow),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class _QuoteEntryDialog extends StatefulWidget {
  const _QuoteEntryDialog();
  @override
  State<_QuoteEntryDialog> createState() => _QuoteEntryDialogState();
}

class _QuoteEntryDialogState extends State<_QuoteEntryDialog> {
  final _instrument = TextEditingController();
  final _price = TextEditingController();
  String _currency = 'CNY';

  @override
  void dispose() {
    _instrument.dispose();
    _price.dispose();
    super.dispose();
  }

  bool get _valid {
    final p = _price.text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(p)) return false;
    final v = double.tryParse(p);
    return v != null && v > 0 && _instrument.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('录入行情'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _instrument,
            decoration: const InputDecoration(
              labelText: '标的 ID（instrumentId）',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '价格',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: const InputDecoration(
              labelText: '币种',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final c in _currencies)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() => _currency = v ?? _currency),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(
                    context,
                    ManualQuoteInput(
                      instrumentId: _instrument.text.trim(),
                      price: _price.text.trim(),
                      currency: _currency,
                    ),
                  )
              : null,
          child: const Text('录入'),
        ),
      ],
    );
  }
}

class _FxEntryDialog extends StatefulWidget {
  const _FxEntryDialog();
  @override
  State<_FxEntryDialog> createState() => _FxEntryDialogState();
}

class _FxEntryDialogState extends State<_FxEntryDialog> {
  final _rate = TextEditingController();
  String _base = 'USD';
  String _quote = 'CNY';

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  bool get _valid {
    final t = _rate.text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(t)) return false;
    final v = double.tryParse(t);
    return v != null && v > 0 && _base != _quote;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('录入汇率'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _base,
                  decoration: const InputDecoration(
                    labelText: '基准',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in _currencies)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _base = v ?? _base),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Icon(Icons.arrow_forward, size: 16),
              ),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _quote,
                  decoration: const InputDecoration(
                    labelText: '报价',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in _currencies)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _quote = v ?? _quote),
                ),
              ),
            ],
          ),
          if (_base == _quote)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                '基准与报价币种不能相同',
                style: AppType.caption
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '汇率（1 $_base = ? $_quote）',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(
                    context,
                    ManualFxRateInput(
                      baseCurrency: _base,
                      quoteCurrency: _quote,
                      rate: _rate.text.trim(),
                    ),
                  )
              : null,
          child: const Text('录入'),
        ),
      ],
    );
  }
}
