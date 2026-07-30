// Wealth Ledger — 更新持仓（多资产快照）。
// 一次编辑同一账户下多项数量并整批提交；提交只生成一个待确认审核组，
// 确认前不改变持仓与估值。标的一律从服务端列表里选，前端不生成 instrumentId。
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
import '../theme/app_typography.dart';
import 'account_form_validation.dart' show targetQuantityError;

const Key kHoldingSnapshotSubmitKey = Key('holding_snapshot_submit');
const Key kHoldingSnapshotAddKey = Key('holding_snapshot_add');
const Key kHoldingSnapshotSearchKey = Key('holding_snapshot_search');
const Key kHoldingSnapshotRegisterKey = Key('holding_snapshot_register');

Future<void> showHoldingSnapshotDialog(
  BuildContext context, {
  required AccountVm account,
  required List<HoldingVm> holdings,
}) => showDialog<void>(
  context: context,
  builder: (_) => HoldingSnapshotDialog(account: account, holdings: holdings),
);

/// 待提交的一行：已有持仓带 instrumentId，新增行选中标的后才有。
class HoldingSnapshotDraftRow {
  HoldingSnapshotDraftRow({
    required this.instrumentId,
    required this.label,
    required String quantity,
  }) : controller = TextEditingController(text: quantity),
       original = quantity;

  final Id instrumentId;
  final String label;
  final TextEditingController controller;

  /// 打开弹窗时的数量：用于判断哪些行真的改过。
  final String original;
}

/// 只提交真的改过且格式合法的行；全部未改动时返回空列表。
List<HoldingSnapshotPositionInput> holdingSnapshotChanges(
  List<HoldingSnapshotDraftRow> rows,
) => [
  for (final r in rows)
    if (r.instrumentId.isNotEmpty &&
        targetQuantityError(r.controller.text) == null &&
        r.controller.text.trim() != r.original.trim())
      HoldingSnapshotPositionInput(
        instrumentId: r.instrumentId,
        targetQuantity: r.controller.text.trim(),
      ),
];

class HoldingSnapshotDialog extends ConsumerStatefulWidget {
  const HoldingSnapshotDialog({
    super.key,
    required this.account,
    required this.holdings,
  });

  final AccountVm account;
  final List<HoldingVm> holdings;

  @override
  ConsumerState<HoldingSnapshotDialog> createState() =>
      _HoldingSnapshotDialogState();
}

class _HoldingSnapshotDialogState extends ConsumerState<HoldingSnapshotDialog> {
  late final List<HoldingSnapshotDraftRow> _rows = [
    for (final h in widget.holdings)
      if (h.instrumentId.isNotEmpty)
        HoldingSnapshotDraftRow(
          instrumentId: h.instrumentId,
          label: h.symbol.isEmpty
              ? h.displayName
              : '${h.displayName} · ${h.symbol}',
          quantity: h.quantity,
        ),
  ];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final r in _rows) {
      r.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _addInstrument() async {
    final instruments =
        ref.read(instrumentsProvider).asData?.value ?? const <InstrumentVm>[];
    final taken = {for (final r in _rows) r.instrumentId};
    final picked = await showDialog<InstrumentVm>(
      context: context,
      builder: (_) => _InstrumentPicker(
        quoteCurrency: widget.account.defaultCurrency,
        instruments: [
          for (final i in instruments)
            if (!taken.contains(i.id)) i,
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _rows.add(
        HoldingSnapshotDraftRow(
          instrumentId: picked.id,
          label: picked.symbol == null || picked.symbol!.isEmpty
              ? picked.displayName
              : '${picked.displayName} · ${picked.symbol}',
          quantity: '',
        ),
      );
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final invalid = _rows.any(
      (r) => r.controller.text.trim().isNotEmpty
          ? targetQuantityError(r.controller.text) != null
          : false,
    );
    if (invalid) {
      setState(() => _error = '数量需为非负数字');
      return;
    }
    final positions = holdingSnapshotChanges(_rows);
    if (positions.isEmpty) {
      setState(() => _error = '没有数量变化');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(portfolioRepositoryProvider)
          .proposeHoldingSnapshot(widget.account.id, positions: positions);
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      if (!mounted) return;
      // 只说明已进入待确认，不宣称持仓已更新。
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
      // 409：刷新账户持仓与待审核，输入原样保留供重新核对。
      ref.invalidate(holdingsByAccountProvider(widget.account.id));
      ref.invalidate(holdingsProvider);
      ref.invalidate(aiPendingProvider);
      if (mounted) setState(() => _error = '数量已变化或已有待确认调整，请重新核对');
    } on ApiValidationException catch (e) {
      if (mounted) setState(() => _error = '未通过校验：${e.userMessage}');
    } catch (e) {
      final isNetwork = e is SocketException || e is ClientException;
      if (mounted) {
        setState(() => _error = isNetwork ? '网络连接失败，请稍后重试' : '提交失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: const Text('更新持仓'),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * 0.6).clamp(
              200.0,
              520.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _rows)
                      Padding(
                        key: ValueKey(
                          'holding_snapshot_field_${r.instrumentId}',
                        ),
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xs,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.label,
                                style: AppType.body,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: r.controller,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: kHoldingSnapshotAddKey,
                  onPressed: _busy ? null : _addInstrument,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加资产'),
                ),
              ),
              if (error != null)
                Text(
                  error,
                  style: AppType.caption.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: kHoldingSnapshotSubmitKey,
          onPressed: _busy ? null : _submit,
          child: const Text('提交待确认'),
        ),
      ],
    );
  }
}

/// 标的选择：在服务端返回的真实标的里搜索，前端不生成 instrumentId。
class _InstrumentPicker extends ConsumerStatefulWidget {
  const _InstrumentPicker({
    required this.instruments,
    required this.quoteCurrency,
  });
  final List<InstrumentVm> instruments;

  /// 登记新资产时的默认计价单位：取账户折算单位。
  final CurrencyCode quoteCurrency;

  @override
  ConsumerState<_InstrumentPicker> createState() => _InstrumentPickerState();
}

class _InstrumentPickerState extends ConsumerState<_InstrumentPicker> {
  String _query = '';
  bool _registering = false;
  String? _registerError;

  /// 登记资产：由服务端创建标的并回传真实 id，前端不生成 instrumentId、
  /// 也不在失败时假装成功。
  Future<void> _register() async {
    final symbol = _query.trim().toUpperCase();
    if (symbol.isEmpty || _registering) return;
    setState(() {
      _registering = true;
      _registerError = null;
    });
    try {
      final created = await ref
          .read(instrumentRepositoryProvider)
          .createInstrument(
            CreateInstrumentInput(
              type: InstrumentType.crypto,
              displayName: symbol,
              quoteCurrency: widget.quoteCurrency,
              symbol: symbol,
            ),
          );
      ref.invalidate(instrumentsProvider);
      if (mounted) Navigator.of(context).pop(created);
    } catch (_) {
      if (mounted) {
        setState(() {
          _registerError = '登记未成功，请重试';
          _registering = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = [
      for (final i in widget.instruments)
        if (query.isEmpty ||
            i.displayName.toLowerCase().contains(query) ||
            (i.symbol ?? '').toLowerCase().contains(query))
          i,
    ];
    return AlertDialog(
      title: const Text('选择资产'),
      content: SizedBox(
        width: 380,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: kHoldingSnapshotSearchKey,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索名称或代码',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: AppSpacing.sm),
              Flexible(
                child: matches.isEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('没有匹配的资产', style: AppType.caption),
                          if (_query.trim().isNotEmpty)
                            TextButton(
                              key: kHoldingSnapshotRegisterKey,
                              onPressed: _registering ? null : _register,
                              child: Text(
                                _registering
                                    ? '登记中…'
                                    : '登记 ${_query.trim().toUpperCase()}',
                              ),
                            ),
                          if (_registerError != null)
                            Text(
                              _registerError!,
                              style: AppType.caption.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final i in matches)
                            ListTile(
                              key: ValueKey('instrument_option_${i.id}'),
                              dense: true,
                              title: Text(
                                i.symbol == null || i.symbol!.isEmpty
                                    ? i.displayName
                                    : '${i.displayName} · ${i.symbol}',
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(i.quoteCurrency),
                              onTap: () => Navigator.of(context).pop(i),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
