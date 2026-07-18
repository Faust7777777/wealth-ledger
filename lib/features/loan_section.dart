// Wealth Ledger — 账户详情的贷款区块。
// 剩余债务/应计利息/下一期拆分全部来自 GET /v1/liability-positions（服务端权威），
// 「记录利息」只生成待确认候选；还款计划为服务端有界投影，按需分页。
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
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// 负债账户详情的贷款区：未配置时只有低强调「贷款条款」入口；
/// 已配置时展示头寸与还款计划。
class LoanSection extends ConsumerWidget {
  const LoanSection({super.key, required this.account});
  final AccountVm account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionsAsync = ref.watch(liabilityPositionsProvider);
    final positions = positionsAsync.asData?.value ?? const [];
    LiabilityPositionVm? position;
    for (final p in positions) {
      if (p.accountId == account.id) position = p;
    }
    final canWrite = ref.writeCapabilities.canCreateAccount;

    if (position == null) {
      // 低强调入口；positions 加载中/失败不阻塞详情主体。
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: canWrite
              ? () => context.push('/account/${account.id}/liability-terms')
              : null,
          icon: const Icon(Icons.percent, size: 18),
          label: const Text('贷款条款'),
        ),
      );
    }

    final terms = position.terms;
    final pending = terms.hasPendingInterest;
    final canPropose = ref.writeCapabilities.canPersistPendingProposal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: '贷款',
          trailing: TextButton(
            onPressed: canWrite && !pending
                ? () => context.push('/account/${account.id}/liability-terms')
                : null,
            child: const Text('贷款条款'),
          ),
        ),
        _kv(context, '剩余债务', formatMoney(position.outstandingPrincipal)),
        _kv(
          context,
          '应计利息（截至 ${position.accruedThrough}）',
          formatMoney(position.accruedInterest),
        ),
        _kv(context, '下次还款日', position.nextPayment.dueDate),
        _kv(context, '计划金额', formatMoney(position.nextPayment.scheduledAmount)),
        _kv(
          context,
          '预计利息',
          formatMoney(position.nextPayment.projectedInterest),
        ),
        _kv(
          context,
          '预计本金',
          formatMoney(position.nextPayment.projectedPrincipal),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            OutlinedButton(
              onPressed: canPropose && !pending
                  ? () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          _RecordInterestDialog(accountId: account.id),
                    )
                  : null,
              child: const Text('记录利息'),
            ),
            if (pending) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '已有待确认利息'
                  '${terms.pendingLoanInterestThroughDate == null ? '' : '（截至 ${terms.pendingLoanInterestThroughDate}）'}',
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
        _RepaymentScheduleTile(accountId: account.id),
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
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
class _RecordInterestDialog extends ConsumerStatefulWidget {
  const _RecordInterestDialog({required this.accountId});
  final String accountId;

  @override
  ConsumerState<_RecordInterestDialog> createState() =>
      _RecordInterestDialogState();
}

class _RecordInterestDialogState extends ConsumerState<_RecordInterestDialog> {
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
          .read(loanRepositoryProvider)
          .proposeLoanInterest(
            widget.accountId,
            throughDate: _throughDate,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.invalidate(aiPendingProvider);
      ref.invalidate(overviewProvider);
      ref.invalidate(liabilityPositionsProvider);
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
            onPressed: () => ref.invalidate(liabilityPositionsProvider),
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

/// 可折叠还款计划：展开时才请求；hasMore 时可继续加载更长投影。
class _RepaymentScheduleTile extends ConsumerStatefulWidget {
  const _RepaymentScheduleTile({required this.accountId});
  final String accountId;

  @override
  ConsumerState<_RepaymentScheduleTile> createState() =>
      _RepaymentScheduleTileState();
}

class _RepaymentScheduleTileState
    extends ConsumerState<_RepaymentScheduleTile> {
  LoanRepaymentScheduleVm? _schedule;
  int _limit = 24;
  bool _loading = false;
  String? _error;

  Future<void> _load({int? limit}) async {
    final nextLimit = limit ?? _limit;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final schedule = await ref
          .read(loanRepositoryProvider)
          .getRepaymentSchedule(widget.accountId, limit: nextLimit);
      if (!mounted) return;
      setState(() {
        _schedule = schedule;
        _limit = nextLimit;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final schedule = _schedule;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('还款计划', style: AppType.body),
      onExpansionChanged: (open) {
        if (open && schedule == null && !_loading) _load();
      },
      children: [
        if (_loading && schedule == null)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.base),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('还款计划加载失败', style: AppType.caption),
                const SizedBox(height: AppSpacing.xs),
                OutlinedButton(
                  onPressed: () => _load(),
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        else if (schedule != null) ...[
          for (final item in schedule.items)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.kind == 'balloon'
                        ? '到期还款 · ${item.dueDate}'
                        : '第 ${item.sequence} 期 · ${item.dueDate}',
                    style: AppType.bodyStrong,
                  ),
                  Text(
                    '付款 ${formatMoney(item.payment)} · '
                    '本金 ${formatMoney(item.principal)} · '
                    '利息 ${formatMoney(item.interest)} · '
                    '期末 ${formatMoney(item.closingBalance)}',
                    style: AppType.caption,
                  ),
                ],
              ),
            ),
          if (schedule.hasMore)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _loading ? null : () => _load(limit: _limit * 2),
                child: Text(_loading ? '加载中…' : '加载更多'),
              ),
            ),
        ],
      ],
    );
  }
}
