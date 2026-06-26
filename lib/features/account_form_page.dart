// Wealth Ledger — 新建账户表单（写真实账本，仅 local_server）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import 'account_visuals.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];
const Map<String, String> _balanceModes = {
  'cash_balance': '现金余额',
  'holdings': '持仓',
  'liability': '负债',
  'mixed': '混合',
};

class AccountFormPage extends ConsumerStatefulWidget {
  const AccountFormPage({super.key});
  @override
  ConsumerState<AccountFormPage> createState() => _AccountFormPageState();
}

class _AccountFormPageState extends ConsumerState<AccountFormPage> {
  final _name = TextEditingController();
  final _institution = TextEditingController();
  AccountType _type = AccountType.bank;
  String _currency = 'CNY';
  String _balanceMode = 'cash_balance';
  bool _includeInNetWorth = true;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _institution.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(accountRepositoryProvider).createAccount(
            CreateAccountInput(
              displayName: name,
              accountType: _type,
              defaultCurrency: _currency,
              balanceMode: _balanceMode,
              includeInNetWorth: _includeInNetWorth,
              institutionName:
                  _institution.text.trim().isEmpty ? null : _institution.text.trim(),
            ),
          );
      ref.invalidate(accountsProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(const SnackBar(content: Text('账户已创建')));
      if (mounted) router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建账户')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.base),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '账户名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.base),
          DropdownButtonFormField<AccountType>(
            initialValue: _type,
            decoration: const InputDecoration(
              labelText: '账户类型',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in AccountType.values)
                DropdownMenuItem(value: t, child: Text(accountTypeLabel(t))),
            ],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: AppSpacing.base),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: const InputDecoration(
              labelText: '默认币种',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final c in _currencies) DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() => _currency = v ?? _currency),
          ),
          const SizedBox(height: AppSpacing.base),
          DropdownButtonFormField<String>(
            initialValue: _balanceMode,
            decoration: const InputDecoration(
              labelText: '余额模式',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final e in _balanceModes.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _balanceMode = v ?? _balanceMode),
          ),
          const SizedBox(height: AppSpacing.base),
          TextField(
            controller: _institution,
            decoration: const InputDecoration(
              labelText: '机构名称（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('计入净资产'),
            value: _includeInNetWorth,
            onChanged: (v) => setState(() => _includeInNetWorth = v),
          ),
          const SizedBox(height: AppSpacing.base),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '创建中…' : '创建账户'),
          ),
        ],
      ),
    );
  }
}
