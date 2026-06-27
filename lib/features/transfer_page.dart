// Wealth Ledger — 转账（账户间转移；同币种同额双分录 MVP，写真实账本，仅 local_server）。
// 候选 → 确认：填写后弹确认摘要，确认即「草稿 → 复核 → 入账」全流程；不下单、不连银行。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

class TransferPage extends ConsumerStatefulWidget {
  const TransferPage({super.key});
  @override
  ConsumerState<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends ConsumerState<TransferPage> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _fromId;
  String? _toId;
  String _currency = 'CNY';
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _amountValid {
    final t = _amount.text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(t)) return false;
    final v = double.tryParse(t);
    return v != null && v > 0;
  }

  bool get _canSave =>
      _fromId != null &&
      _toId != null &&
      _fromId != _toId &&
      _amountValid &&
      !_busy;

  Future<void> _save(List<AccountVm> accounts) async {
    if (!_canSave) return;
    final from = accounts.firstWhere((a) => a.id == _fromId);
    final to = accounts.firstWhere((a) => a.id == _toId);
    final amount = _amount.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final unit = _currency == 'CNY' ? '¥' : '$_currency ';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认转账'),
        content: Text('$unit$amount\n${from.displayName} → ${to.displayName}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('再改改')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认转账')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(movementRepositoryProvider).createTransfer(
            TransferInput(
              fromAccountId: _fromId!,
              toAccountId: _toId!,
              amount: amount,
              currency: _currency,
              title: '转账',
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      ref.invalidate(recentMovementsProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(allocationProvider);
      ref.invalidate(snapshotsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('转账已入账')));
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
    return Scaffold(
      appBar: AppBar(title: const Text('转账')),
      body: ContentMaxWidth(
          child: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (accounts) {
          if (accounts.length < 2) {
            return EmptyState(
              icon: Icons.swap_horiz,
              title: '至少需要两个账户',
              message: '转账需要转出和转入两个账户。',
              action: FilledButton(
                onPressed: () => context.push('/accounts/new'),
                child: const Text('添加账户'),
              ),
            );
          }
          _fromId ??= accounts.first.id;
          _toId ??= accounts.firstWhere((a) => a.id != _fromId).id;
          final currencyItems = [
            ..._currencies,
            if (!_currencies.contains(_currency)) _currency,
          ];
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
              DropdownButtonFormField<String>(
                initialValue: _fromId,
                decoration: const InputDecoration(
                  labelText: '转出账户',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.displayName)),
                ],
                onChanged: (v) => setState(() {
                  _fromId = v;
                  _currency =
                      accounts.firstWhere((x) => x.id == v).defaultCurrency;
                  if (_toId == _fromId) {
                    _toId = accounts.firstWhere((a) => a.id != _fromId).id;
                  }
                }),
              ),
              const SizedBox(height: AppSpacing.base),
              DropdownButtonFormField<String>(
                initialValue: _toId,
                decoration: const InputDecoration(
                  labelText: '转入账户',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.displayName)),
                ],
                onChanged: (v) => setState(() => _toId = v),
              ),
              if (_fromId == _toId)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    '转出和转入不能是同一账户',
                    style: AppType.caption
                        .copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: AppSpacing.base),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '金额',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
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
                controller: _note,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              FilledButton(
                onPressed: _canSave ? () => _save(accounts) : null,
                child: Text(_busy ? '转账中…' : '转账'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '同额同币种转账；暂不支持跨币种折算。不下单、不连银行。',
                style: AppType.caption,
              ),
            ],
          );
        },
      )),
    );
  }
}
