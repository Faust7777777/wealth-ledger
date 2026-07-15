// Wealth Ledger — DCA 真实成交记录表单（对话框）。
// 计划金额只作为总成本默认值；实际数量必须由用户如实填写，绝不预填计划金额。
// 本对话框只收集 DcaExecutionInput（确认后由调用方发请求生成候选），不下单、不自动确认。
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import 'subscription_form_validation.dart' show amountError;

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];
const Key kDcaCostCurrencyFieldKey = Key('dca_cost_currency_field');

List<String> _currencyItems(String current) => [
  ..._currencies,
  if (!_currencies.contains(current)) current,
];

/// 打开成交表单；确认返回 DcaExecutionInput，取消返回 null。
Future<DcaExecutionInput?> showDcaExecutionDialog(
  BuildContext context, {
  required DcaReminderVm reminder,
  required List<AccountVm> holdingAccounts,
}) => showDialog<DcaExecutionInput>(
  context: context,
  builder: (_) =>
      DcaExecutionDialog(reminder: reminder, holdingAccounts: holdingAccounts),
);

class DcaExecutionDialog extends StatefulWidget {
  const DcaExecutionDialog({
    super.key,
    required this.reminder,
    required this.holdingAccounts,
  });

  final DcaReminderVm reminder;

  /// 可选持仓账户（调用方已过滤：balanceMode=holdings|mixed 且未归档）。
  final List<AccountVm> holdingAccounts;

  @override
  State<DcaExecutionDialog> createState() => _DcaExecutionDialogState();
}

class _DcaExecutionDialogState extends State<DcaExecutionDialog> {
  final _quantity = TextEditingController();
  late final _cost = TextEditingController(
    text: widget.reminder.plannedAmount.amount,
  );
  late String _costCurrency = widget.reminder.plannedAmount.currency;
  late String? _accountId = widget.holdingAccounts.isEmpty
      ? null
      : widget.holdingAccounts.first.id;
  late String _quoteCurrency = widget.holdingAccounts.isEmpty
      ? widget.reminder.plannedAmount.currency
      : widget.holdingAccounts.first.defaultCurrency;

  @override
  void dispose() {
    _quantity.dispose();
    _cost.dispose();
    super.dispose();
  }

  void _onAccountChanged(String? id) {
    if (id == null) return;
    final acct = widget.holdingAccounts.firstWhere((a) => a.id == id);
    setState(() {
      _accountId = id;
      // 报价币种跟随所选账户默认币种（用户仍可再改）。
      _quoteCurrency = acct.defaultCurrency;
    });
  }

  bool get _canSubmit =>
      _accountId != null &&
      amountError(_quantity.text) == null &&
      amountError(_cost.text) == null;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.pop(
      context,
      DcaExecutionInput(
        holdingAccountId: _accountId!,
        quantity: _quantity.text.trim(),
        totalCost: Money(amount: _cost.text.trim(), currency: _costCurrency),
        quoteCurrency: _quoteCurrency,
        // executedAt 省略：由服务端取当前时间。
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reminder;
    final maxListHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      240.0,
      460.0,
    );
    if (widget.holdingAccounts.isEmpty) {
      return AlertDialog(
        title: const Text('记录本期成交'),
        content: const SizedBox(
          width: 380,
          child: Text('暂无可用的持仓账户。请先创建证券账户或其他投资账户，再记录成交。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final costItems = _currencyItems(_costCurrency);
    final quoteItems = _currencyItems(_quoteCurrency);
    return AlertDialog(
      title: const Text('记录本期成交'),
      content: SizedBox(
        width: 380,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxListHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.displayName} · 计划 ${formatMoney(r.plannedAmount)} · ${r.dueDate}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(
                    labelText: '持仓账户',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final a in widget.holdingAccounts)
                      DropdownMenuItem(value: a.id, child: Text(a.displayName)),
                  ],
                  onChanged: _onAccountChanged,
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _quantity,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '实际数量',
                    hintText: '如 10 或 0.5',
                    border: const OutlineInputBorder(),
                    errorText: _quantity.text.isEmpty
                        ? null
                        : amountError(_quantity.text),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '实际总成本',
                    border: const OutlineInputBorder(),
                    errorText: _cost.text.isEmpty
                        ? null
                        : amountError(_cost.text),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  key: kDcaCostCurrencyFieldKey,
                  initialValue: _costCurrency,
                  decoration: const InputDecoration(
                    labelText: '成本币种',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in costItems)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (value) =>
                      setState(() => _costCurrency = value ?? _costCurrency),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _quoteCurrency,
                  decoration: const InputDecoration(
                    labelText: '报价币种',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in quoteItems)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) =>
                      setState(() => _quoteCurrency = v ?? _quoteCurrency),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('确认记录'),
        ),
      ],
    );
  }
}
