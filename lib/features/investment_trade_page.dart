// Wealth Ledger — 手动投资成交（买入/卖出；写真实账本，仅 local_server）。
// 候选 → 确认：确认摘要后走「草稿 → 复核 → 入账」流水线；不下单、不连券商。
// 是否已入账只凭服务端 ledgerWrite；金额与数量全程十进制字符串，不经 double。
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show ClientException;

import '../core/format.dart';
import '../data/api_mock_repositories.dart'
    show ApiConflictException, ApiForbiddenException, ApiValidationException;
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'investment_trade_validation.dart';

const Key kTradeCashAccountFieldKey = Key('trade_cash_account_field');
const Key kTradeOccurredAtFieldKey = Key('trade_occurred_at_field');
const Key kTradeHoldingAccountFieldKey = Key('trade_holding_account_field');
const Key kTradeInstrumentFieldKey = Key('trade_instrument_field');
const Key kTradeCashCurrencyFieldKey = Key('trade_cash_currency_field');
const Key kTradeConfirmDialogKey = Key('trade_confirm_dialog');

/// 桌面上表单主体的最大宽度（任务约束 680–760）。
const double kTradeFormMaxWidth = 720;

String _instrumentTypeLabel(InstrumentType t) => switch (t) {
  InstrumentType.cash => '现金',
  InstrumentType.equity => '股票',
  InstrumentType.fund => '基金',
  InstrumentType.crypto => '加密资产',
  InstrumentType.fxCash => '外汇现金',
  InstrumentType.receivable => '应收款',
  InstrumentType.other => '其他',
};

String _instrumentLabel(InstrumentVm i) {
  final symbol = i.symbol;
  return symbol == null || symbol.isEmpty
      ? i.displayName
      : '${i.displayName} · $symbol';
}

class InvestmentTradePage extends ConsumerStatefulWidget {
  const InvestmentTradePage({super.key});

  @override
  ConsumerState<InvestmentTradePage> createState() =>
      _InvestmentTradePageState();
}

class _InvestmentTradePageState extends ConsumerState<InvestmentTradePage> {
  final _quantity = TextEditingController();
  final _principal = TextEditingController();
  final _fee = TextEditingController();
  final _tax = TextEditingController();
  final _title = TextEditingController();
  final _note = TextEditingController();

  /// 成交时间：null = 现在（请求省略该字段，由服务端取当前时间）。
  DateTime? _occurredAt;

  TradeSide _side = TradeSide.buy;
  Id? _cashAccountId;
  Id? _holdingAccountId;
  CurrencyCode? _cashCurrency;
  InstrumentVm? _instrument;

  /// 卖出时所选标的在所选持仓账户内的当前数量（用于上限校验与摘要）。
  DecimalString? _heldQuantity;
  bool _busy = false;

  @override
  void dispose() {
    _quantity.dispose();
    _principal.dispose();
    _fee.dispose();
    _tax.dispose();
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _isBuy => _side == TradeSide.buy;
  String get _principalLabel => _isBuy ? '成交价款' : '卖出毛回款';

  // —— 校验（全部字符串定点，不经 double）——
  String? get _quantityError => requiredDecimalError(_quantity.text, '成交数量');
  String? get _principalError =>
      requiredDecimalError(_principal.text, _principalLabel);
  String? get _feeError => optionalNonNegativeError(_fee.text, '手续费');
  String? get _taxError => optionalNonNegativeError(_tax.text, '税费');

  /// 摘要留空时自动生成（“买入/卖出 <标的名称>”），用户可覆盖。
  String get _autoTitle {
    final inst = _instrument;
    if (inst == null) return '';
    return '${_isBuy ? '买入' : '卖出'} ${inst.displayName}';
  }

  /// 卖出跨字段校验：费用不超毛回款、数量不超持仓。
  String? get _sellCrossError {
    if (_isBuy) return null;
    if (_principalError == null && _feeError == null && _taxError == null) {
      final feeTax = sellFeeTaxError(
        grossProceeds: _principal.text,
        fee: _fee.text,
        tax: _tax.text,
      );
      if (feeTax != null) return feeTax;
    }
    final held = _heldQuantity;
    if (_quantityError == null && held != null) {
      return sellQuantityError(quantity: _quantity.text, heldQuantity: held);
    }
    return null;
  }

  /// 买入：持仓腿币种=标的报价币种，必须在所选持仓账户支持币种内（服务端硬校验）。
  String? _buyInstrumentCurrencyError(AccountVm? holdingAccount) {
    final inst = _instrument;
    if (!_isBuy || holdingAccount == null || inst == null) return null;
    final supported = holdingAccount.supportedCurrencies;
    if (supported.isNotEmpty && !supported.contains(inst.quoteCurrency)) {
      return '持仓账户不支持该标的的报价币种（${inst.quoteCurrency}），请换持仓账户或标的';
    }
    return null;
  }

  bool get _canSubmit =>
      !_busy &&
      ref.writeCapabilities.canRecordMovement &&
      _cashAccountId != null &&
      _holdingAccountId != null &&
      _instrument != null &&
      _cashCurrency != null &&
      _quantityError == null &&
      _principalError == null &&
      _feeError == null &&
      _taxError == null &&
      _sellCrossError == null;

  // —— 账户/标的选择规则（任务 §7）——
  List<AccountVm> _cashAccounts(List<AccountVm> accounts) => [
    for (final a in accounts)
      if (!a.isArchived &&
          (a.balanceMode == 'cash_balance' || a.balanceMode == 'mixed'))
        a,
  ];

  List<AccountVm> _holdingAccounts(List<AccountVm> accounts) => [
    for (final a in accounts)
      if (!a.isArchived &&
          (a.balanceMode == 'holdings' || a.balanceMode == 'mixed'))
        a,
  ];

  AccountVm? _byId(List<AccountVm> accounts, Id? id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  List<CurrencyCode> _currencyOptions(AccountVm? cashAccount) {
    if (cashAccount == null) return const ['CNY'];
    final options = <CurrencyCode>{
      ...cashAccount.supportedCurrencies,
      if (cashAccount.supportedCurrencies.isEmpty) cashAccount.defaultCurrency,
      ?_cashCurrency,
    };
    return options.toList();
  }

  // —— 选择弹窗（受限尺寸，不占满桌面）——
  Future<T?> _showPicker<T>({
    required String title,
    required List<Widget> Function(BuildContext dialogCtx) tiles,
  }) {
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      240.0,
      460.0,
    );
    return showDialog<T>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: tiles(dialogCtx),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCashAccount(List<AccountVm> accounts) async {
    final picked = await _showPicker<AccountVm>(
      title: '选择资金账户',
      tiles: (dialogCtx) => [
        for (final a in accounts)
          ListTile(
            title: Text(a.displayName),
            subtitle: Text(a.defaultCurrency),
            onTap: () => Navigator.pop(dialogCtx, a),
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      _cashAccountId = picked.id;
      // 成交币种跟随账户默认币种（仍可在其支持币种内更改）。
      _cashCurrency = picked.defaultCurrency;
    });
  }

  Future<void> _pickHoldingAccount(List<AccountVm> accounts) async {
    final picked = await _showPicker<AccountVm>(
      title: '选择持仓账户',
      tiles: (dialogCtx) => [
        for (final a in accounts)
          ListTile(
            title: Text(a.displayName),
            subtitle: Text(a.defaultCurrency),
            onTap: () => Navigator.pop(dialogCtx, a),
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      if (picked.id != _holdingAccountId && !_isBuy) {
        // 换账户后原标的可能不在新账户持仓内，重选。
        _instrument = null;
        _heldQuantity = null;
      }
      _holdingAccountId = picked.id;
    });
  }

  /// 标的选择：买入从服务端标的中选（可新建）；卖出只从所选账户正数量持仓中选。
  /// 加载/失败/重试三态由弹窗内部处理。
  Future<void> _pickInstrument() async {
    final sellAccountId = _isBuy ? null : _holdingAccountId;
    final picked = await showDialog<Object>(
      context: context,
      builder: (_) => _InstrumentPickerDialog(
        sellAccountId: sellAccountId,
        onCreate: _isBuy ? _createInstrument : null,
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (picked is InstrumentVm) {
        _instrument = picked;
        _heldQuantity = null;
      } else if (picked is (HoldingVm, InstrumentVm)) {
        _instrument = picked.$2;
        _heldQuantity = picked.$1.quantity;
      }
    });
  }

  /// 紧凑「添加标的」弹窗：仅登记标的（POST /v1/instruments），不连行情。
  Future<InstrumentVm?> _createInstrument() async {
    final name = TextEditingController();
    final symbol = TextEditingController();
    var type = InstrumentType.fund;
    var currency = _cashCurrency ?? 'CNY';
    try {
      final input = await showDialog<CreateInstrumentInput>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (dialogCtx, setDialogState) => AlertDialog(
            title: const Text('添加标的'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: '标的名称',
                      hintText: '例如：沪深300ETF',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.base),
                  TextField(
                    controller: symbol,
                    decoration: const InputDecoration(
                      labelText: '代码（可选）',
                      hintText: '例如：510300',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.base),
                  DropdownButtonFormField<InstrumentType>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final t in InstrumentType.values)
                        DropdownMenuItem(
                          value: t,
                          child: Text(_instrumentTypeLabel(t)),
                        ),
                    ],
                    onChanged: (v) => setDialogState(() => type = v ?? type),
                  ),
                  const SizedBox(height: AppSpacing.base),
                  DropdownButtonFormField<CurrencyCode>(
                    initialValue: currency,
                    decoration: const InputDecoration(
                      labelText: '报价币种',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final c in {
                        'CNY',
                        'USD',
                        'HKD',
                        'USDT',
                        'BTC',
                        'ETH',
                        currency,
                      })
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => currency = v ?? currency),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: name.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(
                        dialogCtx,
                        CreateInstrumentInput(
                          type: type,
                          displayName: name.text.trim(),
                          quoteCurrency: currency,
                          symbol: symbol.text.trim().isEmpty
                              ? null
                              : symbol.text.trim(),
                        ),
                      ),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (input == null || !mounted) return null;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final created = await ref
            .read(instrumentRepositoryProvider)
            .createInstrument(input);
        ref.invalidate(instrumentsProvider);
        return created;
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
        return null;
      }
    } finally {
      name.dispose();
      symbol.dispose();
    }
  }

  /// 成交时间：界面显示本地时间；请求转换为 RFC3339 UTC。
  /// 未修改（null）时省略该字段，由服务端取当前时间。
  IsoDateTime? _occurredAtIso() => _occurredAt?.toUtc().toIso8601String();

  String _formatLocal(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 日期 + 时间选择器（本地时区）。
  Future<void> _pickOccurredAt() async {
    final now = DateTime.now();
    final initial = _occurredAt ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    setState(() {
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _submit(List<AccountVm> accounts) async {
    if (!_canSubmit) return;
    final cashAccount = _byId(accounts, _cashAccountId)!;
    final holdingAccount = _byId(accounts, _holdingAccountId)!;
    final instrument = _instrument!;
    final currency = _cashCurrency!;
    final quantity = _quantity.text.trim();
    final principal = _principal.text.trim();
    final fee = _fee.text.trim();
    final tax = _tax.text.trim();
    String money(String amount) =>
        formatMoney(Money(amount: amount, currency: currency), withCode: true);
    final cashTotal = _isBuy
        ? buyTotalCashOut(principal: principal, fee: fee, tax: tax)
        : sellNetCashIn(gross: principal, fee: fee, tax: tax);

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        key: kTradeConfirmDialogKey,
        title: Text(_isBuy ? '确认买入' : '确认卖出'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_instrumentLabel(instrument)} · ${holdingAccount.displayName}',
              ),
              const SizedBox(height: AppSpacing.sm),
              _summaryRow(_principalLabel, money(principal)),
              _summaryRow('手续费', fee.isEmpty ? '—' : money(fee)),
              _summaryRow('税费', tax.isEmpty ? '—' : money(tax)),
              _summaryRow(
                _isBuy ? '现金合计支出' : '现金净入账',
                '${money(cashTotal)}（${cashAccount.displayName}）',
              ),
              _summaryRow('成交数量', quantity),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('再改改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(_isBuy ? '确认买入' : '确认卖出'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final result = await ref
          .read(movementRepositoryProvider)
          .createInvestmentTrade(
            InvestmentTradeInput(
              side: _side,
              cashAccountId: cashAccount.id,
              holdingAccountId: holdingAccount.id,
              instrumentId: instrument.id,
              quantity: quantity,
              principalAmount: principal,
              cashCurrency: currency,
              holdingCurrency: instrument.quoteCurrency,
              feeAmount: fee.isEmpty ? null : fee,
              taxAmount: tax.isEmpty ? null : tax,
              occurredAt: _occurredAtIso(),
              title: _title.text.trim().isEmpty
                  ? _autoTitle
                  : _title.text.trim(),
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      // 只凭服务端 ledgerWrite 决定"已入账"，不猜测。
      ref.refreshAfterInvestmentTrade(
        result,
        holdingAccountId: holdingAccount.id,
      );
      if (result.ledgerWrite) {
        messenger.showSnackBar(const SnackBar(content: Text('已入账')));
        if (mounted) router.pop();
      } else {
        // 未真正写入账本：留在表单，引导去审核确认，不表现为已完成。
        messenger.showSnackBar(
          SnackBar(
            content: const Text('已加入待确认，尚未入账'),
            action: SnackBarAction(
              label: '前往审核',
              onPressed: () => router.push('/ai-review'),
            ),
          ),
        );
      }
    } on ApiValidationException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('记录未通过校验：${e.userMessage}')),
      );
    } on ApiForbiddenException {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前账号没有记账权限，请重新登录后再试')),
      );
    } on ApiConflictException {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('数据已发生变化，请重新加载后再试'),
          action: SnackBarAction(label: '重新加载', onPressed: _reloadInputs),
        ),
      );
    } catch (e) {
      final isNetwork = e is SocketException || e is ClientException;
      messenger.showSnackBar(
        SnackBar(content: Text(isNetwork ? '网络连接失败，表单已保留，请稍后重试' : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 409 后的恢复：重取账户、标的与持仓（表单输入保留）。
  void _reloadInputs() {
    ref.invalidate(accountsProvider);
    ref.invalidate(instrumentsProvider);
    final id = _holdingAccountId;
    if (id != null) ref.invalidate(holdingsByAccountProvider(id));
  }

  Widget _summaryRow(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(k)),
        Flexible(child: Text(v, textAlign: TextAlign.end)),
      ],
    ),
  );

  Widget _pickerField({
    required Key key,
    required String label,
    required String? value,
    required String emptyHint,
    required VoidCallback? onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
      child: Text(
        value ?? emptyHint,
        style: value == null
            ? TextStyle(color: Theme.of(context).hintColor)
            : null,
      ),
    ),
  );

  /// 窄屏（<480 逻辑宽）纵向排列成对字段；宽屏并列两列，校验文案互不挤压。
  Widget _pairFields(Widget a, Widget b, {int flexA = 1, int flexB = 1}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 480) {
            return Column(
              children: [
                a,
                const SizedBox(height: AppSpacing.base),
                b,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: flexA, child: a),
              const SizedBox(width: AppSpacing.sm),
              Expanded(flex: flexB, child: b),
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('投资成交')),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (accounts) => _form(context, accounts),
      ),
    );
  }

  Widget _form(BuildContext context, List<AccountVm> accounts) {
    final cashAccounts = _cashAccounts(accounts);
    final holdingAccounts = _holdingAccounts(accounts);
    if (cashAccounts.isEmpty || holdingAccounts.isEmpty) {
      return EmptyState(
        icon: Icons.candlestick_chart_outlined,
        title: '先补齐账户',
        message: cashAccounts.isEmpty && holdingAccounts.isEmpty
            ? '记录成交需要一个资金账户（付款/收款）和一个持仓账户（证券/交易所等）。'
            : cashAccounts.isEmpty
            ? '还缺一个可记现金余额的资金账户。'
            : '还缺一个持仓账户（证券账户、交易所等）。',
        action: WriteGate(
          enabled: ref.writeCapabilities.canCreateAccount,
          child: FilledButton(
            onPressed: () => context.push(
              holdingAccounts.isEmpty
                  ? '/accounts/new?type=brokerage'
                  : '/accounts/new',
            ),
            child: const Text('添加账户'),
          ),
        ),
      );
    }

    final cashAccount = _byId(cashAccounts, _cashAccountId);
    final holdingAccount = _byId(holdingAccounts, _holdingAccountId);
    final currencyOptions = _currencyOptions(cashAccount);
    final canRecord = ref.writeCapabilities.canRecordMovement;

    final crossError =
        _sellCrossError ?? _buyInstrumentCurrencyError(holdingAccount);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kTradeFormMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.base),
          children: [
            SegmentedButton<TradeSide>(
              segments: const [
                ButtonSegment(
                  value: TradeSide.buy,
                  label: Text('买入'),
                  icon: Icon(Icons.south_west),
                ),
                ButtonSegment(
                  value: TradeSide.sell,
                  label: Text('卖出'),
                  icon: Icon(Icons.north_east),
                ),
              ],
              selected: {_side},
              onSelectionChanged: (s) => setState(() {
                _side = s.first;
                // 卖出标的必须来自所选账户的实际持仓，切向卖出时重选。
                if (_side == TradeSide.sell) {
                  _instrument = null;
                  _heldQuantity = null;
                }
              }),
            ),
            const SizedBox(height: AppSpacing.base),
            _pickerField(
              key: kTradeCashAccountFieldKey,
              label: '资金账户',
              value: cashAccount?.displayName,
              emptyHint: '选择付款 / 收款账户',
              onTap: () => _pickCashAccount(cashAccounts),
            ),
            const SizedBox(height: AppSpacing.base),
            _pickerField(
              key: kTradeHoldingAccountFieldKey,
              label: '持仓账户',
              value: holdingAccount?.displayName,
              emptyHint: '选择持仓所在账户',
              onTap: () => _pickHoldingAccount(holdingAccounts),
            ),
            const SizedBox(height: AppSpacing.base),
            _pickerField(
              key: kTradeInstrumentFieldKey,
              label: '投资标的',
              value: _instrument == null
                  ? null
                  : _isBuy || _heldQuantity == null
                  ? _instrumentLabel(_instrument!)
                  : '${_instrumentLabel(_instrument!)} · 持有 $_heldQuantity',
              emptyHint: _isBuy ? '选择或添加标的' : '从当前持仓中选择',
              onTap: !_isBuy && holdingAccount == null ? null : _pickInstrument,
            ),
            if (!_isBuy && holdingAccount == null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '先选择持仓账户，再从其持仓中选卖出标的。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: AppSpacing.base),
            _pairFields(
              TextField(
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '成交数量',
                  hintText: '如 10 或 0.5',
                  border: const OutlineInputBorder(),
                  errorText: _quantity.text.isEmpty ? null : _quantityError,
                ),
              ),
              TextField(
                controller: _principal,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _principalLabel,
                  border: const OutlineInputBorder(),
                  errorText: _principal.text.isEmpty ? null : _principalError,
                ),
              ),
              flexA: 2,
              flexB: 3,
            ),
            const SizedBox(height: AppSpacing.base),
            DropdownButtonFormField<CurrencyCode>(
              key: kTradeCashCurrencyFieldKey,
              initialValue: _cashCurrency,
              decoration: const InputDecoration(
                labelText: '成交币种',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in currencyOptions)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => _cashCurrency = v),
            ),
            const SizedBox(height: AppSpacing.base),
            _pairFields(
              TextField(
                controller: _fee,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '手续费（可选）',
                  border: const OutlineInputBorder(),
                  errorText: _fee.text.isEmpty ? null : _feeError,
                ),
              ),
              TextField(
                controller: _tax,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '税费（可选）',
                  border: const OutlineInputBorder(),
                  errorText: _tax.text.isEmpty ? null : _taxError,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            _pickerField(
              key: kTradeOccurredAtFieldKey,
              label: '成交时间',
              value: _occurredAt == null ? '现在' : _formatLocal(_occurredAt!),
              emptyHint: '现在',
              onTap: _pickOccurredAt,
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _title,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '摘要（可选）',
                hintText: _autoTitle.isEmpty
                    ? (_isBuy ? '默认：买入 <标的名称>' : '默认：卖出 <标的名称>')
                    : '默认：$_autoTitle',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            if (crossError != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                crossError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            FilledButton(
              onPressed: _canSubmit && crossError == null
                  ? () => _submit(accounts)
                  : null,
              child: Text(_busy ? '提交中…' : (_isBuy ? '确认买入' : '确认卖出')),
            ),
            if (!canRecord)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  kReadOnlyHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 卖出可选标的：持仓数量 > 0 且能按 instrumentId 关联到标的。
List<(HoldingVm, InstrumentVm)> _sellableHoldings(
  List<HoldingVm> holdings,
  List<InstrumentVm> instruments,
) {
  final byId = {for (final i in instruments) i.id: i};
  return [
    for (final h in holdings)
      if (decimalSign(h.quantity) > 0 && byId.containsKey(h.instrumentId))
        (h, byId[h.instrumentId]!),
  ];
}

/// 标的选择弹窗：内部处理加载 / 失败重试 / 空态；
/// 买入列出服务端全部标的（可新建），卖出只列所选账户的正数量持仓。
class _InstrumentPickerDialog extends ConsumerWidget {
  const _InstrumentPickerDialog({required this.sellAccountId, this.onCreate});

  /// 卖出模式的持仓账户；null = 买入模式。
  final Id? sellAccountId;

  /// 买入模式的「添加标的」入口；创建成功后作为选中项返回。
  final Future<InstrumentVm?> Function()? onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      240.0,
      460.0,
    );
    final instrumentsAsync = ref.watch(instrumentsProvider);
    final holdingsAsync = sellAccountId == null
        ? null
        : ref.watch(holdingsByAccountProvider(sellAccountId!));

    void retry() {
      ref.invalidate(instrumentsProvider);
      if (sellAccountId != null) {
        ref.invalidate(holdingsByAccountProvider(sellAccountId!));
      }
    }

    Widget body;
    if (instrumentsAsync.isLoading || (holdingsAsync?.isLoading ?? false)) {
      body = const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (instrumentsAsync.hasError ||
        (holdingsAsync?.hasError ?? false)) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('标的加载失败，请重试。'),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(onPressed: retry, child: const Text('重试')),
            ),
          ],
        ),
      );
    } else if (sellAccountId == null) {
      final instruments = instrumentsAsync.value ?? const <InstrumentVm>[];
      body = instruments.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.base),
              child: Text('还没有投资标的，先添加一个。'),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final i in instruments)
                  ListTile(
                    title: Text(_instrumentLabel(i)),
                    subtitle: Text(
                      '${_instrumentTypeLabel(i.type)} · ${i.quoteCurrency}',
                    ),
                    onTap: () => Navigator.pop(context, i),
                  ),
              ],
            );
    } else {
      final sellable = _sellableHoldings(
        holdingsAsync!.value ?? const <HoldingVm>[],
        instrumentsAsync.value ?? const <InstrumentVm>[],
      );
      body = sellable.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.base),
              child: Text('该持仓账户暂无可卖出的持仓。'),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in sellable)
                  ListTile(
                    title: Text(_instrumentLabel(entry.$2)),
                    subtitle: Text('持有 ${entry.$1.quantity}'),
                    onTap: () => Navigator.pop(context, entry),
                  ),
              ],
            );
    }

    return AlertDialog(
      title: Text(sellAccountId == null ? '选择投资标的' : '选择卖出标的'),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(child: body),
        ),
      ),
      actions: [
        if (onCreate != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final created = await onCreate!();
                if (created != null && context.mounted) {
                  Navigator.pop(context, created);
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加标的'),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
