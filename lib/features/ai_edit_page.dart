// Wealth Ledger — 编辑 AI 候选（把无金额的文本候选补成结构化 movement；仅 local_server）。
// 编辑只更新候选 proposal（不写账本）；补全后回 AI 复核「接受整组」才真正入账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

class AiEditPage extends ConsumerStatefulWidget {
  const AiEditPage({super.key, required this.groupId});
  final String groupId;
  @override
  ConsumerState<AiEditPage> createState() => _AiEditPageState();
}

class _AiEditPageState extends ConsumerState<AiEditPage> {
  final _amount = TextEditingController();
  final _title = TextEditingController();
  MovementType _type = MovementType.expense;
  String? _accountId;
  String _currency = 'CNY';
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _title.dispose();
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

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(aiProposalRepositoryProvider).editAtomicGroup(
            widget.groupId,
            ManualRecordInput(
              type: _type,
              accountId: _accountId!,
              amount: _amount.text.trim(),
              currency: _currency,
              title: _title.text.trim(),
            ),
          );
      ref.invalidate(aiPendingProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('已补全候选，请回 AI 复核「接受整组」入账')),
      );
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
      appBar: AppBar(title: const Text('编辑 AI 候选')),
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
              message: '先添加账户，才能把候选补成结构化记录。',
              action: FilledButton(
                onPressed: () => context.push('/accounts/new'),
                child: const Text('添加账户'),
              ),
            );
          }
          _accountId ??= accounts.first.id;
          final currencyItems = [
            ..._currencies,
            if (!_currencies.contains(_currency)) _currency,
          ];
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.base),
            children: [
              Text(
                'AI 文本候选不含金额；补全为结构化收支后，回 AI 复核点「接受整组」才写账本。',
                style: AppType.caption,
              ),
              const SizedBox(height: AppSpacing.base),
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
                onSelectionChanged: (s) => setState(() => _type = s.first),
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
                  _currency =
                      accounts.firstWhere((x) => x.id == v).defaultCurrency;
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
              FilledButton(
                onPressed: _canSave ? _save : null,
                child: Text(_busy ? '保存中…' : '保存候选'),
              ),
            ],
          );
        },
      )),
    );
  }
}
