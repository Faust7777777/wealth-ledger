// Wealth Ledger — 订阅表单（新建 POST / 编辑 PATCH；写真实账本，仅 local_server）。
// 客户端只做可用性校验，服务端仍是权威。金额十进制字符串、日期本地日历字符串。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/types.dart';
import '../data/api_mock_repositories.dart' show ApiValidationException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'subscription_form_validation.dart';
import 'subscription_visuals.dart';

const List<String> _currencies = ['CNY', 'USD', 'HKD', 'USDT', 'BTC', 'ETH'];

enum _TermMode { none, duration, endDate }

class SubscriptionFormPage extends ConsumerStatefulWidget {
  const SubscriptionFormPage({super.key, this.existing});

  /// 非 null → 编辑（PATCH 整表替换）；null → 新建（POST）。
  final SubscriptionVm? existing;

  @override
  ConsumerState<SubscriptionFormPage> createState() =>
      _SubscriptionFormPageState();
}

class _SubscriptionFormPageState extends ConsumerState<SubscriptionFormPage> {
  final _displayName = TextEditingController();
  final _provider = TextEditingController();
  final _planName = TextEditingController();
  final _amount = TextEditingController();
  final _billingInterval = TextEditingController(text: '1');
  final _durationCount = TextEditingController(text: '1');
  final _reminderDays = TextEditingController(text: '3');
  final _note = TextEditingController();

  String _currency = 'CNY';
  String? _paymentAccountId;
  String _startDate = todayIsoDate();

  /// 下次扣费日：与开始日期是两个概念（本月已续费 → 直接填下个月）。
  /// 新建默认等于开始日期；编辑用服务端值初始化；null（已取消）不发送。
  String? _nextChargeDate;

  /// 用户是否在本次会话手动改过下次扣费日：改过则不再随开始日期联动。
  bool _nextChargeTouched = false;
  BillingUnit _billingUnit = BillingUnit.month;
  _TermMode _termMode = _TermMode.none;
  SubscriptionDurationUnit _durationUnit = SubscriptionDurationUnit.month;
  String? _endDate;
  bool _autoRenew = true;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nextChargeDate = _startDate;
    final e = widget.existing;
    if (e != null) {
      _displayName.text = e.displayName;
      _provider.text = e.provider;
      _planName.text = e.planName ?? '';
      _amount.text = e.amount.amount;
      _currency = e.amount.currency;
      _paymentAccountId = e.paymentAccountId;
      _startDate = e.startDate;
      _nextChargeDate = e.nextChargeDate;
      _billingUnit = e.billingCycle.unit;
      _billingInterval.text = e.billingCycle.interval.toString();
      _reminderDays.text = e.reminderDaysBefore.toString();
      _autoRenew = e.autoRenew;
      _note.text = e.note ?? '';
      if (e.duration != null) {
        _termMode = _TermMode.duration;
        _durationUnit = e.duration!.unit;
        _durationCount.text = e.duration!.count.toString();
      } else if (e.endDate != null) {
        _termMode = _TermMode.endDate;
        _endDate = e.endDate;
      }
    }
  }

  @override
  void dispose() {
    _displayName.dispose();
    _provider.dispose();
    _planName.dispose();
    _amount.dispose();
    _billingInterval.dispose();
    _durationCount.dispose();
    _reminderDays.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).asData?.value ?? const [];
    // 编辑时若付款账户已归档、不在列表，补进去避免 Dropdown 断言。
    final accountItems = <AccountVm>[
      ...accounts,
      if (_paymentAccountId != null &&
          !accounts.any((a) => a.id == _paymentAccountId) &&
          widget.existing != null)
        AccountVm(
          id: _paymentAccountId!,
          displayName: '${_paymentAccountId!}（已归档）',
          accountType: AccountType.other,
          isLiability: false,
          defaultCurrency: _currency,
        ),
    ];
    final selectedAccount = accountItems.cast<AccountVm?>().firstWhere(
      (a) => a!.id == _paymentAccountId,
      orElse: () => null,
    );
    final currencyMismatch =
        selectedAccount != null &&
        !_accountSupports(selectedAccount, _currency);
    final currencyItems = [
      ..._currencies,
      if (!_currencies.contains(_currency)) _currency,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑订阅' : '新建订阅')),
      body: ContentMaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            _text(_displayName, '名称', hint: '如 ChatGPT Plus'),
            const SizedBox(height: AppSpacing.base),
            _text(_provider, '服务商', hint: '如 OpenAI'),
            const SizedBox(height: AppSpacing.base),
            _text(_planName, '计划名（可选）', hint: '如 Plus'),
            const SizedBox(height: AppSpacing.base),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: '原币金额',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _currency,
                    // 窄列内防内部 Row 溢出。
                    isExpanded: true,
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
            DropdownButtonFormField<String>(
              initialValue: _paymentAccountId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '付款账户',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final a in accountItems)
                  DropdownMenuItem(
                    value: a.id,
                    child: Text('${a.displayName}（${a.defaultCurrency}）'),
                  ),
              ],
              onChanged: (v) => setState(() => _paymentAccountId = v),
            ),
            if (currencyMismatch)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '该账户不支持 $_currency。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: AppSpacing.base),
            _DateField(
              label: '订阅开始日期',
              value: _startDate,
              onPick: (d) => setState(() {
                _startDate = d;
                if (!_nextChargeTouched) {
                  final next = _nextChargeDate;
                  if (!_isEdit) {
                    // 新建：未手动改过时始终跟随开始日期。
                    _nextChargeDate = d;
                  } else if (next != null && next.compareTo(d) < 0) {
                    // 编辑：仅当原下次扣费日早于新开始日期时顺延，
                    // 否则保留服务端排期。
                    _nextChargeDate = d;
                  }
                }
              }),
            ),
            const SizedBox(height: AppSpacing.base),
            _DateField(
              label: '下次扣费日',
              value: _nextChargeDate,
              onPick: (d) => setState(() {
                _nextChargeDate = d;
                _nextChargeTouched = true;
              }),
            ),
            const SizedBox(height: AppSpacing.base),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<BillingUnit>(
                    initialValue: _billingUnit,
                    decoration: const InputDecoration(
                      labelText: '计费单位',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: BillingUnit.day,
                        child: Text('日'),
                      ),
                      DropdownMenuItem(
                        value: BillingUnit.week,
                        child: Text('周'),
                      ),
                      DropdownMenuItem(
                        value: BillingUnit.month,
                        child: Text('月'),
                      ),
                      DropdownMenuItem(
                        value: BillingUnit.year,
                        child: Text('年'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _billingUnit = v ?? _billingUnit),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _intField(_billingInterval, '每几个')),
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            _termSection(),
            const SizedBox(height: AppSpacing.base),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动续订'),
              value: _autoRenew,
              onChanged: (v) => setState(() => _autoRenew = v),
            ),
            const SizedBox(height: AppSpacing.sm),
            _intField(_reminderDays, '提前提醒天数'),
            const SizedBox(height: AppSpacing.base),
            _text(_note, '备注（可选）'),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(
                _busy
                    ? (_isEdit ? '保存中…' : '创建中…')
                    : (_isEdit ? '保存修改' : '创建订阅'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _termSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('期限', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        // 窄屏（<380 逻辑宽）下三段中文标签放不下，允许横向滚动而不溢出。
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<_TermMode>(
            segments: const [
              ButtonSegment(value: _TermMode.none, label: Text('无固定期限')),
              ButtonSegment(value: _TermMode.duration, label: Text('持续时长')),
              ButtonSegment(value: _TermMode.endDate, label: Text('结束日期')),
            ],
            selected: {_termMode},
            onSelectionChanged: (s) => setState(() => _termMode = s.first),
          ),
        ),
        if (_termMode == _TermMode.duration) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DropdownButtonFormField<SubscriptionDurationUnit>(
                  initialValue: _durationUnit,
                  decoration: const InputDecoration(
                    labelText: '时长单位',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: SubscriptionDurationUnit.day,
                      child: Text('天'),
                    ),
                    DropdownMenuItem(
                      value: SubscriptionDurationUnit.month,
                      child: Text('月'),
                    ),
                    DropdownMenuItem(
                      value: SubscriptionDurationUnit.year,
                      child: Text('年'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _durationUnit = v ?? _durationUnit),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _intField(_durationCount, '数量')),
            ],
          ),
        ] else if (_termMode == _TermMode.endDate) ...[
          const SizedBox(height: AppSpacing.sm),
          _DateField(
            label: '结束日期',
            value: _endDate,
            onPick: (d) => setState(() => _endDate = d),
          ),
        ],
      ],
    );
  }

  Widget _text(TextEditingController c, String label, {String? hint}) =>
      TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _intField(TextEditingController c, String label) => TextField(
    controller: c,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  bool _accountSupports(AccountVm a, String currency) =>
      a.defaultCurrency == currency || a.cashBalances.containsKey(currency);

  /// 客户端可用性校验：返回首个错误文案，全部通过返回 null。校验逻辑见
  /// [subscription_form_validation]（纯函数、可单测）。
  String? _validate(AccountVm? account) {
    if (_displayName.text.trim().isEmpty) return '请填写名称';
    if (_provider.text.trim().isEmpty) return '请填写服务商';
    final amountErr = amountError(_amount.text.trim());
    if (amountErr != null) return amountErr;
    if (_paymentAccountId == null) return '请选择付款账户';
    if (account != null && !_accountSupports(account, _currency)) {
      return '付款账户不支持 $_currency';
    }
    final intervalErr = positiveIntError(_billingInterval.text, '计费周期');
    if (intervalErr != null) return intervalErr;
    final reminderErr = nonNegativeIntError(_reminderDays.text, '提前提醒天数');
    if (reminderErr != null) return reminderErr;
    if (_termMode == _TermMode.duration) {
      final countErr = positiveIntError(_durationCount.text, '持续时长');
      if (countErr != null) return countErr;
    }
    if (_termMode == _TermMode.endDate) {
      final endErr = endDateAfterStartError(_endDate, _startDate);
      if (endErr != null) return endErr;
    }
    final nextErr = nextChargeDateError(_nextChargeDate, _startDate);
    if (nextErr != null) return nextErr;
    return null;
  }

  Future<void> _save() async {
    final accounts = ref.read(accountsProvider).asData?.value ?? const [];
    final account = accounts.cast<AccountVm?>().firstWhere(
      (a) => a!.id == _paymentAccountId,
      orElse: () => null,
    );
    final err = _validate(account);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(subscriptionRepositoryProvider);
    final amount = Money(amount: _amount.text.trim(), currency: _currency);
    final cycle = SubscriptionBillingCycleVm(
      unit: _billingUnit,
      interval: int.parse(_billingInterval.text.trim()),
    );
    final duration = _termMode == _TermMode.duration
        ? SubscriptionDurationVm(
            unit: _durationUnit,
            count: int.parse(_durationCount.text.trim()),
          )
        : null;
    final endDate = _termMode == _TermMode.endDate ? _endDate : null;
    final planName = _planName.text.trim().isEmpty
        ? null
        : _planName.text.trim();
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final reminder = int.parse(_reminderDays.text.trim());

    try {
      if (_isEdit) {
        await repo.updateSubscription(
          widget.existing!.id,
          UpdateSubscriptionInput(
            displayName: _displayName.text.trim(),
            provider: _provider.text.trim(),
            planName: planName,
            amount: amount,
            paymentAccountId: _paymentAccountId!,
            billingCycle: cycle,
            startDate: _startDate,
            nextChargeDate: _nextChargeDate,
            duration: duration,
            endDate: endDate,
            autoRenew: _autoRenew,
            reminderDaysBefore: reminder,
            status: widget.existing!.status, // 状态不在本表单改，透传保留
            note: note,
          ),
        );
        ref.refreshSubscriptions(id: widget.existing!.id);
      } else {
        await repo.createSubscription(
          CreateSubscriptionInput(
            displayName: _displayName.text.trim(),
            provider: _provider.text.trim(),
            planName: planName,
            amount: amount,
            paymentAccountId: _paymentAccountId!,
            billingCycle: cycle,
            startDate: _startDate,
            nextChargeDate: _nextChargeDate,
            duration: duration,
            endDate: endDate,
            autoRenew: _autoRenew,
            reminderDaysBefore: reminder,
            note: note,
          ),
        );
        ref.refreshSubscriptions();
      }
      messenger.showSnackBar(
        SnackBar(content: Text(_isEdit ? '订阅已更新' : '订阅已创建')),
      );
      if (mounted) router.pop();
    } on ApiValidationException catch (e) {
      // 服务端字段校验：nextChargeDate 冲突转成中文，不暴露 wire 字段。
      final message = e.userMessage.contains('nextChargeDate')
          ? '下次扣费日不能早于订阅开始日期'
          : '未通过校验：${e.userMessage}';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      // 网络/服务端失败：保留表单内容，允许重试（同一逻辑请求复用原幂等键）。
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 日期选择字段：只在本地日历层面取 YYYY-MM-DD，绝不经 UTC 转换。
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
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) onPick(isoDateOf(picked));
            },
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: const Text('选择'),
          ),
        ],
      ),
    );
  }
}
