// Wealth Ledger — 持仓导入 / 数量校准弹窗。
// 提交后生成待确认调整（进 AI 审核），确认前不改持仓；目标数量可为 0（清零）。
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
import '../theme/app_dimens.dart';
import 'account_form_validation.dart' show targetQuantityError;

const Key kHoldingAdjustmentInstrumentFieldKey = Key(
  'holding_adjustment_instrument_field',
);

/// 打开持仓校准弹窗。[existing] 非空 = 校准该持仓；空 = 添加新资产。
Future<void> showHoldingAdjustmentDialog(
  BuildContext context, {
  required AccountVm account,
  HoldingVm? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => HoldingAdjustmentDialog(account: account, existing: existing),
);

class HoldingAdjustmentDialog extends ConsumerStatefulWidget {
  const HoldingAdjustmentDialog({
    super.key,
    required this.account,
    this.existing,
  });

  final AccountVm account;
  final HoldingVm? existing;

  @override
  ConsumerState<HoldingAdjustmentDialog> createState() =>
      _HoldingAdjustmentDialogState();
}

class _HoldingAdjustmentDialogState
    extends ConsumerState<HoldingAdjustmentDialog> {
  late final _quantity = TextEditingController(
    text: widget.existing?.quantity ?? '',
  );
  final _note = TextEditingController();
  InstrumentVm? _instrument;
  bool _busy = false;

  bool get _isCalibrate => widget.existing != null;

  @override
  void dispose() {
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  String? get _quantityError => targetQuantityError(_quantity.text);

  Id? get _instrumentId =>
      _isCalibrate ? widget.existing!.instrumentId : _instrument?.id;

  /// 新资产的报价币种必须被账户支持（服务端硬校验，前端先拦）。
  String? get _currencyError {
    final inst = _instrument;
    if (_isCalibrate || inst == null) return null;
    final supported = widget.account.supportedCurrencies;
    if (supported.isNotEmpty && !supported.contains(inst.quoteCurrency)) {
      return '该账户不支持此资产的报价币种（${inst.quoteCurrency}）';
    }
    return null;
  }

  bool get _canSubmit =>
      !_busy &&
      _instrumentId != null &&
      _instrumentId!.isNotEmpty &&
      _quantityError == null &&
      _currencyError == null;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(portfolioRepositoryProvider)
          .proposeHoldingAdjustment(
            widget.account.id,
            HoldingAdjustmentInput(
              instrumentId: _instrumentId!,
              targetQuantity: _quantity.text.trim(),
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('已加入待确认'),
          action: SnackBarAction(
            label: '前往审核',
            onPressed: () => router.push('/ai-review'),
          ),
        ),
      );
      navigator.pop();
    } on ApiConflictException {
      // 已有待确认调整或数据已变化：不伪造成功，提供重新加载。
      messenger.showSnackBar(
        SnackBar(
          content: const Text('数据已发生变化或已有待确认调整，请重新加载后再试'),
          action: SnackBarAction(
            label: '重新加载',
            onPressed: () {
              ref.invalidate(holdingsByAccountProvider(widget.account.id));
              ref.invalidate(holdingsProvider);
              ref.invalidate(aiPendingProvider);
            },
          ),
        ),
      );
    } on ApiValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('未通过校验：${e.userMessage}')));
    } catch (e) {
      final isNetwork = e is SocketException || e is ClientException;
      messenger.showSnackBar(
        SnackBar(content: Text(isNetwork ? '网络连接失败，请稍后重试' : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _instrumentField() {
    final instrumentsAsync = ref.watch(instrumentsProvider);
    if (instrumentsAsync.isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.sm),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (instrumentsAsync.hasError) {
      return Row(
        children: [
          const Expanded(child: Text('资产列表加载失败')),
          OutlinedButton(
            onPressed: () => ref.invalidate(instrumentsProvider),
            child: const Text('重试'),
          ),
        ],
      );
    }
    final instruments = instrumentsAsync.value ?? const <InstrumentVm>[];
    if (instruments.isEmpty) {
      return const Text('还没有可选资产，请先在投资页添加标的。');
    }
    return DropdownButtonFormField<InstrumentVm>(
      key: kHoldingAdjustmentInstrumentFieldKey,
      initialValue: _instrument,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '资产',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final i in instruments)
          DropdownMenuItem(
            value: i,
            child: Text(
              i.symbol == null || i.symbol!.isEmpty
                  ? '${i.displayName}（${i.quoteCurrency}）'
                  : '${i.displayName} · ${i.symbol}（${i.quoteCurrency}）',
            ),
          ),
      ],
      onChanged: (v) => setState(() => _instrument = v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final currencyError = _currencyError;
    return AlertDialog(
      title: Text(_isCalibrate ? '校准持仓' : '添加资产'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (existing != null) ...[
              Text(
                '${existing.displayName} · ${existing.symbol} · '
                '当前 ${existing.quantity}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.base),
            ] else ...[
              _instrumentField(),
              if (currencyError != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    currencyError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.base),
            ],
            TextField(
              controller: _quantity,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '目标数量',
                hintText: '当前实际持有的数量；0 表示清零',
                border: const OutlineInputBorder(),
                errorText: _quantity.text.isEmpty ? null : _quantityError,
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(_busy ? '提交中…' : '提交'),
        ),
      ],
    );
  }
}
