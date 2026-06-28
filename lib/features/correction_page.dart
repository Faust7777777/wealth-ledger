// Wealth Ledger — 已确认记录更正候选。
// 产品边界：不原地改 confirmed movement；这里只生成 correction proposal，用户去 AI 复核确认后才入账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/types.dart';
import '../data/providers.dart';
import '../data/view_models.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class CorrectionPage extends ConsumerStatefulWidget {
  const CorrectionPage({super.key, required this.movementId});
  final String movementId;

  @override
  ConsumerState<CorrectionPage> createState() => _CorrectionPageState();
}

class _CorrectionPageState extends ConsumerState<CorrectionPage> {
  final _newAmount = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;
  bool _initializedAmount = false;

  @override
  void dispose() {
    _newAmount.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool _amountValid(String oldAmount) {
    final t = _newAmount.text.trim();
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(t)) return false;
    final delta = subtractDecimal(t, oldAmount);
    return !RegExp(r'^-?0+(\.0+)?$').hasMatch(delta);
  }

  bool _canSubmit(String oldAmount) =>
      _amountValid(oldAmount) && _reason.text.trim().isNotEmpty && !_busy;

  Future<void> _submit(MovementVm movement, MovementEntryVm entry) async {
    final oldAmount = entry.amount;
    if (!_canSubmit(oldAmount)) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(movementRepositoryProvider)
          .createCorrectionProposal(
            CreateCorrectionInput(
              targetMovementId: movement.id,
              oldAmount: oldAmount,
              newAmount: _newAmount.text.trim(),
              reason: _reason.text.trim(),
            ),
          );
      ref.invalidate(aiPendingProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('已生成更正候选，请在 AI 复核中确认')),
      );
      if (mounted) router.go('/ai-review');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(movementByIdProvider(widget.movementId));
    return Scaffold(
      appBar: AppBar(title: const Text('发起更正')),
      body: ContentMaxWidth(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () =>
                ref.invalidate(movementByIdProvider(widget.movementId)),
          ),
          data: (m) {
            if (m == null) {
              return const EmptyState(icon: Icons.help_outline, title: '记录不存在');
            }
            final entry = m.entries.length == 1 ? m.entries.single : null;
            final editable =
                entry != null &&
                (m.status == MovementStatus.confirmed ||
                    m.status == MovementStatus.inTransit) &&
                m.type != MovementType.correction;
            if (!editable) {
              return const EmptyState(
                icon: Icons.lock_outline,
                title: '当前记录暂不支持更正',
                message:
                    'MVP 只支持 confirmed / in_transit 的单分录金额更正。转账、多腿交易和 correction 本身需要更完整的 diff。',
              );
            }
            final oldAmount = entry.amount;
            final currency = entry.currency;
            if (!_initializedAmount) {
              _newAmount.text = oldAmount;
              _initializedAmount = true;
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                Text(m.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '不会改写原记录；确认后新增一条 correction movement。',
                  style: AppType.caption,
                ),
                const SizedBox(height: AppSpacing.base),
                _kv(
                  '当前金额',
                  formatMoney(Money(amount: oldAmount, currency: currency)),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _newAmount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '更正后金额',
                    helperText: '币种保持 $currency；如需换账户/币种，后续用多字段更正。',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _reason,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '更正原因',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.base),
                FilledButton(
                  onPressed: _canSubmit(oldAmount)
                      ? () => _submit(m, entry)
                      : null,
                  child: Text(_busy ? '生成中…' : '生成更正候选'),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('这是候选变更；AI 复核中接受整组后才写账本。', style: AppType.caption),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Row(
    children: [
      Expanded(child: Text(k, style: AppType.body)),
      Text(v, style: AppType.moneyRow),
    ],
  );
}
