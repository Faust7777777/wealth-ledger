// Wealth Ledger — AI 文本导入：输入文本 → 生成候选 proposal → 去 AI 待确认逐条复核。
// AI 只产候选，确认前不入账；不下单/不转账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/app_dimens.dart';

class AiImportTextPage extends ConsumerStatefulWidget {
  const AiImportTextPage({super.key});
  @override
  ConsumerState<AiImportTextPage> createState() => _AiImportTextPageState();
}

class _AiImportTextPageState extends ConsumerState<AiImportTextPage> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(aiProposalRepositoryProvider).createFromText(text);
      ref.invalidate(aiPendingProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('已生成候选；请在「AI 待确认」逐条复核后再入账')),
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
    return Scaffold(
      appBar: AppBar(title: const Text('AI 导入 · 文本')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'AI 只根据你输入的文本生成候选记录；不连接券商、不下单、不转账，需你逐条确认后才入账。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.base),
            TextField(
              controller: _controller,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：瑞幸 18 改 21，加了配送费',
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? '生成中…' : '生成候选'),
            ),
          ],
        ),
      ),
    );
  }
}
