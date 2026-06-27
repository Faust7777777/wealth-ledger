// Wealth Ledger — 余额观察/校准（录入实际余额，对差额生成 adjustment 候选；仅 local_server）。
// 候选 → 确认：确认后对（实际 − 当前）差额生成一条 adjustment 并入账；不改历史流水。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class ReconcilePage extends ConsumerStatefulWidget {
  const ReconcilePage({super.key});
  @override
  ConsumerState<ReconcilePage> createState() => _ReconcilePageState();
}

class _ReconcilePageState extends ConsumerState<ReconcilePage> {
  final _observed = TextEditingController();
  final _note = TextEditingController();
  String? _accountId;
  String? _currency;
  bool _busy = false;

  @override
  void dispose() {
    _observed.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _observedValid =>
      RegExp(r'^\d+(\.\d+)?$').hasMatch(_observed.text.trim());

  bool _isZero(String d) => !RegExp(r'[1-9]').hasMatch(d);

  String _signed(String delta) =>
      '${delta.startsWith('-') ? '−' : '+'}${formatDecimalThousands(delta.replaceFirst('-', ''))}';

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('余额观察')),
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
              icon: Icons.fact_check_outlined,
              title: '还没有账户',
              message: '先添加账户，才能校准余额。',
              action: FilledButton(
                onPressed: () => context.push('/accounts/new'),
                child: const Text('添加账户'),
              ),
            );
          }
          _accountId ??= accounts.first.id;
          final acct = accounts.firstWhere(
            (a) => a.id == _accountId,
            orElse: () => accounts.first,
          );
          final curs = <String>{...acct.cashBalances.keys, acct.defaultCurrency}
              .toList();
          _currency ??= acct.defaultCurrency;
          if (!curs.contains(_currency)) _currency = curs.first;
          final cur = _currency!;
          final current = acct.cashBalances[cur] ?? '0';
          final observed = _observed.text.trim();
          final delta = _observedValid ? subtractDecimal(observed, current) : null;
          final deltaZero = delta != null && _isZero(delta);
          final canSave = delta != null && !deltaZero && !_busy;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
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
                  _currency = null;
                }),
              ),
              const SizedBox(height: AppSpacing.base),
              DropdownButtonFormField<String>(
                initialValue: cur,
                decoration: const InputDecoration(
                  labelText: '币种',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in curs)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => _currency = v),
              ),
              const SizedBox(height: AppSpacing.base),
              Card(
                child: ListTile(
                  title: const Text('当前记录余额'),
                  trailing: Text(
                    formatMoney(Money(amount: current, currency: cur),
                        withCode: true),
                    style: AppType.moneyRow,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              TextField(
                controller: _observed,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '实际余额（你观察到的）',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (delta != null)
                Text(
                  deltaZero ? '余额一致，无需校准' : '将记入调整：${_signed(delta)} $cur',
                  style: AppType.caption,
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
                onPressed: canSave ? () => _save(acct, cur, current) : null,
                child: Text(_busy ? '校准中…' : '记录校准'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '校准会对差额生成一条 adjustment 候选并入账；不改动历史流水。',
                style: AppType.caption,
              ),
            ],
          );
        },
      )),
    );
  }

  Future<void> _save(AccountVm acct, String cur, String current) async {
    final observed = _observed.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final delta = subtractDecimal(observed, current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认校准'),
        content: Text(
          '${acct.displayName}\n'
          '当前 ${formatMoney(Money(amount: current, currency: cur))} → '
          '实际 ${formatMoney(Money(amount: observed, currency: cur))}\n'
          '调整 ${_signed(delta)} $cur',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('再改改')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认校准')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(movementRepositoryProvider).reconcileBalance(
            ReconcileInput(
              accountId: acct.id,
              currency: cur,
              currentBalance: current,
              observedBalance: observed,
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      ref.invalidate(recentMovementsProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(allocationProvider);
      ref.invalidate(snapshotsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('余额已校准')));
      if (mounted) router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
