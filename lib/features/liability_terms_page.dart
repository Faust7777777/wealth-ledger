// Wealth Ledger — 贷款条款表单（PATCH /v1/accounts/{id}/liability-terms）。
// 年利率按百分比输入（wire 发十进制小数）；应计与拆分由服务端计算。
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
import 'liability_terms_validation.dart';

String liabilityTypeLabel(LiabilityType t) => switch (t) {
  LiabilityType.studentLoan => '助学贷款',
  LiabilityType.mortgage => '房贷',
  LiabilityType.consumerLoan => '消费贷款',
  LiabilityType.creditCard => '信用卡',
  LiabilityType.other => '其他',
};

class LiabilityTermsPage extends ConsumerStatefulWidget {
  const LiabilityTermsPage({super.key, required this.accountId});
  final String accountId;

  @override
  ConsumerState<LiabilityTermsPage> createState() => _LiabilityTermsPageState();
}

class _LiabilityTermsPageState extends ConsumerState<LiabilityTermsPage> {
  final _ratePercent = TextEditingController();
  final _payment = TextEditingController();

  LiabilityType _type = LiabilityType.other;
  LiabilityRateType _rateType = LiabilityRateType.fixed;
  int _dayCountBasis = 365;
  String? _interestStartDate;
  String? _maturityDate;
  String? _repaymentStartDate;
  String? _nextDueDate;
  Id? _paymentAccountId;
  bool _busy = false;
  bool _initialized = false;

  @override
  void dispose() {
    _ratePercent.dispose();
    _payment.dispose();
    super.dispose();
  }

  void _initFrom(LiabilityTermsVm? terms) {
    // positions 异步返回；条款到达前不锁定，避免编辑态首帧空数据吞掉回填。
    if (_initialized || terms == null) return;
    _initialized = true;
    _type = terms.liabilityType;
    _ratePercent.text = wireRateToPercent(terms.annualRate);
    _rateType = terms.rateType;
    _dayCountBasis = terms.dayCountBasis;
    _interestStartDate = terms.interestStartDate;
    _maturityDate = terms.maturityDate;
    _repaymentStartDate = terms.repaymentStartDate;
    _nextDueDate = terms.nextDueDate;
    _payment.text = terms.scheduledPayment.amount;
    _paymentAccountId = terms.paymentAccountId;
  }

  String? _validate() {
    final rateErr = annualRatePercentError(_ratePercent.text);
    if (rateErr != null) return rateErr;
    if (_interestStartDate == null) return '请选择起息日';
    if (_maturityDate == null) return '请选择到期日';
    final maturityErr = maturityAfterStartError(
      _maturityDate!,
      _interestStartDate!,
    );
    if (maturityErr != null) return maturityErr;
    if (_repaymentStartDate == null) return '请选择还款起始日';
    if (_nextDueDate == null) return '请选择下次还款日';
    final paymentErr = amountError(_payment.text.trim());
    if (paymentErr != null) return '月还款金额：$paymentErr';
    if (_paymentAccountId == null) return '请选择付款账户';
    return null;
  }

  Future<void> _save(AccountVm account) async {
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
          .read(loanRepositoryProvider)
          .updateLiabilityTerms(
            widget.accountId,
            LiabilityTermsInput(
              liabilityType: _type,
              annualRate: percentToWireRate(_ratePercent.text.trim()),
              rateType: _rateType,
              dayCountBasis: _dayCountBasis,
              interestStartDate: _interestStartDate!,
              maturityDate: _maturityDate!,
              repaymentStartDate: _repaymentStartDate!,
              nextDueDate: _nextDueDate!,
              scheduledPayment: Money(
                amount: _payment.text.trim(),
                currency: account.defaultCurrency,
              ),
              paymentAccountId: _paymentAccountId!,
            ),
          );
      ref.invalidate(liabilityPositionsProvider);
      ref.invalidate(accountByIdProvider(widget.accountId));
      ref.invalidate(accountsProvider);
      ref.invalidate(liabilitiesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('贷款条款已保存')));
      if (mounted) router.pop();
    } on ApiValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('未通过校验：${e.userMessage}')));
    } on ApiConflictException {
      messenger.showSnackBar(const SnackBar(content: Text('数据已发生变化，请返回后重试')));
    } catch (e) {
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
    final accountAsync = ref.watch(accountByIdProvider(widget.accountId));
    final positions =
        ref.watch(liabilityPositionsProvider).asData?.value ??
        const <LiabilityPositionVm>[];
    LiabilityTermsVm? existing;
    for (final p in positions) {
      if (p.accountId == widget.accountId) existing = p.terms;
    }
    _initFrom(existing);
    final pendingInterest = existing?.hasPendingInterest ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('贷款条款')),
      body: ContentMaxWidth(
        child: accountAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () =>
                ref.invalidate(accountByIdProvider(widget.accountId)),
          ),
          data: (account) {
            if (account == null) {
              return const EmptyState(icon: Icons.help_outline, title: '账户不存在');
            }
            final accounts =
                ref.watch(accountsProvider).asData?.value ??
                const <AccountVm>[];
            final paymentAccounts = [
              for (final a in accounts)
                if (!a.isArchived &&
                    (a.balanceMode == 'cash_balance' ||
                        a.balanceMode == 'mixed'))
                  a,
            ];
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                DropdownButtonFormField<LiabilityType>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '贷款类型',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final t in LiabilityType.values)
                      DropdownMenuItem(
                        value: t,
                        child: Text(liabilityTypeLabel(t)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? _type),
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
                SegmentedButton<LiabilityRateType>(
                  segments: const [
                    ButtonSegment(
                      value: LiabilityRateType.fixed,
                      label: Text('固定利率'),
                    ),
                    ButtonSegment(
                      value: LiabilityRateType.floating,
                      label: Text('浮动利率'),
                    ),
                  ],
                  selected: {_rateType},
                  onSelectionChanged: (s) =>
                      setState(() => _rateType = s.first),
                ),
                if (_rateType == LiabilityRateType.floating)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      '利率变化时，在这里更新当前值。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: AppSpacing.base),
                Row(
                  children: [
                    Expanded(
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
                    const SizedBox(width: AppSpacing.xs),
                    // 解释只放在小型信息入口内，不占常驻正文。
                    Tooltip(
                      message: '利息按 年利率 ÷ 计息天数 逐日累计',
                      triggerMode: TooltipTriggerMode.tap,
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
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
                _DateField(
                  label: '还款起始日',
                  value: _repaymentStartDate,
                  onPick: (d) => setState(() => _repaymentStartDate = d),
                ),
                const SizedBox(height: AppSpacing.base),
                _DateField(
                  label: '下次还款日',
                  value: _nextDueDate,
                  onPick: (d) => setState(() => _nextDueDate = d),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _payment,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '月还款计划金额',
                    suffixText: account.defaultCurrency,
                    border: const OutlineInputBorder(),
                    errorText: _payment.text.isEmpty
                        ? null
                        : amountError(_payment.text.trim()),
                  ),
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<Id>(
                  initialValue: _paymentAccountId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '付款账户',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final a in paymentAccounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.displayName}（${a.defaultCurrency}）'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _paymentAccountId = v),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed:
                      _busy ||
                          pendingInterest ||
                          !ref.writeCapabilities.canCreateAccount
                      ? null
                      : () => _save(account),
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
            );
          },
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
