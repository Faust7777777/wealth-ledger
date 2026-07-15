// Wealth Ledger — 账户表单（新建 / 编辑；写真实账本，仅 local_server）。
// 类型走分组选择器；余额模式为内部概念，由类型自动派生，不在表单暴露。
// 新建支持期初余额；信用卡/贷款以正数录入「当前欠款」，由表单转为账本负数。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'account_form_validation.dart';
import 'account_type_picker.dart';
import 'account_visuals.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

/// 账户类型字段的稳定 Key（widget 测试打开选择器用）。
const kAccountTypeFieldKey = ValueKey('account_type_field');

class AccountFormPage extends ConsumerStatefulWidget {
  const AccountFormPage({super.key, this.existing, this.initialType});

  /// 非 null → 编辑模式（PATCH）；null → 新建模式（POST）。
  final AccountVm? existing;

  /// 新建时的默认类型（如从负债页进入默认「信用卡」）。
  final AccountType? initialType;

  @override
  ConsumerState<AccountFormPage> createState() => _AccountFormPageState();
}

class _AccountFormPageState extends ConsumerState<AccountFormPage> {
  final _name = TextEditingController();
  final _institution = TextEditingController();
  final _openingAmount = TextEditingController();
  late AccountType _type = widget.initialType ?? AccountType.bank;
  String _currency = 'CNY';
  bool _includeInNetWorth = true;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;
  bool get _isLiabilityType => isLiabilityAccountType(_type);

  /// 余额模式自动派生：编辑且类型未变 → 保留服务端原值（含历史 mixed）；
  /// 否则取新类型的默认模式。
  String get _balanceModeToSend {
    final e = widget.existing;
    if (e != null && e.accountType == _type) return e.balanceMode;
    return defaultBalanceModeFor(_type);
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.displayName;
      _institution.text = e.institutionName ?? '';
      _type = e.accountType;
      _currency = e.defaultCurrency;
      _includeInNetWorth = e.includeInNetWorth;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _institution.dispose();
    _openingAmount.dispose();
    super.dispose();
  }

  Future<void> _pickType() async {
    final picked = await showAccountTypePicker(context, selected: _type);
    if (picked != null && mounted) setState(() => _type = picked);
  }

  /// 期初余额（仅新建）：欠款正数输入 → 账本负数；空/零 → null（发送空数组）。
  Money? get _openingBalance {
    if (_isEdit) return null;
    final normalized = normalizedOpeningAmount(_openingAmount.text);
    if (normalized == null) return null;
    return Money(
      amount: _isLiabilityType ? '-$normalized' : normalized,
      currency: _currency,
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    if (openingAmountError(_openingAmount.text) != null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(accountRepositoryProvider);
    final input = CreateAccountInput(
      displayName: name,
      accountType: _type,
      defaultCurrency: _currency,
      balanceMode: _balanceModeToSend,
      includeInNetWorth: _includeInNetWorth,
      institutionName: _institution.text.trim().isEmpty
          ? null
          : _institution.text.trim(),
      openingBalance: _openingBalance,
    );
    try {
      if (_isEdit) {
        await repo.updateAccount(widget.existing!.id, input);
        ref.invalidate(accountByIdProvider(widget.existing!.id));
      } else {
        await repo.createAccount(input);
      }
      ref.invalidate(accountsProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(liabilitiesProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(_isEdit ? '账户已更新' : '账户已创建')),
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
    // 若账户现有币种不在预设列表（历史数据），补进去避免 Dropdown 断言。
    final currencyItems = [
      ..._currencies,
      if (!_currencies.contains(_currency)) _currency,
    ];
    final openingError = openingAmountError(_openingAmount.text);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑账户' : '新建账户')),
      body: ContentMaxWidth(
        child: ListView(
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
            InkWell(
              key: kAccountTypeFieldKey,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: _pickType,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '账户类型',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.arrow_drop_down),
                ),
                child: Row(
                  children: [
                    Icon(accountTypeIcon(_type), size: 20),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '${accountTypeLabel(_type)} · ${accountTypeExample(_type)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: const InputDecoration(
                labelText: '默认币种',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in currencyItems)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => _currency = v ?? _currency),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: AppSpacing.base),
              TextField(
                controller: _openingAmount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _isLiabilityType ? '当前欠款（可选）' : '期初余额（可选）',
                  border: const OutlineInputBorder(),
                  suffixText: _currency,
                  errorText: openingError,
                ),
              ),
            ],
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
              child: Text(
                _busy
                    ? (_isEdit ? '保存中…' : '创建中…')
                    : (_isEdit ? '保存修改' : '创建账户'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
