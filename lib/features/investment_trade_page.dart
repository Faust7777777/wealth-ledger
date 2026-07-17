// Wealth Ledger — 手动投资成交（买入/卖出；写真实账本，仅 local_server）。
// 候选 → 确认：确认摘要后走「草稿 → 复核 → 入账」流水线；不下单、不连券商。
// 是否已入账只凭服务端 ledgerWrite；金额与数量全程十进制字符串，不经 double。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import 'investment_trade_validation.dart';

const Key kTradeCashAccountFieldKey = Key('trade_cash_account_field');
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
  final _date = TextEditingController();
  final _title = TextEditingController();
  final _note = TextEditingController();

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
    _date.dispose();
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
  String? get _dateError => occurredDateError(_date.text);

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
      _dateError == null &&
      _sellCrossError == null &&
      _title.text.trim().isNotEmpty;

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

  /// 卖出可选标的：所选持仓账户中数量 > 0 的实际持仓（按 instrumentId 关联标的）。
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

  // —— 选择弹窗（受限尺寸，不占满桌面）——
  Future<T?> _showPicker<T>({
    required String title,
    required List<Widget> Function(BuildContext dialogCtx) tiles,
    Widget? footer,
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
          if (footer != null)
            Align(alignment: Alignment.centerLeft, child: footer),
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

  Future<void> _pickBuyInstrument(List<InstrumentVm> instruments) async {
    final picked = await _showPicker<InstrumentVm>(
      title: '选择投资标的',
      tiles: (dialogCtx) => [
        if (instruments.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.base),
            child: Text('还没有投资标的，先添加一个。'),
          ),
        for (final i in instruments)
          ListTile(
            title: Text(_instrumentLabel(i)),
            subtitle: Text(
              '${_instrumentTypeLabel(i.type)} · ${i.quoteCurrency}',
            ),
            onTap: () => Navigator.pop(dialogCtx, i),
          ),
      ],
      footer: Builder(
        builder: (footerCtx) => TextButton.icon(
          onPressed: () async {
            final created = await _createInstrument();
            if (created != null && footerCtx.mounted) {
              Navigator.pop(footerCtx, created);
            }
          },
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加标的'),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _instrument = picked;
      _heldQuantity = null;
    });
  }

  Future<void> _pickSellInstrument(
    List<(HoldingVm, InstrumentVm)> sellable,
  ) async {
    final picked = await _showPicker<(HoldingVm, InstrumentVm)>(
      title: '选择卖出标的',
      tiles: (dialogCtx) => [
        if (sellable.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.base),
            child: Text('该持仓账户暂无可卖出的持仓。'),
          ),
        for (final entry in sellable)
          ListTile(
            title: Text(_instrumentLabel(entry.$2)),
            subtitle: Text('持有 ${entry.$1.quantity}'),
            onTap: () => Navigator.pop(dialogCtx, entry),
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      _instrument = picked.$2;
      _heldQuantity = picked.$1.quantity;
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

  /// 成交时间：空 → null（服务端取当前时间）；填了按本地正午换算 UTC 瞬时，
  /// 避免时区把日期挪走。
  IsoDateTime? _occurredAtIso() {
    final s = _date.text.trim();
    if (s.isEmpty) return null;
    final d = DateTime.parse(s);
    return DateTime(d.year, d.month, d.day, 12).toUtc().toIso8601String();
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
              title: _title.text.trim(),
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      // 只凭服务端 ledgerWrite 决定"已入账"，不猜测。
      ref.refreshAfterInvestmentTrade(
        result,
        holdingAccountId: holdingAccount.id,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(result.ledgerWrite ? '已入账' : '已提交候选，尚未入账')),
      );
      if (mounted) router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final instruments =
        ref.watch(instrumentsProvider).asData?.value ?? const <InstrumentVm>[];
    return Scaffold(
      appBar: AppBar(title: const Text('投资成交')),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorStateView(
          message: '$e',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (accounts) => _form(context, accounts, instruments),
      ),
    );
  }

  Widget _form(
    BuildContext context,
    List<AccountVm> accounts,
    List<InstrumentVm> instruments,
  ) {
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

    // 卖出：所选账户的正数量持仓（provider family 只在选定账户后 watch）。
    var sellable = const <(HoldingVm, InstrumentVm)>[];
    if (!_isBuy && holdingAccount != null) {
      final holdings =
          ref
              .watch(holdingsByAccountProvider(holdingAccount.id))
              .asData
              ?.value ??
          const <HoldingVm>[];
      sellable = _sellableHoldings(holdings, instruments);
    }

    final crossError = _sellCrossError;
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
              onTap: !_isBuy && holdingAccount == null
                  ? null
                  : () => _isBuy
                        ? _pickBuyInstrument(instruments)
                        : _pickSellInstrument(sellable),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
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
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _principal,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: _principalLabel,
                      border: const OutlineInputBorder(),
                      errorText: _principal.text.isEmpty
                          ? null
                          : _principalError,
                    ),
                  ),
                ),
              ],
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
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
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
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
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _date,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '成交时间（可选）',
                hintText: 'YYYY-MM-DD，留空为当前时间',
                border: const OutlineInputBorder(),
                errorText: _date.text.isEmpty ? null : _dateError,
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _title,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '摘要',
                hintText: _isBuy ? '例如：买入 沪深300ETF' : '例如：卖出 沪深300ETF',
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
              onPressed: _canSubmit ? () => _submit(accounts) : null,
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
