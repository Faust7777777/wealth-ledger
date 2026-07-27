// Wealth Ledger — 持仓详情的固定收益区块。
// 本金/应计利息/状态/截至日期全部来自 GET /v1/yield-positions（服务端权威），
// 前端不重算收益；「记录利息」只生成待确认候选。
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show ClientException;

import '../core/format.dart';
import '../data/api_mock_repositories.dart'
    show ApiConflictException, ApiValidationException;
import '../data/providers.dart';
import '../data/view_models.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'yield_terms_page.dart' show yieldFrequencyLabel;
import 'yield_terms_validation.dart' show wireRateToPercent;

/// 持仓行下的收益区：未配置时只有低强调「收益条款」入口；
/// 已配置时展示条款与服务端应计结果。
class YieldSection extends ConsumerWidget {
  const YieldSection({super.key, required this.holding});
  final HoldingVm holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions =
        ref.watch(yieldPositionsProvider).asData?.value ?? const [];
    YieldPositionVm? position;
    for (final p in positions) {
      if (p.holdingId == holding.id) position = p;
    }
    final canWrite = ref.writeCapabilities.canCreateAccount;

    if (position == null) {
      // 低强调入口；positions 加载中/失败不阻塞持仓主体。
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: canWrite
              ? () => context.push('/holding/${holding.id}/yield-terms')
              : null,
          icon: const Icon(Icons.percent, size: 18),
          label: const Text('收益条款'),
        ),
      );
    }

    final terms = position.terms;
    final pending = terms.hasPendingInterest;
    final canPropose = ref.writeCapabilities.canPersistPendingProposal;
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.base,
        bottom: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  position.status == YieldPositionStatus.matured
                      ? '收益条款 · 已到期'
                      : '收益条款',
                  style: AppType.bodyStrong,
                ),
              ),
              TextButton(
                onPressed: canWrite && !pending
                    ? () => context.push('/holding/${holding.id}/yield-terms')
                    : null,
                child: const Text('编辑'),
              ),
            ],
          ),
          _kv('本金', formatMoney(terms.principal)),
          _kv(
            '年利率',
            '${wireRateToPercent(terms.annualRate)}% · '
                '${terms.interestMethod == YieldInterestMethod.simple ? '单利' : '复利 ${yieldFrequencyLabel(terms.compoundingFrequency)}'} · '
                '${terms.dayCountBasis} 天',
          ),
          _kv('起息日', terms.interestStartDate),
          _kv('到期日', terms.maturityDate),
          _kv(
            '应计利息（截至 ${position.accruedThrough}）',
            formatMoney(position.accruedInterest),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              OutlinedButton(
                onPressed: canPropose && !pending
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            _RecordYieldInterestDialog(position: position!),
                      )
                    : null,
                child: const Text('记录利息'),
              ),
              if (pending) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '已有待确认利息'
                    '${terms.pendingInterestThroughDate == null ? '' : '（截至 ${terms.pendingInterestThroughDate}）'}',
                    style: AppType.caption,
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/ai-review'),
                  child: const Text('前往审核'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
    child: Row(
      children: [
        Expanded(child: Text(k, style: AppType.body)),
        Text(v, style: AppType.moneyRow),
      ],
    ),
  );
}

/// 记录利息：选定截止日期（默认今天）生成待确认候选。
class _RecordYieldInterestDialog extends ConsumerStatefulWidget {
  const _RecordYieldInterestDialog({required this.position});
  final YieldPositionVm position;

  @override
  ConsumerState<_RecordYieldInterestDialog> createState() =>
      _RecordYieldInterestDialogState();
}

class _RecordYieldInterestDialogState
    extends ConsumerState<_RecordYieldInterestDialog> {
  final _note = TextEditingController();
  late String _throughDate = _todayIsoDate();
  bool _busy = false;

  static String _todayIsoDate() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(yieldRepositoryProvider)
          .proposeInterest(
            widget.position.holdingId,
            throughDate: _throughDate,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(yieldPositionsProvider);
      ref.invalidate(holdingsProvider);
      ref.invalidate(accountsProvider);
      ref.invalidate(recentMovementsProvider);
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
      messenger.showSnackBar(
        SnackBar(
          content: const Text('数据已发生变化或已有待确认利息，请重新加载后再试'),
          action: SnackBarAction(
            label: '重新加载',
            onPressed: () => ref.invalidate(yieldPositionsProvider),
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('记录利息'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '计息截止日期',
                border: OutlineInputBorder(),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(_throughDate)),
                  TextButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            DateTime.tryParse(_throughDate) ?? DateTime.now(),
                        firstDate: DateTime(1990),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        String two(int n) => n.toString().padLeft(2, '0');
                        setState(() {
                          _throughDate =
                              '${picked.year}-${two(picked.month)}-${two(picked.day)}';
                        });
                      }
                    },
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: const Text('选择'),
                  ),
                ],
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
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '提交中…' : '提交'),
        ),
      ],
    );
  }
}
