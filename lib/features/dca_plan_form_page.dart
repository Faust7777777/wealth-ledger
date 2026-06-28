// Wealth Ledger — 新建 / 编辑定投计划。
// 只记录“计划投什么、何时投、投多少”，不连接券商、不下单、不转账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT'];

class DcaPlanFormPage extends ConsumerStatefulWidget {
  const DcaPlanFormPage({super.key, this.existing});

  final DcaPlanVm? existing;

  @override
  ConsumerState<DcaPlanFormPage> createState() => _DcaPlanFormPageState();
}

class _DcaPlanFormPageState extends ConsumerState<DcaPlanFormPage> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  final _amount = TextEditingController();
  final _nextDueDate = TextEditingController(text: _todayIsoDate());
  final _note = TextEditingController();
  Id? _fundingAccountId;
  CurrencyCode _currency = 'CNY';
  DcaFrequency _frequency = DcaFrequency.monthly;
  bool _busy = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _name.text = existing.displayName;
    _target.text = existing.targetInstrumentId;
    _amount.text = existing.plannedAmount.amount;
    _nextDueDate.text = existing.nextDueDate;
    _note.text = existing.note ?? '';
    _fundingAccountId = existing.fundingAccountId;
    _currency = existing.plannedAmount.currency;
    _frequency = existing.frequency;
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _amount.dispose();
    _nextDueDate.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save(List<AccountVm> accounts) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final selectedAccount = _selectedAccount(accounts);
    final name = _name.text.trim();
    final target = _target.text.trim();
    final amount = _amount.text.trim();
    final dueDate = _nextDueDate.text.trim();
    final note = _note.text.trim();

    if (selectedAccount == null) {
      messenger.showSnackBar(const SnackBar(content: Text('请先创建资金账户。')));
      return;
    }
    if (name.isEmpty || target.isEmpty || amount.isEmpty || dueDate.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请补全计划名称、目标、金额和下次日期。')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(dcaRepositoryProvider);
      if (_editing) {
        await repo.updatePlan(
          widget.existing!.id,
          UpdateDcaPlanPatch(
            displayName: name,
            targetInstrumentId: target,
            fundingAccountId: selectedAccount.id,
            plannedAmount: Money(amount: amount, currency: _currency),
            frequency: _frequency,
            nextDueDate: dueDate,
            reminderStatus: widget.existing!.status,
            note: note.isEmpty ? null : note,
            clearNote: note.isEmpty,
          ),
        );
      } else {
        await repo.createPlan(
          CreateDcaPlanInput(
            displayName: name,
            targetInstrumentId: target,
            fundingAccountId: selectedAccount.id,
            plannedAmount: Money(amount: amount, currency: _currency),
            frequency: _frequency,
            nextDueDate: dueDate,
            note: note.isEmpty ? null : note,
          ),
        );
      }
      ref.invalidate(dcaPlansProvider);
      ref.invalidate(dueRemindersProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(_editing ? '定投计划已更新。' : '定投计划已创建；只提醒和记录，不下单。')),
      );
      if (mounted) router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AccountVm? _selectedAccount(List<AccountVm> accounts) {
    if (accounts.isEmpty) return null;
    final id = _fundingAccountId;
    if (id != null) {
      for (final account in accounts) {
        if (account.id == id) return account;
      }
    }
    return accounts.first;
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? '编辑定投计划' : '新建定投计划')),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (accounts) {
          if (accounts.isEmpty) {
            return EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: '先创建资金账户',
              message: '定投计划需要关联一个资金账户，用于之后生成“记录已执行”的待确认记录。',
              action: FilledButton(
                onPressed: () => context.push('/accounts/new'),
                child: const Text('添加账户'),
              ),
            );
          }

          final selected = _selectedAccount(accounts)!;
          final currencyItems = {
            ..._currencies,
            if (!_currencies.contains(_currency)) _currency,
            if (!_currencies.contains(selected.defaultCurrency))
              selected.defaultCurrency,
          }.toList();
          final selectedId = _fundingAccountId ?? selected.id;

          return ContentMaxWidth(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '计划名称',
                    hintText: '例如：沪深300 每月定投',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _target,
                  decoration: const InputDecoration(
                    labelText: '投资目标',
                    hintText: '基金代码 / 股票代码 / 加密资产 / 自定义名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<Id>(
                  initialValue: selectedId,
                  decoration: const InputDecoration(
                    labelText: '资金账户',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(account.displayName),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    final account = accounts.firstWhere((a) => a.id == id);
                    setState(() {
                      _fundingAccountId = id;
                      _currency = account.defaultCurrency;
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.base),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _amount,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '每期金额',
                          hintText: '1000.00',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: DropdownButtonFormField<CurrencyCode>(
                        initialValue: _currency,
                        decoration: const InputDecoration(
                          labelText: '币种',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final c in currencyItems)
                            DropdownMenuItem(value: c, child: Text(c)),
                        ],
                        onChanged: (v) =>
                            setState(() => _currency = v ?? _currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<DcaFrequency>(
                  initialValue: _frequency,
                  decoration: const InputDecoration(
                    labelText: '频率',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: DcaFrequency.weekly,
                      child: Text('每周'),
                    ),
                    DropdownMenuItem(
                      value: DcaFrequency.monthly,
                      child: Text('每月'),
                    ),
                    DropdownMenuItem(
                      value: DcaFrequency.custom,
                      child: Text('自定义'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _frequency = v ?? _frequency),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _nextDueDate,
                  decoration: const InputDecoration(
                    labelText: '下次提醒日期',
                    hintText: 'YYYY-MM-DD',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _note,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    hintText: '只提醒与记录，不下单。',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                FilledButton(
                  onPressed: _busy ? null : () => _save(accounts),
                  child: Text(
                    _busy
                        ? (_editing ? '保存中…' : '创建中…')
                        : (_editing ? '保存定投计划' : '创建定投计划'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _todayIsoDate() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}
