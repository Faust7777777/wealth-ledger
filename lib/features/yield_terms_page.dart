// Wealth Ledger — 固定收益条款表单（PATCH /v1/holdings/{id}/yield-terms）。
// 年利率按百分比输入（wire 发十进制小数）；本金与应计利息由服务端计算。
// 有待确认利息时条款不可修改（先去审核处理）。
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show ClientException;

import '../core/types.dart';
import '../data/api_mock_repositories.dart'
    show ApiConflictException, ApiValidationException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'subscription_form_validation.dart' show amountError;
import 'yield_terms_validation.dart';

String yieldFrequencyLabel(YieldCompoundingFrequency f) => switch (f) {
  YieldCompoundingFrequency.none => '不复利',
  YieldCompoundingFrequency.monthly => '按月',
  YieldCompoundingFrequency.quarterly => '按季',
  YieldCompoundingFrequency.annual => '按年',
};

class YieldTermsPage extends ConsumerStatefulWidget {
  const YieldTermsPage({super.key, required this.holdingId});
  final String holdingId;

  @override
  ConsumerState<YieldTermsPage> createState() => _YieldTermsPageState();
}

class _YieldTermsPageState extends ConsumerState<YieldTermsPage> {
  final _principal = TextEditingController();
  final _ratePercent = TextEditingController();

  YieldRateType _rateType = YieldRateType.fixed;
  YieldInterestMethod _method = YieldInterestMethod.simple;
  YieldCompoundingFrequency _frequency = YieldCompoundingFrequency.none;
  int _dayCountBasis = 365;
  String? _interestStartDate;
  String? _maturityDate;
  Id? _payoutAccountId;
  String? _currency;
  bool _busy = false;
  bool _initialized = false;

  @override
  void dispose() {
    _principal.dispose();
    _ratePercent.dispose();
    super.dispose();
  }

  void _initFrom(YieldTermsVm? terms) {
    // positions 异步返回；条款到达前不锁定，避免编辑态首帧空数据吞掉回填。
    if (_initialized || terms == null) return;
    _initialized = true;
    _principal.text = terms.principal.amount;
    _currency = terms.principal.currency;
    _ratePercent.text = wireRateToPercent(terms.annualRate);
    _rateType = terms.rateType;
    _method = terms.interestMethod;
    _frequency = terms.compoundingFrequency;
    _dayCountBasis = terms.dayCountBasis;
    _interestStartDate = terms.interestStartDate;
    _maturityDate = terms.maturityDate;
    _payoutAccountId = terms.payoutAccountId;
  }

  String? _validate() {
    final principalErr = amountError(_principal.text.trim());
    if (principalErr != null) return '本金：$principalErr';
    final rateErr = annualRatePercentError(_ratePercent.text);
    if (rateErr != null) return rateErr;
    final frequencyErr = compoundingFrequencyError(_method, _frequency);
    if (frequencyErr != null) return frequencyErr;
    if (_interestStartDate == null) return '请选择起息日';
    if (_maturityDate == null) return '请选择到期日';
    final maturityErr = maturityAfterStartError(
      _maturityDate!,
      _interestStartDate!,
    );
    if (maturityErr != null) return maturityErr;
    if (_payoutAccountId == null) return '请选择收款账户';
    return null;
  }

  Future<void> _save(String currency) async {
    final err = _validate();
    final messenger = ScaffoldMessenger.of(context);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final router = GoRouter.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(yieldRepositoryProvider)
          .updateYieldTerms(
            widget.holdingId,
            YieldTermsInput(
              principal: Money(
                amount: _principal.text.trim(),
                currency: currency,
              ),
              annualRate: percentToWireRate(_ratePercent.text.trim()),
              rateType: _rateType,
              interestMethod: _method,
              dayCountBasis: _dayCountBasis,
              compoundingFrequency: _frequency,
              interestStartDate: _interestStartDate!,
              maturityDate: _maturityDate!,
              payoutAccountId: _payoutAccountId!,
            ),
          );
      ref.invalidate(yieldPositionsProvider);
      ref.invalidate(holdingsProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(const SnackBar(content: Text('收益条款已保存')));
      if (mounted) router.pop();
    } on ApiValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('未通过校验：${e.userMessage}')));
    } on ApiConflictException {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('数据已发生变化，请重新加载后再试'),
          action: SnackBarAction(
            label: '重新加载',
            onPressed: () {
              ref.invalidate(yieldPositionsProvider);
              ref.invalidate(holdingsProvider);
            },
          ),
        ),
      );
    } catch (e) {
      // 网络失败保留表单内容，不清空、不返回。
      final isNetwork = e is SocketException || e is ClientException;
      messenger.showSnackBar(
        SnackBar(content: Text(isNetwork ? '网络连接失败，表单已保留，请稍后重试' : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final positions =
        ref.watch(yieldPositionsProvider).asData?.value ??
        const <YieldPositionVm>[];
    YieldPositionVm? position;
    for (final p in positions) {
      if (p.holdingId == widget.holdingId) position = p;
    }
    _initFrom(position?.terms);
    final pendingInterest = position?.terms.hasPendingInterest ?? false;

    final accounts =
        ref.watch(accountsProvider).asData?.value ?? const <AccountVm>[];
    final payoutAccounts = [
      for (final a in accounts)
        if (!a.isArchived &&
            (a.balanceMode == 'cash_balance' || a.balanceMode == 'mixed'))
          a,
    ];
    final holdings =
        ref.watch(holdingsProvider).asData?.value ?? const <HoldingVm>[];
    HoldingVm? holding;
    for (final h in holdings) {
      if (h.id == widget.holdingId) holding = h;
    }
    // 币种优先取已有条款；否则取收款账户的默认币种。
    final payoutAccount = _payoutAccountId == null
        ? null
        : payoutAccounts.where((a) => a.id == _payoutAccountId).firstOrNull;
    final currency = _currency ?? payoutAccount?.defaultCurrency ?? 'CNY';

    return Scaffold(
      appBar: AppBar(title: const Text('收益条款')),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            if (holding != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.base),
                child: Text(
                  holding.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            TextField(
              controller: _principal,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '本金',
                suffixText: currency,
                border: const OutlineInputBorder(),
                errorText: _principal.text.isEmpty
                    ? null
                    : amountError(_principal.text.trim()),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _ratePercent,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '年利率',
                suffixText: '%',
                hintText: '如 3.65',
                border: const OutlineInputBorder(),
                errorText: _ratePercent.text.isEmpty
                    ? null
                    : annualRatePercentError(_ratePercent.text),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            // 窄屏下逐个纵向排列，避免 SegmentedButton 溢出。
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<YieldRateType>(
                segments: const [
                  ButtonSegment(
                    value: YieldRateType.fixed,
                    label: Text('固定利率'),
                  ),
                  ButtonSegment(
                    value: YieldRateType.floating,
                    label: Text('浮动利率'),
                  ),
                ],
                selected: {_rateType},
                onSelectionChanged: (s) => setState(() => _rateType = s.first),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<YieldInterestMethod>(
                segments: const [
                  ButtonSegment(
                    value: YieldInterestMethod.simple,
                    label: Text('单利'),
                  ),
                  ButtonSegment(
                    value: YieldInterestMethod.compound,
                    label: Text('复利'),
                  ),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() {
                  _method = s.first;
                  // 单利只能 none；切到复利时给一个可用默认值。
                  _frequency = _method == YieldInterestMethod.simple
                      ? YieldCompoundingFrequency.none
                      : (_frequency == YieldCompoundingFrequency.none
                            ? YieldCompoundingFrequency.monthly
                            : _frequency);
                }),
              ),
            ),
            if (_method == YieldInterestMethod.compound) ...[
              const SizedBox(height: AppSpacing.base),
              DropdownButtonFormField<YieldCompoundingFrequency>(
                initialValue: _frequency == YieldCompoundingFrequency.none
                    ? YieldCompoundingFrequency.monthly
                    : _frequency,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '复利周期',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final f in const [
                    YieldCompoundingFrequency.monthly,
                    YieldCompoundingFrequency.quarterly,
                    YieldCompoundingFrequency.annual,
                  ])
                    DropdownMenuItem(
                      value: f,
                      child: Text(yieldFrequencyLabel(f)),
                    ),
                ],
                onChanged: (v) => setState(() => _frequency = v ?? _frequency),
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 360, label: Text('360 天')),
                  ButtonSegment(value: 365, label: Text('365 天')),
                ],
                selected: {_dayCountBasis},
                onSelectionChanged: (s) =>
                    setState(() => _dayCountBasis = s.first),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            _DateField(
              label: '起息日',
              value: _interestStartDate,
              onPick: (d) => setState(() => _interestStartDate = d),
            ),
            const SizedBox(height: AppSpacing.base),
            _DateField(
              label: '到期日',
              value: _maturityDate,
              onPick: (d) => setState(() => _maturityDate = d),
            ),
            const SizedBox(height: AppSpacing.base),
            DropdownButtonFormField<Id>(
              initialValue: _payoutAccountId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '收款账户',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final a in payoutAccounts)
                  DropdownMenuItem(
                    value: a.id,
                    child: Text('${a.displayName}（${a.defaultCurrency}）'),
                  ),
              ],
              onChanged: (v) => setState(() {
                _payoutAccountId = v;
                _currency ??= payoutAccounts
                    .where((a) => a.id == v)
                    .firstOrNull
                    ?.defaultCurrency;
              }),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed:
                  _busy ||
                      pendingInterest ||
                      !ref.writeCapabilities.canCreateAccount
                  ? null
                  : () => _save(currency),
              child: Text(_busy ? '保存中…' : '保存条款'),
            ),
            if (pendingInterest)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '有待确认的利息记录，处理后才能修改条款。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 日期选择字段：本地日历 YYYY-MM-DD，不经 UTC。
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
  });
  final String label;
  final String? value;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: Row(
        children: [
          Expanded(child: Text(value ?? '未选择')),
          TextButton.icon(
            onPressed: () async {
              final initial = value == null
                  ? DateTime.now()
                  : DateTime.tryParse(value!) ?? DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(1990),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                String two(int n) => n.toString().padLeft(2, '0');
                onPick(
                  '${picked.year}-${two(picked.month)}-${two(picked.day)}',
                );
              }
            },
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: const Text('选择'),
          ),
        ],
      ),
    );
  }
}
