// Wealth Ledger — 手动记账（income/expense 单分录；写真实账本，仅 local_server）。
// 候选 → 确认：填写后弹确认摘要，确认即「草稿 → 复核 → 入账」全流程；不下单、不转账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

class ManualRecordPage extends ConsumerStatefulWidget {
  const ManualRecordPage({super.key});
  @override
  ConsumerState<ManualRecordPage> createState() => _ManualRecordPageState();
}

class _ManualRecordPageState extends ConsumerState<ManualRecordPage> {
  final _amount = TextEditingController();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  MovementType _type = MovementType.expense;
  String? _accountId;
  String? _categoryId;
  String? _counterpartyId;
  String _currency = 'CNY';
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  bool get _amountValid {
    final t = _amount.text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(t)) return false;
    final v = double.tryParse(t);
    return v != null && v > 0;
  }

  bool get _canSave =>
      _accountId != null &&
      _amountValid &&
      _title.text.trim().isNotEmpty &&
      !_busy;

  bool _categoryMatchesType(CategoryVm c) => switch (_type) {
    MovementType.income => c.kind == CategoryKind.income,
    MovementType.expense => c.kind == CategoryKind.expense,
    _ => true,
  };

  Future<void> _save(
    List<AccountVm> accounts,
    List<CategoryVm> categories,
    List<CounterpartyVm> counterparties,
  ) async {
    if (!_canSave) return;
    final acct = accounts.firstWhere((a) => a.id == _accountId);
    final categoryName = _categoryId == null
        ? null
        : categories
              .where((c) => c.id == _categoryId)
              .map((c) => c.displayName)
              .fold<String?>(null, (previous, name) => previous ?? name);
    final counterpartyName = _counterpartyId == null
        ? null
        : counterparties
              .where((p) => p.id == _counterpartyId)
              .map((p) => p.displayName)
              .fold<String?>(null, (previous, name) => previous ?? name);
    final amount = _amount.text.trim();
    final isIncome = _type == MovementType.income;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final sign = isIncome ? '+' : '−';
    final unit = _currency == 'CNY' ? '¥' : '$_currency ';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认入账'),
        content: Text(
          '${isIncome ? '收入' : '支出'}  $sign$unit$amount\n'
          '账户：${acct.displayName}\n'
          '摘要：${_title.text.trim()}'
          '${categoryName == null ? '' : '\n分类：$categoryName'}'
          '${counterpartyName == null ? '' : '\n对手方：$counterpartyName'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('再改改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认入账'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(movementRepositoryProvider)
          .createManualRecord(
            ManualRecordInput(
              type: _type,
              accountId: _accountId!,
              amount: amount,
              currency: _currency,
              title: _title.text.trim(),
              description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
              categoryId: _categoryId,
              counterpartyId: _counterpartyId,
            ),
          );
      ref.invalidate(recentMovementsProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(allocationProvider);
      ref.invalidate(snapshotsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('已入账')));
      if (mounted) router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final categories =
        ref.watch(categoriesProvider).asData?.value ?? const <CategoryVm>[];
    final counterparties =
        ref.watch(counterpartiesProvider).asData?.value ??
        const <CounterpartyVm>[];
    return Scaffold(
      appBar: AppBar(title: const Text('手动记账')),
      body: ContentMaxWidth(
        child: accountsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () => ref.invalidate(accountsProvider),
          ),
          data: (accounts) {
            if (accounts.isEmpty) {
              return EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: '还没有账户',
                message: '先添加一个账户，才能记账。',
                action: FilledButton(
                  onPressed: () => context.push('/accounts/new'),
                  child: const Text('添加账户'),
                ),
              );
            }
            _accountId ??= accounts.first.id;
            final filteredCategories = categories
                .where(_categoryMatchesType)
                .toList();
            if (_categoryId != null &&
                !filteredCategories.any((c) => c.id == _categoryId)) {
              _categoryId = null;
            }
            final currencyItems = [
              ..._currencies,
              if (!_currencies.contains(_currency)) _currency,
            ];
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                SegmentedButton<MovementType>(
                  segments: const [
                    ButtonSegment(
                      value: MovementType.expense,
                      label: Text('支出'),
                      icon: Icon(Icons.south_east),
                    ),
                    ButtonSegment(
                      value: MovementType.income,
                      label: Text('收入'),
                      icon: Icon(Icons.north_east),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() {
                    _type = s.first;
                    if (_categoryId != null &&
                        !categories
                            .where(_categoryMatchesType)
                            .any((c) => c.id == _categoryId)) {
                      _categoryId = null;
                    }
                  }),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '金额',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(
                    labelText: '账户',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(value: a.id, child: Text(a.displayName)),
                  ],
                  onChanged: (v) => setState(() {
                    _accountId = v;
                    _currency = accounts
                        .firstWhere((x) => x.id == v)
                        .defaultCurrency;
                  }),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _currency,
                  decoration: const InputDecoration(
                    labelText: '币种',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in currencyItems)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _currency = v ?? _currency),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(
                    labelText: '摘要',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _categoryId ?? '',
                  decoration: const InputDecoration(
                    labelText: '分类（可选）',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不选择')),
                    for (final c in filteredCategories)
                      DropdownMenuItem(value: c.id, child: Text(c.displayName)),
                  ],
                  onChanged: (v) => setState(
                    () => _categoryId = v == null || v.isEmpty ? null : v,
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _counterpartyId ?? '',
                  decoration: const InputDecoration(
                    labelText: '对手方（可选）',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不选择')),
                    for (final p in counterparties)
                      DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                  ],
                  onChanged: (v) => setState(
                    () => _counterpartyId = v == null || v.isEmpty ? null : v,
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _desc,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                FilledButton(
                  onPressed: _canSave
                      ? () => _save(accounts, categories, counterparties)
                      : null,
                  child: Text(_busy ? '入账中…' : '记一笔'),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('记账会生成候选并即时确认入账；不下单、不转账、不连券商。', style: AppType.caption),
              ],
            );
          },
        ),
      ),
    );
  }
}
