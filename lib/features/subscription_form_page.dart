// Wealth Ledger — 订阅表单（新建 POST / 编辑 PATCH；写真实账本，仅 local_server）。
// 客户端只做可用性校验，服务端仍是权威。金额十进制字符串、日期本地日历字符串。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
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
    final e = widget.existing;
    if (e != null) {
      _displayName.text = e.displayName;
      _provider.text = e.provider;
      _planName.text = e.planName ?? '';
      _amount.text = e.amount.amount;
      _currency = e.amount.currency;
      _paymentAccountId = e.paymentAccountId;
      _startDate = e.startDate;
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
                  '该账户不支持 $_currency，请改用支持该币种的账户（不自动换汇）。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: AppSpacing.base),
            _DateField(
              label: '开始日期',
              value: _startDate,
              onPick: (d) => setState(() => _startDate = d),
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
            const SizedBox(height: AppSpacing.xs),
            Text(
              '月/年周期按自然月锚点：1 月 31 日 → 2 月末 → 3 月 31 日。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.base),
            _termSection(),
            const SizedBox(height: AppSpacing.base),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动续订'),
              subtitle: const Text('仅记录服务商续订偏好，本应用不会自动扣款'),
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
        SegmentedButton<_TermMode>(
          segments: const [
            ButtonSegment(value: _TermMode.none, label: Text('无固定期限')),
            ButtonSegment(value: _TermMode.duration, label: Text('持续时长')),
            ButtonSegment(value: _TermMode.endDate, label: Text('结束日期')),
          ],
          selected: {_termMode},
          onSelectionChanged: (s) => setState(() => _termMode = s.first),
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

  /// 客户端可用性校验：返回首个错误文案，全部通过返回 null。
  String? _validate(AccountVm? account) {
    if (_displayName.text.trim().isEmpty) return '请填写名称';
    if (_provider.text.trim().isEmpty) return '请填写服务商';
    final amountErr = _amountError(_amount.text.trim());
    if (amountErr != null) return amountErr;
    if (_paymentAccountId == null) return '请选择付款账户';
    if (account != null && !_accountSupports(account, _currency)) {
      return '付款账户不支持 $_currency，请改用支持该币种的账户（不自动换汇）';
    }
    final interval = int.tryParse(_billingInterval.text.trim());
    if (interval == null || interval < 1) return '计费周期必须为正整数';
    final reminder = int.tryParse(_reminderDays.text.trim());
    if (reminder == null || reminder < 0) return '提前提醒天数必须为非负整数';
    if (_termMode == _TermMode.duration) {
      final count = int.tryParse(_durationCount.text.trim());
      if (count == null || count < 1) return '持续时长必须为正整数';
    }
    if (_termMode == _TermMode.endDate) {
      if (_endDate == null) return '请选择结束日期';
      if (_endDate!.compareTo(_startDate) <= 0) return '结束日期须晚于开始日期';
    }
    return null;
  }

  /// 金额：正数、最多 8 位小数（纯字符串校验，不经 double）。
  String? _amountError(String raw) {
    if (raw.isEmpty) return '请填写金额';
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(raw)) return '金额格式不正确';
    final dot = raw.indexOf('.');
    if (dot >= 0 && raw.length - dot - 1 > 8) return '金额最多 8 位小数';
    // 正数：去掉所有 0 和小数点后仍有数字即 > 0。
    if (raw.replaceAll(RegExp(r'[0.]'), '').isEmpty) return '金额必须大于 0';
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
