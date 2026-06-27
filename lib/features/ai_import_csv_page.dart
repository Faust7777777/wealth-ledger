// Wealth Ledger — CSV 导入：粘贴 CSV → 逐行生成候选 atomic group → 去 AI 待确认复核。
// CSV 导入只生成候选；确认前不写账本。不连接券商、不下单、不转账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../shared/widgets.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

class AiImportCsvPage extends ConsumerStatefulWidget {
  const AiImportCsvPage({super.key});

  @override
  ConsumerState<AiImportCsvPage> createState() => _AiImportCsvPageState();
}

class _AiImportCsvPageState extends ConsumerState<AiImportCsvPage> {
  final _csv = TextEditingController();
  String? _accountId;
  bool _busy = false;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _csv.text.trim().isNotEmpty && _accountId != null && !_busy;

  Future<void> _submit(String defaultCurrency) async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref
          .read(aiProposalRepositoryProvider)
          .createFromCsv(
            _csv.text.trim(),
            defaultAccountId: _accountId,
            defaultCurrency: defaultCurrency,
          );
      ref.invalidate(aiPendingProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('已按 CSV 行生成候选；请在「AI 待确认」逐组复核')),
      );
      router.go('/ai-review');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 导入 · CSV')),
      body: ContentMaxWidth(
        child: accountsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorStateView(
            message: '$e',
            onRetry: () => ref.invalidate(accountsProvider),
          ),
          data: (accounts) {
            if (accounts.isEmpty) {
              return EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: '还没有账户',
                message: '先添加账户，才能把 CSV 行归到默认账户。',
                action: FilledButton(
                  onPressed: () => context.push('/accounts/new'),
                  child: const Text('添加账户'),
                ),
              );
            }

            _accountId ??= accounts.first.id;
            final selected = accounts.firstWhere(
              (account) => account.id == _accountId,
              orElse: () => accounts.first,
            );

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.base),
              children: [
                Text(
                  '粘贴 CSV 后，每一行会生成一个候选 atomic group；确认前不会进入余额、流水或净值。'
                  '支持列名：occurredAt,title,amount,currency；amount 为负数表示支出，正数表示收入。',
                  style: AppType.caption,
                ),
                const SizedBox(height: AppSpacing.base),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(
                    labelText: '默认账户',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(
                          '${account.displayName} · ${account.defaultCurrency}',
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _accountId = value),
                ),
                const SizedBox(height: AppSpacing.base),
                TextField(
                  controller: _csv,
                  minLines: 8,
                  maxLines: 14,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'CSV 内容',
                    hintText:
                        'occurredAt,title,amount,currency\n2026-06-27T08:00:00+08:00,早餐,-18.00,CNY\n2026-06-27T18:00:00+08:00,报销,+50.00,CNY',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '默认币种：${selected.defaultCurrency}。CSV 行内 currency 会覆盖默认币种。',
                  style: AppType.caption,
                ),
                const SizedBox(height: AppSpacing.base),
                FilledButton(
                  onPressed: _canSubmit
                      ? () => _submit(selected.defaultCurrency)
                      : null,
                  child: Text(_busy ? '生成中…' : '生成候选'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
